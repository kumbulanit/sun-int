"""Fake pricing service, for local runs, tests and the incident drill.

POST /prices        {"skus": [...]} -> {"prices": {sku: price}}. Like a real service, it
                    prices only the SKUs asked about and leaves out ones it doesn't know.
                    Needs the bearer token.
POST /admin/mode    the misbehave switch: normal | slow | error | auth_fail. Goes back to
                    normal by itself after duration_s.
GET  /admin/mode    the current mode and the seconds left
GET  /healthz       liveness

Prices are made up but stable: the SKU number x 100, so SKU-0001 costs 100 and
SKU-0048 costs 4800.
"""
import asyncio
import os
import random
import re
import time

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

TOKEN = os.environ["PRICING_TOKEN"]          # required: won't start without it
SKU = re.compile(r"SKU-(\d{4})")

app = FastAPI(title="Fake pricing")


class Mode(BaseModel):
    mode: str = Field("normal", pattern="^(normal|slow|error|auth_fail)$")
    slow_pct: int = Field(20, ge=0, le=100)        # slow: share of calls that are slow
    slow_ms_min: int = Field(2000, ge=0)           # ...and how slow (a random time in this range)
    slow_ms_max: int = Field(5000, ge=0)
    error_pct: int = Field(20, ge=0, le=100)       # error: share of calls that get a 500
    duration_s: int = Field(300, ge=1, le=3600)    # then back to normal by itself


current = Mode()
ends_at = 0.0                                      # when the current mode ends (monotonic clock)


def active_mode() -> Mode:
    if current.mode != "normal" and time.monotonic() >= ends_at:
        return Mode()                              # time's up: back to normal
    return current


class PriceRequest(BaseModel):
    skus: list[str]


@app.post("/prices")
async def prices(body: PriceRequest, authorization: str = Header(default="")):
    mode = active_mode()
    if mode.mode == "auth_fail" or authorization != f"Bearer {TOKEN}":
        raise HTTPException(status_code=401, detail="invalid credentials")
    if mode.mode == "slow" and random.random() * 100 < mode.slow_pct:
        await asyncio.sleep(random.uniform(mode.slow_ms_min, mode.slow_ms_max) / 1000)
    if mode.mode == "error" and random.random() * 100 < mode.error_pct:
        raise HTTPException(status_code=500, detail="pricing failed")
    found = {}
    for sku in body.skus:
        match = SKU.fullmatch(sku)
        if match:
            found[sku] = int(match.group(1)) * 100
    return {"prices": found}


@app.post("/admin/mode")
async def set_mode(new: Mode):
    global current, ends_at
    current, ends_at = new, time.monotonic() + new.duration_s
    return describe()


@app.get("/admin/mode")
async def get_mode():
    return describe()


def describe() -> dict:
    mode = active_mode()
    seconds_left = max(0, round(ends_at - time.monotonic())) if mode.mode != "normal" else 0
    return {**mode.model_dump(), "seconds_left": seconds_left}


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}
