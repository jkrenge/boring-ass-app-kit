"""Pure helpers (no `js`/`workers` imports) so pytest can load them outside the Workers runtime."""

import base64
import hashlib
import json
import re
import secrets

# Max request body size per route, in characters. D1 caps a row at 2 MB.
LIMITS = {
    "/v1/register": 8_000,
    "/api/v0/events": 128_000,
    "/api/v0/error": 64_000,
    "/v1/crashes": 1_500_000,
    "/v1/feedback": 32_000,
}


def token_from_headers(headers) -> str | None:
    auth = headers.get("authorization") or ""
    if auth.startswith("Bearer "):
        return auth[7:].strip() or None
    # aptabase-swift only lets us set its App-Key, so the device token rides in it as A-SH-<token>
    key = headers.get("app-key") or ""
    if key.startswith("A-SH-"):
        return key[5:] or None
    return None


def new_token() -> str:
    # hex on purpose: aptabase-swift rejects an App-Key that doesn't split into exactly 3 parts on "-"
    return secrets.token_hex(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwt_signing_input(team_id: str, key_id: str, now: float) -> bytes:
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id}).encode())
    claims = b64url(json.dumps({"iss": team_id, "iat": int(now)}).encode())
    return f"{header}.{claims}".encode()


def jwt(signing_input: bytes, raw_signature: bytes) -> str:
    """raw_signature is r||s (64 bytes), which is what WebCrypto ECDSA returns and what JWS wants."""
    return f"{signing_input.decode()}.{b64url(raw_signature)}"


def pem_to_der(pem: str) -> bytes:
    # tolerate real newlines and literal "\n" (how multi-line secrets often get pasted)
    return base64.b64decode(re.sub(r"-----[^-]+-----|\\n|\s", "", pem))


# --- request validation (trust boundary: everything below comes from devices) ---


def _str(obj: dict, key: str, max_len: int, required: bool = True) -> str | None:
    value = obj.get(key)
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value or len(value) > max_len:
        raise ValueError(f"{key}: expected a non-empty string of at most {max_len} chars")
    return value


def _dict(obj: dict, key: str, required: bool = True) -> dict | None:
    value = obj.get(key)
    if value is None and not required:
        return None
    if not isinstance(value, dict):
        raise ValueError(f"{key}: expected an object")
    return value


def _obj(data) -> dict:
    if not isinstance(data, dict):
        raise ValueError("expected a JSON object")
    return data


def parse_register(data) -> dict:
    data = _obj(data)
    return {
        "bundle_id": _str(data, "bundleId", 200),
        "device_check_token": _str(data, "deviceCheckToken", 6_000, required=False),
        "development": data.get("development") is True,
    }


def parse_events(data) -> list[dict]:
    """Aptabase batch: a list of up to 25 events, see aptabase-swift Event.swift."""
    if not isinstance(data, list) or not 1 <= len(data) <= 25:
        raise ValueError("expected a list of 1-25 events")
    events = []
    for event in data:
        event = _obj(event)
        system = _dict(event, "systemProps")
        events.append({
            "ts": _str(event, "timestamp", 40),
            "session_id": _str(event, "sessionId", 100),
            "name": _str(event, "eventName", 200),
            "props": _dict(event, "props", required=False),
            "system": system,
            "is_debug": system.get("isDebug") is True,
        })
    return events


def parse_error(data) -> dict:
    """Aptabase error report, see aptabase-swift ErrorReport.swift."""
    data = _obj(data)
    return {
        "type": _str(data, "errorType", 200),
        "message": _str(data, "errorMessage", 10_000),
        "is_debug": data.get("isDebug") is True,
        "report": data,
    }


def parse_crash(data) -> dict:
    # A KSCrash report; stored as-is, query it with json_extract.
    return _obj(data)


def parse_feedback(data) -> dict:
    data = _obj(data)
    return {
        "message": _str(data, "message", 5_000),
        "email": _str(data, "email", 200, required=False),
        "meta": {k: data.get(k) for k in ("appVersion", "osVersion", "deviceModel", "isDebug")},
    }
