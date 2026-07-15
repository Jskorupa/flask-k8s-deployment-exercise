# syntax=docker/dockerfile:1.7

# ---------- Build stage: install deps into an isolated prefix ----------
FROM python:3.12-slim AS builder

WORKDIR /build

COPY requirements.txt .

RUN pip install --no-cache-dir --user -r requirements.txt

# ---------- Runtime stage: minimal, non-root, no build tooling ----------
FROM python:3.12-slim

# Metadata for traceability across many similar app images
LABEL org.opencontainers.image.title="hello-world-app" \
      org.opencontainers.image.description="Flask hello-world service" \
      org.opencontainers.image.source="https://example.com/repo/hello-world-app"

# Create an unprivileged, home-less system user to run the app as
RUN addgroup --system app && adduser --system --ingroup app --home /home/app app

WORKDIR /app

# Bring in only the installed packages from the builder stage
COPY --from=builder /root/.local /home/app/.local
COPY app.py .

ENV PATH="/home/app/.local/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Container-internal port only. This is NOT a host port binding —
# Kubernetes Services/Ingress handle external exposure, so the Pod
# is never pinned to a static port on the underlying node.
EXPOSE 8080

USER app

# Basic liveness check usable outside k8s too (e.g. docker run, CI)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; \
      sys.exit(0) if urllib.request.urlopen('http://127.0.0.1:8080/').status==200 else sys.exit(1)"

# Production WSGI server (never use `flask run` / app.run() in prod).
# Worker count kept modest; horizontal scaling is handled by k8s HPA,
# not by stacking workers/pods vertically.
CMD ["gunicorn", "--bind=0.0.0.0:8080", "--workers=2", "--threads=2", \
     "--timeout=30", "--access-logfile=-", "--error-logfile=-", "app:app"]
