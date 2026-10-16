# Pinned base image -> reproducible build.
FROM python:3.12.11-alpine3.21

WORKDIR /app
COPY app.py /app/app.py

# Non-root for hygiene; container is internal-network-only anyway.
RUN addgroup -S app && adduser -S app -G app \
    && chown -R app:app /app
USER app

EXPOSE 9000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=6 \
  CMD wget -q -O /dev/null http://127.0.0.1:9000/health || exit 1

CMD ["python", "/app/app.py"]
