import json
import time
import uuid
from urllib.parse import urlparse

from js import Object, crypto
from pyodide.ffi import jsnull, to_js
from workers import Response, WorkerEntrypoint, fetch

import kit

DEVICECHECK = {
    False: "https://api.devicecheck.apple.com/v1/validate_device_token",
    True: "https://api.development.devicecheck.apple.com/v1/validate_device_token",
}


def js_obj(value):
    return to_js(value, dict_converter=Object.fromEntries)


def error(status: int, message: str):
    return Response.json({"error": message}, status=status)


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        path = urlparse(request.url).path
        if request.method != "POST" or path not in kit.LIMITS:
            return error(404, "not found")
        length = request.headers.get("content-length") or ""
        if length.isdigit() and int(length) > kit.LIMITS[path]:
            return error(413, "body too large")

        if path == "/v1/register":
            device_id = None
            # Cloudflare sets cf-connecting-ip; it's absent under `pywrangler dev`
            limiter, key = self.env.REGISTER_LIMIT, request.headers.get("cf-connecting-ip") or "local"
        else:
            token = kit.token_from_headers(request.headers)
            device_id = token and await self.device_id(token)
            if not device_id:
                return error(401, "unknown device")
            limiter, key = self.env.DEVICE_LIMIT, str(device_id)

        body = await request.text()  # chunked bodies have no content-length, so check again
        if len(body) > kit.LIMITS[path]:
            return error(413, "body too large")
        # big crash reports cost more of the per-device budget
        if not await self.allowed(limiter, key, cost=1 + len(body) // 100_000):
            return error(429, "slow down")
        if kit.too_deep(body):
            return error(400, "JSON nested too deeply")
        try:
            data = json.loads(body)
            match path:
                case "/v1/register":
                    return await self.register(kit.parse_register(data))
                case "/v1/ping":
                    pass  # reaching here means the token is valid
                case "/api/v0/events":
                    await self.save_events(device_id, kit.parse_events(data))
                case "/api/v0/error":
                    e = kit.parse_error(data)
                    await self.sql(
                        "INSERT INTO errors (device_id, type, message, is_debug, report) VALUES (?, ?, ?, ?, ?)",
                        device_id, e["type"], e["message"], int(e["is_debug"]), kit.dumps(e["report"]),
                    ).run()
                case "/v1/crashes":
                    report = kit.dumps(kit.parse_crash(data))
                    await self.sql("INSERT INTO crashes (device_id, report) VALUES (?, ?)", device_id, report).run()
                case "/v1/feedback":
                    f = kit.parse_feedback(data)
                    await self.sql(
                        "INSERT INTO feedback (device_id, message, email, meta) VALUES (?, ?, ?, ?)",
                        device_id, f["message"], f["email"], kit.dumps(f["meta"]),
                    ).run()
        except ValueError as e:  # also catches json.JSONDecodeError
            return error(400, str(e))
        return Response.json({"ok": True})

    async def allowed(self, limiter, key: str, cost: int) -> bool:
        # shortcut: Cloudflare rate limits are approximate and per location; a per-device daily quota
        # in D1 would be the next step if one device ever floods the database
        result = await limiter.limit(js_obj({"key": key, "delta": cost}))
        return bool(result.success)

    def sql(self, query: str, *args):
        # D1 rejects `undefined`, which is what Python None becomes, so pass JS null explicitly
        return self.env.DB.prepare(query).bind(*[jsnull if a is None else a for a in args])

    async def device_id(self, token: str) -> int | None:
        value = await self.sql("SELECT id FROM devices WHERE token_hash = ?", kit.hash_token(token)).first("id")
        return int(value) if isinstance(value, (int, float)) else None

    async def save_events(self, device_id: int, events: list[dict]):
        # One statement for the whole batch: DB.batch() hits Pyodide borrowed-proxy errors,
        # and 25 rows x 7 params would blow D1's 100-bound-params limit.
        await self.sql(
            """INSERT INTO events (device_id, ts, session_id, name, props, system, is_debug)
               SELECT ?, value->>'ts', value->>'session_id', value->>'name',
                      value->>'props', value->>'system', value->>'is_debug'
               FROM json_each(?)""",
            device_id, kit.dumps(events),
        ).run()

    async def register(self, req: dict):
        if req["device_check_token"]:
            if not await self.apple_says_genuine(req["device_check_token"], req["development"]):
                return error(403, "device check failed")
        elif getattr(self.env, "ALLOW_UNATTESTED", "") != "true":
            return error(403, "device check token required")

        token = kit.new_token()
        await self.sql(
            "INSERT INTO devices (token_hash, bundle_id, attested) VALUES (?, ?, ?)",
            kit.hash_token(token), req["bundle_id"], int(bool(req["device_check_token"])),
        ).run()
        return Response.json({"token": token})

    async def apple_says_genuine(self, device_token: str, development: bool) -> bool:
        """Apple DeviceCheck: is this token from a real Apple device running one of our apps?"""
        signing_input = kit.jwt_signing_input(self.env.APPLE_TEAM_ID, self.env.APPLE_KEY_ID, time.time())
        key = await crypto.subtle.importKey(
            "pkcs8", to_js(kit.pem_to_der(self.env.APPLE_DEVICECHECK_KEY)),
            js_obj({"name": "ECDSA", "namedCurve": "P-256"}), False, to_js(["sign"]),
        )
        signature = await crypto.subtle.sign(js_obj({"name": "ECDSA", "hash": "SHA-256"}), key, to_js(signing_input))

        resp = await fetch(
            DEVICECHECK[development],
            method="POST",
            headers={"Authorization": f"Bearer {kit.jwt(signing_input, signature.to_bytes())}"},
            body=json.dumps({
                "device_token": device_token,
                "transaction_id": str(uuid.uuid4()),
                "timestamp": int(time.time() * 1000),
            }),
        )
        if resp.status != 200:
            # 401 here means our Apple key/team/key id is wrong, not the device
            print(f"devicecheck rejected: {resp.status} {await resp.text()}")
        return resp.status == 200
