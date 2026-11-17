# Order validation service image, in three stages:
#   base     Python and the runtime libraries
#   test     base + test libraries + tests (published as order-validation-tests, run by `helm test`)
#   runtime  base + the app, as a non-root user (the last stage, so the default)
FROM python:3.12.16-slim-trixie AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM base AS test
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY pytest.ini .
COPY app ./app
COPY tests ./tests
USER 10001
CMD ["python", "-m", "pytest", "-v", "-p", "no:cacheprovider"]

FROM base AS runtime
COPY app ./app
# A fixed non-root user id: if the app is ever broken into, it isn't root.
USER 10001
EXPOSE 8080
# --no-access-log: one log line per request at 600 req/s costs far more than it
# tells us; metrics count requests instead.
# --timeout-graceful-shutdown: on stop, finish in-flight requests for up to 10 s.
# opentelemetry-instrument: adds metrics and traces for FastAPI, httpx and asyncpg with no code.
CMD ["opentelemetry-instrument", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log", "--timeout-graceful-shutdown", "10"]
