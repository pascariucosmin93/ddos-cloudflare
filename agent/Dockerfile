FROM python:3.12-alpine

RUN apk add --no-cache iptables

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py .

USER root
CMD ["python", "agent.py"]
