# __SERVICE__'s image: a pinned base and a non-root user (the pipeline's policy gate checks both).
FROM python:3.12.16-slim-trixie
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
USER 10001
EXPOSE 8080
# opentelemetry-instrument: request metrics (your SLI) and traces, with no telemetry code.
# --no-access-log: a log line per request costs more than it tells; metrics count requests.
CMD ["opentelemetry-instrument", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
