FROM python:3.11-slim
RUN pip install --no-cache-dir fastapi uvicorn xgboost pandas boto3
WORKDIR /app
COPY app.py .
ENV PORT=8080
EXPOSE 8080
CMD ["uvicorn","app:app","--host","0.0.0.0","--port","8080"]
