"""Configuration, read once at startup from environment variables.

Addresses and secrets have no defaults: if one is missing, the service refuses
to start with a clear message instead of starting half-configured. Tuning
values default to the numbers in CLAUDE.md and can be changed without a new build.
"""
import os
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Settings:
    database_url: str = field(repr=False)    # holds the password, so it's never printed
    db_pool_size: int                        # connections kept open (~1.2 busy at 600 req/s)
    db_statement_timeout_ms: int             # Postgres cancels slower queries
    db_wait_timeout_s: float                 # longest wait for a free connection
    pricing_url: str                         # e.g. http://pricing-fake:8081
    pricing_token: str = field(repr=False)   # secret, so it's never printed
    pricing_timeout_s: float                 # hard deadline for the whole pricing call
    pricing_cache_ttl_s: float               # how old a cached price may be
    pricing_refresh_interval_s: float        # how often each pod refreshes its whole price cache
    pricing_refresh_timeout_s: float         # deadline for a refresh (no customer is waiting on it)
    pricing_fallback_enabled: bool           # the switch the incident drill flips
    log_level: str                           # INFO normally; DEBUG only while investigating


def load_settings() -> Settings:
    """Read the environment. Raises RuntimeError naming the setting if one is missing or wrong."""
    log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
    if log_level not in ("DEBUG", "INFO", "WARNING", "ERROR"):
        raise RuntimeError(f"LOG_LEVEL must be DEBUG, INFO, WARNING or ERROR, not {log_level!r}")

    settings = Settings(
        database_url=_required("DATABASE_URL"),
        db_pool_size=_number("DB_POOL_SIZE", "10", int),
        db_statement_timeout_ms=_number("DB_STATEMENT_TIMEOUT_MS", "100", int),
        db_wait_timeout_s=_number("DB_WAIT_TIMEOUT_S", "0.1", float),
        pricing_url=_required("PRICING_URL").rstrip("/"),
        pricing_token=_required("PRICING_TOKEN"),
        pricing_timeout_s=_number("PRICING_TIMEOUT_S", "0.15", float),
        pricing_cache_ttl_s=_number("PRICING_CACHE_TTL_S", "60", float),
        pricing_refresh_interval_s=_number("PRICING_REFRESH_INTERVAL_S", "30", float),
        pricing_refresh_timeout_s=_number("PRICING_REFRESH_TIMEOUT_S", "2", float),
        pricing_fallback_enabled=_true_or_false("PRICING_FALLBACK_ENABLED", "true"),
        log_level=log_level,
    )
    # Refreshing less often than prices expire would leave gaps in the cache.
    if settings.pricing_refresh_interval_s >= settings.pricing_cache_ttl_s:
        raise RuntimeError("PRICING_REFRESH_INTERVAL_S must be shorter than PRICING_CACHE_TTL_S")
    return settings


def _required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"{name} must be set")
    return value


def _number(name: str, default: str, kind: type):
    value = os.environ.get(name, default)
    try:
        return kind(value)
    except ValueError:
        raise RuntimeError(f"{name} must be a number, not {value!r}")


def _true_or_false(name: str, default: str) -> bool:
    # Only "true" or "false": a typo like "flase" must stop the service starting,
    # not silently switch the fallback off.
    value = os.environ.get(name, default).strip().lower()
    if value not in ("true", "false"):
        raise RuntimeError(f"{name} must be true or false, not {value!r}")
    return value == "true"
