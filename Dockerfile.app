ARG BASE_IMAGE=chat-app-base:latest
FROM ${BASE_IMAGE}

# Lightweight layer for fast iteration: only app-specific (and optional extra) deps + source code.
WORKDIR /app

# Copy (optional) fast-changing, small dependency file; install only if non-empty.
COPY requirements_app.txt ./requirements_app.txt
RUN if [ -s requirements_app.txt ]; then \
			echo "Installing incremental app requirements" && \
			pip3 install --no-cache-dir -r requirements_app.txt; \
		else \
			echo "No incremental app requirements (requirements_app.txt empty)."; \
		fi

# Copy application source.
COPY app ./app

# Ensure profiles output dir exists (hostPath volume may mount over it later).
RUN mkdir -p /app/profiles/torch

ENV PYTHONUNBUFFERED=1 \
		UVICORN_WORKERS=1 \
		PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
	CMD curl -fs http://127.0.0.1:8080/healthz || exit 1

LABEL org.opencontainers.image.title="chat-app" \
			org.opencontainers.image.description="Chat inference API layer (app code)" \
			org.opencontainers.image.source="https://github.com/hsunwenfang/nvv100"

CMD ["python3", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
