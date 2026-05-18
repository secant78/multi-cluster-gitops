"""
Order Execution API - Mini-Nasdaq GitOps Platform
FastAPI service that simulates order placement and management.
"""
import os
import uuid
import logging
import random
from datetime import datetime, timezone
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException, Path
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from prometheus_fastapi_instrumentator import Instrumentator
from pythonjsonlogger import jsonlogger

# --- Logging setup ---
LOG_LEVEL = os.getenv("LOG_LEVEL", "info").upper()
log_handler = logging.StreamHandler()
formatter = jsonlogger.JsonFormatter(
    fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log_handler.setFormatter(formatter)
logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.INFO), handlers=[log_handler])
logger = logging.getLogger("order-execution-api")

# --- Config ---
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
APP_ENV = os.getenv("APP_ENV", "default")
MARKET_DATA_URL = os.getenv("MARKET_DATA_URL", "http://market-data-service/api/v1/market-data")
POD_NAME = os.getenv("POD_NAME", "unknown")
POD_NAMESPACE = os.getenv("POD_NAMESPACE", "unknown")

# --- FastAPI app ---
app = FastAPI(
    title="Order Execution API",
    description="Mock Order Execution API for Mini-Nasdaq GitOps Platform",
    version=APP_VERSION,
)

# --- Prometheus metrics ---
Instrumentator().instrument(app).expose(app)

# --- In-memory order store (demo purposes) ---
_orders: dict = {
    "ord-0001": {
        "order_id": "ord-0001",
        "symbol": "AAPL",
        "quantity": 100,
        "price": 182.50,
        "status": "FILLED",
        "side": "BUY",
        "created_at": "2026-05-18T09:30:00Z",
        "filled_at": "2026-05-18T09:30:01Z",
    },
    "ord-0002": {
        "order_id": "ord-0002",
        "symbol": "GOOGL",
        "quantity": 10,
        "price": 175.20,
        "status": "FILLED",
        "side": "SELL",
        "created_at": "2026-05-18T09:31:00Z",
        "filled_at": "2026-05-18T09:31:02Z",
    },
    "ord-0003": {
        "order_id": "ord-0003",
        "symbol": "MSFT",
        "quantity": 50,
        "price": 415.00,
        "status": "PENDING",
        "side": "BUY",
        "created_at": "2026-05-18T10:00:00Z",
        "filled_at": None,
    },
    "ord-0004": {
        "order_id": "ord-0004",
        "symbol": "AMZN",
        "quantity": 25,
        "price": 185.75,
        "status": "CANCELLED",
        "side": "BUY",
        "created_at": "2026-05-18T10:15:00Z",
        "filled_at": None,
    },
    "ord-0005": {
        "order_id": "ord-0005",
        "symbol": "TSLA",
        "quantity": 200,
        "price": 172.30,
        "status": "FILLED",
        "side": "SELL",
        "created_at": "2026-05-18T11:00:00Z",
        "filled_at": "2026-05-18T11:00:03Z",
    },
}


# --- Request/Response models ---
class OrderRequest(BaseModel):
    symbol: str = Field(..., description="Ticker symbol (e.g. AAPL)", min_length=1, max_length=10)
    quantity: int = Field(..., description="Number of shares", gt=0)
    price: float = Field(..., description="Limit price per share", gt=0)
    side: str = Field(default="BUY", description="Order side: BUY or SELL", pattern="^(BUY|SELL)$")


class Order(BaseModel):
    order_id: str
    symbol: str
    quantity: int
    price: float
    status: str
    side: str
    created_at: str
    filled_at: Optional[str]


# --- Routes ---

@app.get("/health")
async def health():
    """Kubernetes liveness and readiness probe endpoint."""
    return {
        "status": "ok",
        "version": APP_VERSION,
        "env": APP_ENV,
        "pod": POD_NAME,
        "namespace": POD_NAMESPACE,
    }


@app.get("/api/v1/orders", response_model=list[Order])
async def list_orders():
    """
    List all orders. If APP_ENV=broken, returns 500 for canary failure testing.
    """
    if APP_ENV == "broken":
        logger.error("Broken mode active - simulating 500 error for canary testing")
        raise HTTPException(status_code=500, detail="Service is in broken mode (canary test)")

    logger.info("Listing all orders", extra={"order_count": len(_orders)})
    return list(_orders.values())


@app.post("/api/v1/orders", response_model=Order, status_code=201)
async def create_order(order_request: OrderRequest):
    """
    Create a new order. Fetches current market data for the symbol.
    """
    if APP_ENV == "broken":
        logger.error("Broken mode active - simulating 500 error for canary testing")
        raise HTTPException(status_code=500, detail="Service is in broken mode (canary test)")

    symbol = order_request.symbol.upper()

    # Fetch market data for validation
    market_price = None
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(f"{MARKET_DATA_URL}/{symbol}")
            if response.status_code == 200:
                market_data = response.json()
                market_price = market_data.get("last_price")
                logger.debug(
                    "Fetched market data",
                    extra={"symbol": symbol, "market_price": market_price},
                )
    except (httpx.RequestError, httpx.TimeoutException) as exc:
        logger.warning(
            "Could not fetch market data, proceeding with limit price",
            extra={"symbol": symbol, "error": str(exc)},
        )

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    order_id = f"ord-{uuid.uuid4().hex[:8].upper()}"

    # Simulate order matching: filled if within 2% of market price
    status = "PENDING"
    filled_at = None
    if market_price is not None:
        deviation = abs(order_request.price - market_price) / market_price
        if deviation <= 0.02:
            status = "FILLED"
            filled_at = now
    else:
        # No market data — simulate random fill (80% chance)
        if random.random() < 0.8:
            status = "FILLED"
            filled_at = now

    order = {
        "order_id": order_id,
        "symbol": symbol,
        "quantity": order_request.quantity,
        "price": order_request.price,
        "status": status,
        "side": order_request.side,
        "created_at": now,
        "filled_at": filled_at,
    }
    _orders[order_id] = order

    logger.info(
        "Order created",
        extra={
            "order_id": order_id,
            "symbol": symbol,
            "quantity": order_request.quantity,
            "price": order_request.price,
            "status": status,
            "market_price": market_price,
        },
    )
    return order


@app.get("/api/v1/orders/{order_id}", response_model=Order)
async def get_order(order_id: str = Path(..., description="Order ID")):
    """Get a single order by ID."""
    if order_id not in _orders:
        raise HTTPException(status_code=404, detail=f"Order '{order_id}' not found")
    return _orders[order_id]


@app.delete("/api/v1/orders/{order_id}", status_code=200)
async def cancel_order(order_id: str = Path(..., description="Order ID")):
    """Cancel a pending order."""
    if order_id not in _orders:
        raise HTTPException(status_code=404, detail=f"Order '{order_id}' not found")

    order = _orders[order_id]
    if order["status"] != "PENDING":
        raise HTTPException(
            status_code=400,
            detail=f"Cannot cancel order in status '{order['status']}'. Only PENDING orders can be cancelled.",
        )

    _orders[order_id]["status"] = "CANCELLED"
    logger.info("Order cancelled", extra={"order_id": order_id})
    return {"message": f"Order {order_id} cancelled successfully"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level=LOG_LEVEL.lower())
