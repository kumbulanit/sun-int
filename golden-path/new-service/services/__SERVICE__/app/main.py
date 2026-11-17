"""__SERVICE__: a starter service from the golden path.

Replace /hello with your own routes. Keep /healthz and /readyz (the chart's health checks)
and the opentelemetry-instrument launcher in the Dockerfile (it measures your SLI).
"""
from fastapi import FastAPI

app = FastAPI(title="__SERVICE__")


@app.get("/healthz")
def healthz() -> dict:
    """Liveness: the process is up. Failing this restarts the pod."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict:
    """Readiness: started and able to serve. Never check shared dependencies here:
    every pod shares them, so all pods would be taken out at once."""
    return {"status": "ready"}


@app.get("/hello")
def hello() -> dict:
    return {"message": "hello from __SERVICE__"}
