import base64
import json
import logging
import os
import uuid
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import ClientError

TABLE_NAME = os.environ.get("TABLE_NAME", "InventoryItems")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()

logger = logging.getLogger(__name__)
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

_dynamodb = None


def get_table():
    """Return a cached DynamoDB Table resource for TABLE_NAME."""
    global _dynamodb
    if _dynamodb is None:
        _dynamodb = boto3.resource("dynamodb")
    return _dynamodb.Table(TABLE_NAME)


def _utc_now_iso() -> str:
    """Return current UTC timestamp in ISO-8601 format."""
    return datetime.now(timezone.utc).isoformat()


def _json_default(obj: Any) -> Any:
    """Serialize Decimal values returned by DynamoDB into JSON numbers."""
    if isinstance(obj, Decimal):
        return int(obj) if obj % 1 == 0 else float(obj)
    raise TypeError(f"Type {type(obj).__name__} is not JSON serializable")


def _response(status_code: int, payload: dict[str, Any]) -> dict[str, Any]:
    """Build an API Gateway Lambda proxy JSON response."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(payload, default=_json_default),
    }


def _resolve_route(event: dict[str, Any]) -> str:
    """Resolve routeKey from HTTP API v2.0 or fallback to REST API v1.0."""
    route_key = event.get("routeKey")
    if isinstance(route_key, str) and route_key and route_key != "$default":
        return route_key

    # HTTP API v2.0 $default fallback
    http_ctx = (event.get("requestContext") or {}).get("http") or {}
    if http_ctx.get("method") and event.get("rawPath"):
        method = str(http_ctx["method"]).upper()
        raw_path = str(event["rawPath"]).rstrip("/") or "/"
        if raw_path.startswith("/items/") and len(raw_path.split("/")) == 3:
            return f"{method} /items/{{id}}"
        return f"{method} {raw_path}"

    # REST API v1.0 compatibility
    http_method = event.get("httpMethod")
    resource = event.get("resource") or event.get("path")
    if http_method and resource:
        return f"{str(http_method).upper()} {resource}"

    return ""


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    """Parse JSON request body safely, handling base64 encoding and type checks."""
    raw = event.get("body")
    if raw is None or raw == "":
        return {}
    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, str):
        raise ValueError("Format body request tidak didukung.")

    if event.get("isBase64Encoded"):
        try:
            raw = base64.b64decode(raw).decode("utf-8")
        except Exception as exc:
            raise ValueError("Body base64 tidak valid.") from exc

    parsed = json.loads(raw)
    if not isinstance(parsed, dict):
        raise ValueError("Body JSON harus berupa object ({...}).")
    return parsed


def _validate_non_empty_str(value: Any, field_name: str) -> str:
    """Ensure a field is a non-empty string after trimming whitespace."""
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Field '{field_name}' harus berupa teks dan tidak boleh kosong.")
    return value.strip()


def _to_non_negative_decimal(value: Any, field_name: str) -> Decimal:
    """Convert numeric input to a finite non-negative Decimal."""
    if isinstance(value, bool) or value is None or isinstance(value, (dict, list)):
        raise ValueError(f"Field '{field_name}' harus berupa angka valid.")
    try:
        dec = Decimal(str(value).strip())
    except (InvalidOperation, ValueError, TypeError) as exc:
        raise ValueError(f"Field '{field_name}' harus berupa angka valid.") from exc

    if not dec.is_finite():
        raise ValueError(f"Field '{field_name}' harus berupa angka finite (bukan NaN/Infinity).")
    if dec < 0:
        raise ValueError(f"Field '{field_name}' tidak boleh negatif.")
    return dec


def _to_non_negative_int(value: Any, field_name: str) -> int:
    """Convert numeric input to a non-negative integer, rejecting decimals like 3.7."""
    dec = _to_non_negative_decimal(value, field_name)
    if dec != dec.to_integral_value():
        raise ValueError(f"Field '{field_name}' harus berupa bilangan bulat non-negatif.")
    return int(dec)


def _extract_item_id(event: dict[str, Any]) -> str | None:
    """Extract item id from pathParameters or rawPath/path (for Lambda Function URL)."""
    path_params = event.get("pathParameters") or {}
    if path_params.get("id"):
        return str(path_params["id"])

    raw_path = str(event.get("rawPath") or event.get("path") or "").rstrip("/")
    if raw_path.startswith("/items/"):
        parts = [p for p in raw_path.split("/") if p]
        if len(parts) == 2 and parts[0] == "items" and parts[1]:
            return parts[1]
    return None


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """AWS Lambda entrypoint for the Inventory CRUD microservice."""
    route_key = _resolve_route(event)
    item_id = _extract_item_id(event)
    table = get_table()

    if route_key.startswith("OPTIONS "):
        return _response(200, {"ok": True})

    logger.info(
        json.dumps(
            {
                "event": "request_received",
                "route": route_key,
                "item_id": item_id,
                "table": TABLE_NAME,
            }
        )
    )

    try:
        if route_key == "GET /":
            return _response(
                200,
                {
                    "service": "inventory-service",
                    "track": "Track C (Serverless)",
                    "author": "Bagas Adjie Pamungkas (544718)",
                    "table": TABLE_NAME,
                    "endpoints": [
                        "GET /",
                        "GET /ui",
                        "GET /health",
                        "POST /items",
                        "GET /items",
                        "GET /items/{id}",
                        "PUT /items/{id}",
                        "DELETE /items/{id}",
                    ],
                },
            )

        if route_key == "GET /ui":
            base_dir = Path(__file__).resolve().parent
            ui_candidates = [base_dir / "index.html", base_dir.parent / "frontend" / "index.html"]
            ui_file = next((p for p in ui_candidates if p.exists()), None)
            if ui_file is None:
                return _response(404, {"error": "UI dashboard tidak ditemukan."})
            return {
                "statusCode": 200,
                "headers": {
                    "Content-Type": "text/html; charset=utf-8",
                    "Access-Control-Allow-Origin": "*",
                },
                "body": ui_file.read_text(encoding="utf-8"),
            }

        if route_key == "GET /health":
            # Lightweight GetItem verifies real DynamoDB + IAM LabRole connectivity.
            table.get_item(Key={"item_id": "__health_probe__"})
            return _response(
                200,
                {
                    "status": "healthy",
                    "service": "inventory-service",
                    "table": TABLE_NAME,
                    "dynamodb": "connected",
                    "timestamp": _utc_now_iso(),
                },
            )

        if route_key == "POST /items":
            body = _parse_body(event)
            for req in ("sku", "name", "quantity", "unit_price"):
                if req not in body or body[req] is None:
                    return _response(400, {"error": f"Field wajib '{req}' belum diisi."})

            sku = _validate_non_empty_str(body["sku"], "sku")
            name = _validate_non_empty_str(body["name"], "name")
            quantity = _to_non_negative_int(body["quantity"], "quantity")
            unit_price = _to_non_negative_decimal(body["unit_price"], "unit_price")

            category = (
                _validate_non_empty_str(body["category"], "category")
                if body.get("category") is not None
                else "General"
            )
            location = (
                _validate_non_empty_str(body["location"], "location")
                if body.get("location") is not None
                else "Unassigned"
            )

            now = _utc_now_iso()
            item = {
                "item_id": str(uuid.uuid4()),
                "sku": sku,
                "name": name,
                "category": category,
                "quantity": quantity,
                "unit_price": unit_price,
                "location": location,
                "created_at": now,
                "updated_at": now,
            }
            table.put_item(Item=item)
            logger.info(json.dumps({"event": "item_created", "item_id": item["item_id"], "sku": sku}))
            return _response(201, item)

        if route_key == "GET /items":
            items: list[dict[str, Any]] = []
            scan_kwargs: dict[str, Any] = {}
            max_pages = 20
            pages = 0
            last_key = None

            while pages < max_pages:
                if last_key:
                    scan_kwargs["ExclusiveStartKey"] = last_key
                result = table.scan(**scan_kwargs)
                items.extend(result.get("Items", []))
                last_key = result.get("LastEvaluatedKey")
                pages += 1
                if not last_key:
                    break

            items.sort(key=lambda row: str(row.get("updated_at", "")), reverse=True)
            return _response(
                200,
                {
                    "items": items,
                    "count": len(items),
                    "truncated": bool(last_key),
                },
            )

        if route_key == "GET /items/{id}":
            item_id_clean = _validate_non_empty_str(item_id, "id")
            result = table.get_item(Key={"item_id": item_id_clean})
            item = result.get("Item")
            if not item:
                return _response(404, {"error": f"Item '{item_id_clean}' tidak ditemukan."})
            return _response(200, item)

        if route_key == "PUT /items/{id}":
            item_id_clean = _validate_non_empty_str(item_id, "id")
            body = _parse_body(event)
            allowed = ("sku", "name", "category", "quantity", "unit_price", "location")
            updates = {k: body[k] for k in allowed if k in body}
            if not updates:
                return _response(400, {"error": "Minimal satu field valid harus diperbarui."})

            expr_parts: list[str] = []
            expr_names: dict[str, str] = {}
            expr_vals: dict[str, Any] = {}

            for key, raw_val in updates.items():
                if key == "quantity":
                    val: Any = _to_non_negative_int(raw_val, "quantity")
                elif key == "unit_price":
                    val = _to_non_negative_decimal(raw_val, "unit_price")
                else:
                    val = _validate_non_empty_str(raw_val, key)
                expr_names[f"#{key}"] = key
                expr_vals[f":{key}"] = val
                expr_parts.append(f"#{key} = :{key}")

            expr_names["#updated_at"] = "updated_at"
            expr_vals[":updated_at"] = _utc_now_iso()
            expr_parts.append("#updated_at = :updated_at")

            result = table.update_item(
                Key={"item_id": item_id_clean},
                UpdateExpression="SET " + ", ".join(expr_parts),
                ExpressionAttributeNames=expr_names,
                ExpressionAttributeValues=expr_vals,
                ConditionExpression="attribute_exists(item_id)",
                ReturnValues="ALL_NEW",
            )
            logger.info(json.dumps({"event": "item_updated", "item_id": item_id_clean}))
            return _response(200, result["Attributes"])

        if route_key == "DELETE /items/{id}":
            item_id_clean = _validate_non_empty_str(item_id, "id")
            result = table.delete_item(
                Key={"item_id": item_id_clean},
                ReturnValues="ALL_OLD",
            )
            if "Attributes" not in result:
                return _response(404, {"error": f"Item '{item_id_clean}' tidak ditemukan."})
            logger.info(json.dumps({"event": "item_deleted", "item_id": item_id_clean}))
            return _response(200, {"deleted": item_id_clean})

        return _response(404, {"error": f"Route '{route_key}' tidak dikenali."})

    except json.JSONDecodeError:
        logger.warning(json.dumps({"event": "invalid_json", "route": route_key}))
        return _response(400, {"error": "Format body JSON tidak valid."})
    except ValueError as exc:
        logger.warning(json.dumps({"event": "validation_error", "route": route_key, "detail": str(exc)}))
        return _response(400, {"error": str(exc)})
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "ConditionalCheckFailedException":
            return _response(404, {"error": f"Item '{item_id}' tidak ditemukan."})
        logger.exception("DynamoDB ClientError on route %s (code=%s)", route_key, code)
        return _response(500, {"error": "Kesalahan layanan DynamoDB.", "detail": code})
    except Exception:
        logger.exception("Unhandled exception on route %s", route_key)
        return _response(500, {"error": "Internal server error."})
