FROM python:3.11-slim

WORKDIR /app

# Install dependencies first for optimal layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8002

CMD ["gunicorn", "--bind", "0.0.0.0:8002", "--workers", "2", "--timeout", "60", "app:app"]
