# syntax=docker/dockerfile:1.6
ARG TARGETPLATFORM=linux/amd64
FROM --platform=${TARGETPLATFORM} python:3.11-slim

RUN apt-get update && apt-get install build-essential -y

# Install runtime deps for inference server
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir fastapi uvicorn xgboost pandas boto3

WORKDIR /app
# your FastAPI app (expects app.py with FastAPI() named "app")
COPY app.py .

# install the SageMaker-expected entrypoint
COPY serve /usr/local/bin/serve
RUN chmod +x /usr/local/bin/serve

ENV PORT=8080
EXPOSE 8080