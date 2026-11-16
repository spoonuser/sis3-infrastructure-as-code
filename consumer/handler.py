import json
import logging
import os
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ["IDEMPOTENCY_TABLE"]
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)

def lambda_handler(event, context):
    for record in event.get("Records", []):
        body = json.loads(record["body"])
        # EventBridge target sends the event detail as the SQS message body.
        detail = body.get("detail", body) if isinstance(body, dict) else {}
        event_id = detail.get("eventId") or record.get("messageId")

        if not event_id:
            logger.error("Message has no eventId or SQS messageId; failing for retry/DLQ")
            raise ValueError("Missing idempotency key")

        try:
            table.put_item(
                Item={"eventId": str(event_id), "processedAt": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()},
                ConditionExpression="attribute_not_exists(eventId)"
            )
            logger.info("PROCESSED eventId=%s detail=%s", event_id, json.dumps(detail))
            # Put the business action here. Keep it after the conditional claim,
            # or use a transactional/outbox pattern for non-demo production workloads.
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                logger.info("DUPLICATE eventId=%s - business action skipped", event_id)
                continue
            raise

    return {"statusCode": 200, "body": "processed"}
