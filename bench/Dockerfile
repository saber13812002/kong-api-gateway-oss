# Pinned base image -> reproducible build. Temp benchmark client only;
# joins the internal kong-gw-trial-net network at runtime, no host ports.
FROM python:3.12.11-alpine3.21

WORKDIR /app
COPY bench.py /app/bench.py

CMD ["python", "/app/bench.py"]
