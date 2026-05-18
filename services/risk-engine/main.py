"""
Risk Engine Service — Pre-trade risk validation for Mini-Nasdaq GitOps Platform.
Every order must pass risk checks before being accepted by the Order Execution API.
"""
import os
import time
import collections
import logging
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from pythonjsonlogger import jsonlogger
from prometheus_fastapi_instrumentator import Instrumentator

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
APP_ENV = os.getenv("APP_ENV", "default")
POD_NAME = os.getenv("POD_NAME", "local")
POD_NAMESPACE = os.getenv("POD_NAMESPACE", "default")
LOG_LEVEL = os.getenv("LOG_LEVEL", "info").upper()

# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------
logger = logging.getLogger("risk-engine")
handler = logging.StreamHandler()
formatter = jsonlogger.JsonFormatter(
    fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
handler.setFormatter(formatter)
logger.addHandler(handler)
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

# ---------------------------------------------------------------------------
# Risk limits (hardcoded — would come from config service in production)
# ---------------------------------------------------------------------------
MAX_QUANTITY = 10_000
MAX_NOTIONAL = 5_000_000.0
PRICE_COLLAR_PCT = 10.0

REFERENCE_PRICES: dict[str, float] = {
    "AAPL": 182.50,
    "GOOGL": 175.00,
    "MSFT": 415.00,
    "AMZN": 185.75,
    "TSLA": 172.30,
    "NVDA": 875.00,
    "META": 485.00,
    "NFLX": 620.00,
}
DEFAULT_REFERENCE_PRICE = 100.00

SHORT_SELL_RESTRICTED_SYMBOLS = {"TSLA", "NVDA"}
MAX_SHORT_SELL_QUANTITY = 500

# ---------------------------------------------------------------------------
# In-memory state (module-level, single-threaded via asyncio)
# ---------------------------------------------------------------------------
# Deque acts as a sliding window of the last 1000 order IDs
_recent_order_ids: collections.deque = collections.deque(maxlen=1000)
_seen_order_ids: set = set()

# Stats counters
_stats = {
    "total_checks": 0,
    "approved": 0,
    "rejected": 0,
    "latency_us_total": 0,
    "rejection_breakdown": {
        "QUANTITY_EXCEEDED": 0,
        "NOTIONAL_EXCEEDED": 0,
        "PRICE_COLLAR_BREACH": 0,
        "DUPLICATE_ORDER": 0,
        "SHORT_SELL_RESTRICTED": 0,
    },
}

# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(
    title="Risk Engine Service",
    description="Pre-trade risk validation for Mini-Nasdaq GitOps Platform",
    version=APP_VERSION,
)

Instrumentator().instrument(app).expose(app, endpoint="/metrics")

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
class RiskCheckRequest(BaseModel):
    order_id: str = Field(..., example="ord-123")
    symbol: str = Field(..., example="AAPL")
    quantity: int = Field(..., gt=0, example=100)
    price: float = Field(..., gt=0.0, example=182.50)
    side: str = Field(..., pattern="^(BUY|SELL)$", example="BUY")
    account_id: str = Field(..., example="ACC-001")


class RiskCheckApproved(BaseModel):
    order_id: str
    approved: bool
    risk_score: int
    checks_passed: list[str]
    latency_us: int
    timestamp: str


class RiskCheckRejected(BaseModel):
    order_id: str
    approved: bool
    risk_code: str
    reason: str
    checks_passed: list[str]
    latency_us: int
    timestamp: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _compute_risk_score(notional: float) -> int:
    """0-100 score based on notional relative to $50,000."""
    return min(100, int(notional / 50_000))


def _record_seen(order_id: str) -> None:
    """Add order_id to the sliding window deque and set."""
    if len(_recent_order_ids) == _recent_order_ids.maxlen:
        evicted = _recent_order_ids[0]
        _seen_order_ids.discard(evicted)
    _recent_order_ids.append(order_id)
    _seen_order_ids.add(order_id)


def _is_duplicate(order_id: str) -> bool:
    return order_id in _seen_order_ids


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    return {
        "status": "ok",
        "version": APP_VERSION,
        "env": APP_ENV,
        "pod": POD_NAME,
    }


