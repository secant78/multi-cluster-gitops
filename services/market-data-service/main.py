"""
Market Data Service - Mini-Nasdaq GitOps Platform
FastAPI service that provides mock real-time market data for major tech stocks.
"""
import os
import random
import logging
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Path
from pydantic import BaseModel
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
logger = logging.getLogger("market-data-service")

# --- Config ---
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
APP_ENV = os.getenv("APP_ENV", "default")
REFRESH_INTERVAL_MS = int(os.getenv("REFRESH_INTERVAL_MS", "1000"))
POD_NAME = os.getenv("POD_NAME", "unknown")
POD_NAMESPACE = os.getenv("POD_NAMESPACE", "unknown")

# --- FastAPI app ---
app = FastAPI(
    title="Market Data Service",
    description="Mock Market Data Service for Mini-Nasdaq GitOps Platform",
    version=APP_VERSION,
)

# --- Prometheus metrics ---
Instrumentator().instrument(app).expose(app)

# --- Mock base prices (realistic as of mid-2026 demo) ---
_BASE_PRICES: dict[str, float] = {
    "AAPL":  182.50,
    "GOOGL": 175.20,
    "MSFT":  415.00,
    "AMZN":  185.75,
    "TSLA":  172.30,
    "NVDA":  875.00,
    "META":  505.00,
    "NFLX":  635.00,
}

# --- Mock daily volumes ---
_BASE_VOLUMES: dict[str, int] = {
    "AAPL":  85_000_000,
    "GOOGL": 25_000_000,
    "MSFT":  35_000_000,
    "AMZN":  45_000_000,
    "TSLA":  120_000_000,
    "NVDA":  55_000_000,
    "META":  28_000_000,
    "NFLX":  8_000_000,
}


def _generate_quote(symbol: str) -> dict:
    """Generate a realistic mock market quote with minor random variation."""
    if symbol not in _BASE_PRICES:
        return None

    base = _BASE_PRICES[symbol]
    # Simulate small price movement: ±0.5%
    variation = random.uniform(-0.005, 0.005)
    last_price = round(base * (1 + variation), 2)

    spread = round(last_price * 0.0002, 2)  # ~0.02% spread
    bid = round(last_price - spread, 2)
    ask = round(last_price + spread, 2)

    # Volume simulation: between 60-140% of daily base
    volume_factor = random.uniform(0.6, 1.4)
    volume = int(_BASE_VOLUMES[symbol] * volume_factor)

    # Change from previous close (mock)
    prev_close = round(base * (1 + random.uniform(-0.02, 0.02)), 2)
    change = round(last_price - prev_close, 2)
    change_pct = round((change / prev_close) * 100, 4)

    return {
        "symbol": symbol,
        "last_price": last_price,
        "bid": bid,
        "ask": ask,
        "volume": volume,
        "change": change,
        "change_pct": change_pct,
        "prev_close": prev_close,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        "exchange": "NASDAQ",
        "currency": "USD",
    }


# --- Response models ---
class MarketQuote(BaseModel):
    symbol: str
    last_price: float
    bid: float
    ask: float
    volume: int
    change: float
    change_pct: float
    prev_close: float
    timestamp: str
    exchange: str
    currency: str


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


@app.get("/api/v1/market-data", response_model=list[MarketQuote])
async def get_all_market_data():
    """
    Get current market data for all tracked symbols.
    Returns real-time mock quotes for AAPL, GOOGL, MSFT, AMZN, TSLA, NVDA, META, NFLX.
    """
    logger.info("Fetching all market data", extra={"symbol_count": len(_BASE_PRICES)})
    quotes = []
    for symbol in _BASE_PRICES:
        quote = _generate_quote(symbol)
        if quote:
            quotes.append(quote)
    return quotes


@app.get("/api/v1/market-data/{symbol}", response_model=MarketQuote)
async def get_market_data(symbol: str = Path(..., description="Ticker symbol, e.g. AAPL")):
    """
    Get current market data for a specific symbol.
    """
    symbol = symbol.upper()
    logger.debug("Fetching market data for symbol", extra={"symbol": symbol})

    quote = _generate_quote(symbol)
    if quote is None:
        available = list(_BASE_PRICES.keys())
        raise HTTPException(
            status_code=404,
            detail=f"Symbol '{symbol}' not found. Available symbols: {available}",
        )

    return quote


@app.get("/api/v1/symbols")
async def list_symbols():
    """List all tracked symbols."""
    return {
        "symbols": list(_BASE_PRICES.keys()),
        "count": len(_BASE_PRICES),
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level=LOG_LEVEL.lower())
