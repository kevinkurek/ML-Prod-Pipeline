FROM python:3.11-slim
RUN pip install --no-cache-dir xgboost==2.1.1 scikit-learn pandas boto3
WORKDIR /app
COPY train.py .
ENV ARTIFACTS_BUCKET=REPLACE_ME_BUCKET
ENV MODEL_KEY=models/condor_xgb.json
CMD ["python","train.py"]
