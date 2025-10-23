FROM python:3.11-slim
RUN pip install --no-cache-dir boto3 pandas
WORKDIR /app
COPY score_batch.py .
CMD ["python","score_batch.py"]
