# syntax=docker/dockerfile:1.7

# ---------- Build stage: install deps into a self-contained venv ----------
FROM python:3.12-slim AS builder

WORKDIR /build

COPY requirements.txt .

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"
RUN pip install --no-cache-dir -r requirements.txt

# ---------- Runtime stage: minimal, non-root, no build tooling ----------
FROM python:3.12-slim

LABEL org.opencontainers.image.title="hello-world-app" \
      org.opencontainers.image.description="Flask hello-world service" \
      org.opencontainers.image.source="https://example.com/repo/hello-world-app"

# Fixed, explicit UID/GID so it matches whatever securityContext.runAsUser
# Kubernetes applies at runtime and avoids depending on $HOME resolution.
RUN groupadd --system --gid 1000 app \
    && useradd --system --uid 1000 --gid app --home-dir /home/app --create-home app

WORKDIR /app

# Self-contained venv works regardless of which UID runs the process,
# since it doesn't rely on $HOME or user-site package resolution.
COPY --from=builder /opt/venv /opt/venv
COPY app.py .

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

EXPOSE 8080

USER app

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; \
      sys.exit(0) if urllib.request.urlopen('http://127.0.0.1:8080/').status==200 else sys.exit(1)"

CMD ["gunicorn", "--bind=0.0.0.0:8080", "--workers=2", "--threads=2", \
     "--timeout=30", "--access-logfile=-", "--error-logfile=-", "app:app"]

