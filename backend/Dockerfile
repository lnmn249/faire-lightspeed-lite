# Use lightweight Python image
FROM python:3.12-slim

# Set working directory
WORKDIR /app

# Install system deps (for pandas, numpy, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for caching
COPY requirements.txt .

# Install Python deps
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the app
COPY . .

# Expose the Cloud Run port
ENV PORT=8080

# Run FastAPI with uvicorn on the correct host/port
CMD exec uvicorn lightspeed_xseries_service_4:app --host 0.0.0.0 --port $PORT