@app.post("/api/v1/risk/check", status_code=200)
def risk_check(req: RiskCheckRequest):
    start_ns = time.perf_counter_ns()
    checks_passed: list[str] = []
    notional = req.quantity * req.price
    timestamp = _now_iso()

    _stats["total_checks"] += 1

    def _reject(risk_code: str, reason: str) -> dict:
        elapsed_us = (time.perf_counter_ns() - start_ns) // 1000
        _stats["rejected"] += 1
        _stats["latency_us_total"] += elapsed_us
        _stats["rejection_breakdown"][risk_code] += 1
        payload = RiskCheckRejected(
            order_id=req.order_id,
            approved=False,
            risk_code=risk_code,
            reason=reason,
            checks_passed=checks_passed,
            latency_us=elapsed_us,
            timestamp=timestamp,
        )
        logger.info(
            "Risk decision",
            extra={
                "order_id": req.order_id,
                "symbol": req.symbol,
                "approved": False,
                "risk_score": None,
                "risk_code": risk_code,
                "latency_us": elapsed_us,
            },
        )
        raise HTTPException(status_code=422, detail=payload.model_dump())

    # 1. QUANTITY_LIMIT
    if req.quantity > MAX_QUANTITY:
        _reject(
            "QUANTITY_EXCEEDED",
            f"Order quantity {req.quantity:,} exceeds limit of {MAX_QUANTITY:,}",
        )
    checks_passed.append("QUANTITY_LIMIT")

    # 2. NOTIONAL_LIMIT
    if notional > MAX_NOTIONAL:
        _reject(
            "NOTIONAL_EXCEEDED",
            f"Order notional ${notional:,.2f} exceeds limit of ${MAX_NOTIONAL:,.2f}",
        )
    checks_passed.append("NOTIONAL_LIMIT")

    # 3. PRICE_COLLAR
    ref_price = REFERENCE_PRICES.get(req.symbol, DEFAULT_REFERENCE_PRICE)
    deviation_pct = abs(req.price - ref_price) / ref_price * 100.0
    if deviation_pct > PRICE_COLLAR_PCT:
        _reject(
            "PRICE_COLLAR_BREACH",
            (
                f"Price ${req.price:.2f} deviates {deviation_pct:.1f}% from reference "
                f"${ref_price:.2f} (limit: {PRICE_COLLAR_PCT:.0f}%)"
            ),
        )
    checks_passed.append("PRICE_COLLAR")

    # 4. DUPLICATE_ORDER
    if _is_duplicate(req.order_id):
        _reject(
            "DUPLICATE_ORDER",
            f"Order ID '{req.order_id}' has already been submitted",
        )
    checks_passed.append("DUPLICATE_ORDER")

    # 5. SHORT_SELL_CHECK
    if req.side == "SELL" and req.symbol in SHORT_SELL_RESTRICTED_SYMBOLS:
        if req.quantity > MAX_SHORT_SELL_QUANTITY:
            _reject(
                "SHORT_SELL_RESTRICTED",
                "Enhanced short-sell restrictions active for volatile securities",
            )
    checks_passed.append("SHORT_SELL_CHECK")

    # All checks passed — record this order_id
    _record_seen(req.order_id)

    elapsed_us = (time.perf_counter_ns() - start_ns) // 1000
    risk_score = _compute_risk_score(notional)
    _stats["approved"] += 1
    _stats["latency_us_total"] += elapsed_us

    logger.info(
        "Risk decision",
        extra={
            "order_id": req.order_id,
            "symbol": req.symbol,
            "approved": True,
            "risk_score": risk_score,
            "latency_us": elapsed_us,
        },
    )

    return RiskCheckApproved(
        order_id=req.order_id,
        approved=True,
        risk_score=risk_score,
        checks_passed=checks_passed,
        latency_us=elapsed_us,
        timestamp=timestamp,
    )


@app.get("/api/v1/risk/limits")
def risk_limits():
    return {
        "max_quantity": MAX_QUANTITY,
        "max_notional": MAX_NOTIONAL,
        "price_collar_pct": int(PRICE_COLLAR_PCT),
        "short_sell_restricted_symbols": sorted(SHORT_SELL_RESTRICTED_SYMBOLS),
        "max_short_sell_quantity": MAX_SHORT_SELL_QUANTITY,
    }


@app.get("/api/v1/risk/stats")
def risk_stats():
    total = _stats["total_checks"]
    rejected = _stats["rejected"]
    approved = _stats["approved"]
    rejection_rate = round(rejected / total, 4) if total > 0 else 0.0
    avg_latency_us = (
        int(_stats["latency_us_total"] / total) if total > 0 else 0
    )
    return {
        "total_checks": total,
        "approved": approved,
        "rejected": rejected,
        "rejection_rate": rejection_rate,
        "rejection_breakdown": dict(_stats["rejection_breakdown"]),
        "avg_latency_us": avg_latency_us,
    }
