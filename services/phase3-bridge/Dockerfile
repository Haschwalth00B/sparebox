FROM python:3.13-alpine

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY --chown=65532:65532 bridge.py /app/bridge.py

USER 65532:65532

EXPOSE 8080

CMD ["python", "-B", "/app/bridge.py"]
