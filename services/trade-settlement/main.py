"""
Trade Settlement Service — Post-trade T+2 settlement lifecycle management.
Manages the clearing pipeline: trade capture → confirmation → settled.
"""
import os
import uuid
import logging
from datetime import date, datetime, timedelta, timezone
from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field
from pythonjsonlogger import jsonlogger
from prometheus_fastapi_instrumentator import Instrumentator

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
APP_ENV = os.getenv("APP_ENV", "default")
POD_NAME = os.getenv("POD_NAME", "local")
LOG_LEVEL = os.getenv("LOG_LEVEL", "info").upper()

# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------
logger = logging.getLogger("trade-settlement")
handler = logging.StreamHandler()
formatter = jsonlogger.JsonFormatter(
    fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
handler.setFormatter(formatter)
logger.addHandler(handler)
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------
CUSIP_MAP: dict[str, str] = {
    "AAPL": "037833100",
    "GOOGL": "02079K305",
    "MSFT": "594918104",
    "AMZN": "023135106",
    "TSLA": "88160R101",
    "NVDA": "67066G104",
    "META": "30303M102",
    "NFLX": "64110L106",
}
DEFAULT_CUSIP = "000000000"

# Valid lifecycle statuses (in order)
STATUSES = [
    "PENDING_CONFIRMATION",
    "CONFIRMED",
    "CLEARED",
    "SETTLEMENT_INSTRUCTED",
    "SETTLED",
    "FAILED",
]

# ---------------------------------------------------------------------------
# Business day calendar helper
# ---------------------------------------------------------------------------
def add_business_days(start: date, n: int) -> date:
    """Add n business days to start date, skipping Saturday (5) and Sunday (6)."""
    current = start
    added = 0
    while added < n:
        current += timedelta(days=1)
        if current.weekday() < 5:  # Mon=0 … Fri=4
            added += 1
    return current


# ---------------------------------------------------------------------------
# In-memory trade store
# ---------------------------------------------------------------------------
# trade_id -> dict
_trades: dict[str, dict] = {}


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _make_dtcc_ref() -> str:
    return "DTCC-" + uuid.uuid4().hex[:12].upper()


def _build_trade(
    trade_id: str,
    order_id: str,
    symbol: str,
    quantity: int,
    price: float,
    side: str,
    account_id: str,
    counterparty_id: str,
    executed_at: str,
    status: str = "PENDING_CONFIRMATION",
    settled_at: Optional[str] = None,
) -> dict:
    exec_dt = datetime.fromisoformat(executed_at.replace("Z", "+00:00"))
    exec_date = exec_dt.date()
    settlement_date = add_business_days(exec_date, 2)
    raw_amount = quantity * price
    settlement_amount = raw_amount if side == "BUY" else -raw_amount
    cusip = CUSIP_MAP.get(symbol, DEFAULT_CUSIP)
    dtcc_ref = _make_dtcc_ref()
    return {
        "trade_id": trade_id,
        "order_id": order_id,
        "symbol": symbol,
        "quantity": quantity,
        "price": price,
        "side": side,
        "account_id": account_id,
        "counterparty_id": counterparty_id,
        "executed_at": executed_at,
        "status": status,
        "settlement_date": settlement_date.isoformat(),
        "settlement_amount": round(settlement_amount, 2),
        "cusip": cusip,
        "dtcc_ref": dtcc_ref,
        "captured_at": _now_iso(),
        "settled_at": settled_at,
    }


# ---------------------------------------------------------------------------
# Pre-populate with 5 sample trades
# ---------------------------------------------------------------------------
def _seed_trades() -> None:
    samples = [
        {
            "trade_id": "TRD-SEED-001",
            "order_id": "ord-seed-001",
            "symbol": "AAPL",
            "quantity": 200,
            "price": 182.50,
            "side": "BUY",
            "account_id": "ACC-001",
            "counterparty_id": "MM-CITADEL",
            "executed_at": "2026-05-14T09:35:00Z",
            "status": "SETTLED",
            "settled_at": "2026-05-18T16:00:00Z",
        },
        {
            "trade_id": "TRD-SEED-002",
            "order_id": "ord-seed-002",
            "symbol": "MSFT",
            "quantity": 50,
            "price": 415.00,
            "side": "BUY",
            "account_id": "ACC-002",
            "counterparty_id": "MM-VIRTU",
            "executed_at": "2026-05-15T10:12:00Z",
            "status": "CONFIRMED",
            "settled_at": None,
        },
        {
            "trade_id": "TRD-SEED-003",
            "order_id": "ord-seed-003",
            "symbol": "TSLA",
            "quantity": 75,
            "price": 172.30,
            "side": "SELL",
            "account_id": "ACC-001",
            "counterparty_id": "MM-GOLDMAN",
            "executed_at": "2026-05-16T11:45:00Z",
            "status": "PENDING_CONFIRMATION",
            "settled_at": None,
        },
        {
            "trade_id": "TRD-SEED-004",
            "order_id": "ord-seed-004",
            "symbol": "NVDA",
            "quantity": 30,
            "price": 875.00,
            "side": "BUY",
            "account_id": "ACC-003",
            "counterparty_id": "MM-JANE-STREET",
            "executed_at": "2026-05-16T13:22:00Z",
            "status": "CONFIRMED",
            "settled_at": None,
        },
        {
            "trade_id": "TRD-SEED-005",
            "order_id": "ord-seed-005",
            "symbol": "GOOGL",
            "quantity": 100,
            "price": 175.00,
            "side": "BUY",
            "account_id": "ACC-002",
            "counterparty_id": "MM-CITADEL",
            "executed_at": "2026-05-13T14:55:00Z",
            "status": "SETTLED",
            "settled_at": "2026-05-17T16:00:00Z",
        },
    ]
    for s in samples:
        trade = _build_trade(
            trade_id=s["trade_id"],
            order_id=s["order_id"],
            symbol=s["symbol"],
            quantity=s["quantity"],
            price=s["price"],
            side=s["side"],
            account_id=s["account_id"],
            counterparty_id=s["counterparty_id"],
            executed_at=s["executed_at"],
            status=s["status"],
            settled_at=s.get("settled_at"),
        )
        _trades[s["trade_id"]] = trade


_seed_trades()

# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(
    title="Trade Settlement Service",
    description="Post-trade clearing and T+2 settlement lifecycle manager",
    version=APP_VERSION,
)

