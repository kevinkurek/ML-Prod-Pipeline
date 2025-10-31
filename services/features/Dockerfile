FROM python:3.11-slim

RUN pip install --no-cache-dir boto3 pandas numpy pyarrow

COPY build_features.py /opt/app/build_features.py
ENTRYPOINT ["python", "/opt/app/build_features.py"]