FROM python:3.12-alpine

RUN apk add --no-cache iptables conntrack-tools

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py .

USER root
CMD ["gunicorn", "--workers", "1", "--threads", "8", "--bind", "0.0.0.0:8080", "--timeout", "120", "agent:app"]