Instrumentator().instrument(app).expose(app, endpoint="/metrics")

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
class TradeCapture(BaseModel):
    trade_id: str = Field(..., example="TRD-001")
    order_id: str = Field(..., example="ord-123")
    symbol: str = Field(..., example="AAPL")
    quantity: int = Field(..., gt=0, example=100)
    price: float = Field(..., gt=0.0, example=182.50)
    side: str = Field(..., pattern="^(BUY|SELL)$", example="BUY")
    account_id: str = Field(..., example="ACC-001")
    counterparty_id: str = Field(..., example="MM-GOLDMAN")
    executed_at: str = Field(..., example="2026-05-18T14:32:01Z")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    return {
        "status": "ok",
        "version": APP_VERSION,
        "env": APP_ENV,
    }


@app.post("/api/v1/settlement/trades", status_code=201)
def capture_trade(req: TradeCapture):
    if req.trade_id in _trades:
        raise HTTPException(status_code=409, detail=f"Trade '{req.trade_id}' already exists")

    trade = _build_trade(
        trade_id=req.trade_id,
        order_id=req.order_id,
        symbol=req.symbol,
        quantity=req.quantity,
        price=req.price,
        side=req.side,
        account_id=req.account_id,
        counterparty_id=req.counterparty_id,
        executed_at=req.executed_at,
    )
    _trades[req.trade_id] = trade

    logger.info(
        "Trade captured",
        extra={
            "trade_id": req.trade_id,
            "symbol": req.symbol,
            "from_status": None,
            "to_status": "PENDING_CONFIRMATION",
        },
    )
    return trade


