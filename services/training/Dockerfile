# syntax=docker/dockerfile:1.6
ARG TARGETPLATFORM=linux/amd64
FROM --platform=${TARGETPLATFORM} python:3.11-slim

RUN apt-get update && apt-get install build-essential -y

# Install dependencies
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir xgboost==2.1.1 scikit-learn pandas boto3

# SageMaker-friendly dirs
RUN mkdir -p /opt/ml/code /opt/ml/model /opt/ml/checkpoints /opt/ml/input/data/train
WORKDIR /opt/ml/code
ENV PYTHONUNBUFFERED=1

COPY train.py /opt/ml/code/train.py
ENTRYPOINT ["python", "/opt/ml/code/train.py"]