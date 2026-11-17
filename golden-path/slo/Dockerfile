# A tiny, pinned image to run the SLO generator (golden-path/slo/generate.sh): nobody needs Python installed.
FROM python:3.12.16-slim-trixie
RUN pip install --no-cache-dir pyyaml==6.0.3
USER 10001
ENTRYPOINT ["python", "/work/golden-path/slo/generate.py"]