@app.get("/api/v1/settlement/trades")
def list_trades(status: Optional[str] = Query(default=None)):
    trades = list(_trades.values())
    if status:
        trades = [t for t in trades if t["status"] == status]
    return trades


@app.get("/api/v1/settlement/trades/{trade_id}")
def get_trade(trade_id: str):
    trade = _trades.get(trade_id)
    if not trade:
        raise HTTPException(status_code=404, detail=f"Trade '{trade_id}' not found")
    return trade


@app.post("/api/v1/settlement/trades/{trade_id}/confirm")
def confirm_trade(trade_id: str):
    trade = _trades.get(trade_id)
    if not trade:
        raise HTTPException(status_code=404, detail=f"Trade '{trade_id}' not found")

    if trade["status"] != "PENDING_CONFIRMATION":
        raise HTTPException(status_code=400, detail="Trade already confirmed")

    from_status = trade["status"]
    trade["status"] = "CONFIRMED"

    logger.info(
        "Trade status transition",
        extra={
            "trade_id": trade_id,
            "from_status": from_status,
            "to_status": "CONFIRMED",
        },
    )
    return trade


@app.post("/api/v1/settlement/trades/{trade_id}/settle")
def settle_trade(trade_id: str):
    trade = _trades.get(trade_id)
    if not trade:
        raise HTTPException(status_code=404, detail=f"Trade '{trade_id}' not found")

    if trade["status"] != "CONFIRMED":
        raise HTTPException(
            status_code=400,
            detail=f"Trade must be in CONFIRMED status to settle (current: {trade['status']})",
        )

    today = date.today()
    settlement_date = date.fromisoformat(trade["settlement_date"])
    if today < settlement_date:
        raise HTTPException(
            status_code=400,
            detail=(
                f"Early settlement attempted: settlement_date is {trade['settlement_date']}, "
                f"today is {today.isoformat()}"
            ),
        )

    from_status = trade["status"]
    trade["status"] = "SETTLED"
    trade["settled_at"] = _now_iso()

    logger.info(
        "Trade status transition",
        extra={
            "trade_id": trade_id,
            "from_status": from_status,
            "to_status": "SETTLED",
        },
    )
    return trade


@app.get("/api/v1/settlement/pipeline")
def pipeline_summary():
    all_trades = list(_trades.values())
    total_trades = len(all_trades)

    # Count by status
    pipeline_counts: dict[str, int] = {s: 0 for s in STATUSES}
    total_value = 0.0
    pending_value = 0.0
    settlement_date_breakdown: dict[str, dict] = {}

    for t in all_trades:
        status = t["status"]
        if status in pipeline_counts:
            pipeline_counts[status] += 1

        amount = abs(t["settlement_amount"])
        total_value += amount

        if status not in ("SETTLED", "FAILED"):
            pending_value += amount
            sd = t["settlement_date"]
            if sd not in settlement_date_breakdown:
                settlement_date_breakdown[sd] = {"count": 0, "value": 0.0}
            settlement_date_breakdown[sd]["count"] += 1
            settlement_date_breakdown[sd]["value"] = round(
                settlement_date_breakdown[sd]["value"] + amount, 2
            )

    return {
        "pipeline": pipeline_counts,
        "total_trades": total_trades,
        "total_settlement_value": round(total_value, 2),
        "pending_settlement_value": round(pending_value, 2),
        "settlement_date_breakdown": settlement_date_breakdown,
    }


@app.get("/api/v1/settlement/calendar")
def settlement_calendar():
    today = date.today()
    results = []
    for i in range(1, 6):
        trade_date = today + timedelta(days=i - 1)
        # We want T+2 from today, T+2 from today+1, etc. — specifically
        # the next 5 (trade_date, settlement_date) pairs starting from today.
        settlement = add_business_days(trade_date, 2)
        results.append(
            {
                "trade_date": trade_date.isoformat(),
                "settlement_date": settlement.isoformat(),
            }
        )
    return results
