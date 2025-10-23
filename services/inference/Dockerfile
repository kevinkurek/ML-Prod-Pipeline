# syntax=docker/dockerfile:1.6
ARG TARGETPLATFORM=linux/amd64
FROM --platform=${TARGETPLATFORM} python:3.11-slim

RUN apt-get update && apt-get install build-essential -y

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir fastapi uvicorn xgboost pandas boto3

WORKDIR /app
COPY app.py .
ENV PORT=8080
EXPOSE 8080
CMD ["uvicorn","app:app","--host","0.0.0.0","--port","8080"]