import json
import os
import uuid
from flask import Flask, jsonify, request
import boto3

app = Flask(__name__)
EVENT_BUS_NAME = os.environ.get("EVENT_BUS_NAME", "")
AWS_REGION = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
events = boto3.client("events", region_name=AWS_REGION) if EVENT_BUS_NAME else None

@app.get("/health")
def health():
    return jsonify(status="healthy"), 200

@app.get("/")
def index():
    return jsonify(
        service="SIS 3 Orders API",
        health="/health",
        event_endpoint="POST /events"
    ), 200

@app.post("/events")
def publish_event():
    if not events or not EVENT_BUS_NAME:
        return jsonify(error="EVENT_BUS_NAME is not configured"), 500

    payload = request.get_json(silent=True) or {}
    event_id = payload.get("eventId") or str(uuid.uuid4())
    detail = {
        "eventId": event_id,
        "eventType": payload.get("eventType", "OrderCreated"),
        "orderId": payload.get("orderId", "demo-order-001"),
        "message": payload.get("message", "SIS 3 demo event")
    }

    try:
        result = events.put_events(
            Entries=[{
                "Source": "sis3.orders",
                "DetailType": detail["eventType"],
                "Detail": json.dumps(detail),
                "EventBusName": EVENT_BUS_NAME
            }]
        )
        if result.get("FailedEntryCount", 0):
            return jsonify(error="EventBridge rejected the event", result=result), 502
        return jsonify(status="published", event=detail, eventBridgeResult=result), 202
    except Exception as exc:
        app.logger.exception("Failed to publish event")
        return jsonify(error=str(exc)), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
