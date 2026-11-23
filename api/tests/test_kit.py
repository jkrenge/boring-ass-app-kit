import base64
import json
import time

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature, encode_dss_signature

import kit


def unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def test_token_from_headers():
    assert kit.token_from_headers({"authorization": "Bearer abc"}) == "abc"
    assert kit.token_from_headers({"app-key": "A-SH-abc"}) == "abc"
    assert kit.token_from_headers({"app-key": "A-EU-abc"}) is None
    assert kit.token_from_headers({"authorization": "Basic abc"}) is None
    assert kit.token_from_headers({}) is None


def test_new_token_survives_aptabase_app_key_split():
    assert len(f"A-SH-{kit.new_token()}".split("-")) == 3


def test_jwt_verifies_with_apple_style_p8_key():
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    # the Worker imports the key from DER; check pasted-with-literal-\n secrets still decode
    assert kit.pem_to_der(pem.replace("\n", "\\n")) == key.private_bytes(
        serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )

    signing_input = kit.jwt_signing_input("TEAM123", "KEY456", 1_700_000_000)
    r, s = decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    token = kit.jwt(signing_input, r.to_bytes(32, "big") + s.to_bytes(32, "big"))  # WebCrypto's r||s

    header, claims, sig = token.split(".")
    assert json.loads(unb64(header)) == {"alg": "ES256", "kid": "KEY456"}
    assert json.loads(unb64(claims)) == {"iss": "TEAM123", "iat": 1_700_000_000}
    raw = unb64(sig)
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    key.public_key().verify(der, f"{header}.{claims}".encode(), ec.ECDSA(hashes.SHA256()))


APTABASE_EVENT = {
    "timestamp": "2026-11-22T10:00:00Z",
    "sessionId": "1732269600123",
    "eventName": "app_started",
    "systemProps": {"isDebug": True, "locale": "en-US", "osName": "iOS", "osVersion": "27.1",
                    "appVersion": "1.0", "appBuildNumber": "1", "sdkVersion": "aptabase-swift@0.4.0",
                    "deviceModel": "iPhone17,1"},
    "props": {"plan": "free", "count": 3},
}


def test_parse_events():
    [event] = kit.parse_events([APTABASE_EVENT])
    assert event["name"] == "app_started" and event["is_debug"] and event["props"] == {"plan": "free", "count": 3}
    assert kit.parse_events([{**APTABASE_EVENT, "props": None}])[0]["props"] is None


@pytest.mark.parametrize("bad", [
    [],
    [APTABASE_EVENT] * 26,
    APTABASE_EVENT,
    [{**APTABASE_EVENT, "eventName": ""}],
    [{**APTABASE_EVENT, "eventName": "x" * 201}],
    [{**APTABASE_EVENT, "systemProps": "nope"}],
    ["nope"],
])
def test_parse_events_rejects(bad):
    with pytest.raises(ValueError):
        kit.parse_events(bad)


def test_too_deep():
    assert not kit.too_deep(json.dumps([APTABASE_EVENT] * 25))
    assert not kit.too_deep("[" * kit.MAX_DEPTH + "]" * kit.MAX_DEPTH)
    assert kit.too_deep("[" * (kit.MAX_DEPTH + 1))
    assert kit.too_deep("[" * 8000)  # the request that used to kill the isolate
    # brackets inside strings (incl. escaped quotes) don't count
    assert not kit.too_deep(json.dumps({"stack": "[" * 500, "q": 'say \\"[[[[\\"'}))
    # an unterminated string hides what follows it, which json.loads rejects anyway
    assert not kit.too_deep('"' + "[" * 500)
    assert kit.too_deep("[" * 500 + '"')


def test_too_deep_is_linear():
    # each unclosed quote used to rescan the rest of the body: ~30 s at this size
    start = time.perf_counter()
    kit.too_deep('\\"' * (kit.LIMITS["/api/v0/events"] // 2))
    kit.too_deep('"' * kit.LIMITS["/api/v0/events"])
    assert time.perf_counter() - start < 1


def test_clean_replaces_control_characters():
    dirty = {"name\x1b": ["\x1b]52;c;evil\x07", 3, None], "ok": "tab\tnew\nline ü", "c1": "\x9b31m"}
    assert kit.clean(dirty) == {"name�": ["�]52;c;evil�", 3, None], "ok": "tab\tnew\nline ü",
                                "c1": "�31m"}


def test_dumps_is_compact_and_rejects_nan():
    assert kit.dumps({"a": [1, 2], "b": "ü"}) == '{"a":[1,2],"b":"ü"}'
    with pytest.raises(ValueError):
        kit.dumps({"x": float("nan")})


def test_parse_version():
    assert kit.parse_version("1.4") == kit.parse_version("1.4.0") == (1, 4, 0)
    assert kit.parse_version("1.10") > kit.parse_version("1.9")
    for bad in ["", "1.", "v1.2", "1.2.3.4", "1.2 (3)", None, 1.2]:
        assert kit.parse_version(bad) is None


def test_update_for():
    apps = {"com.x.app": {"version": "1.4.0", "url": "https://apps.apple.com/app/id1"}}
    assert kit.update_for("com.x.app", {"version": "1.3.9"}, apps) == apps["com.x.app"]
    for ping in [{"version": "1.4"}, {"version": "2.0"}, {"version": "?"}, {}, [], None]:
        assert kit.update_for("com.x.app", ping, apps) is None
    assert kit.update_for("com.other", {"version": "0.1"}, apps) is None
    assert kit.update_for("com.x.app", {"version": "0.1"}, {"com.x.app": {"version": "oops", "url": ""}}) is None


def test_configured_apps_are_valid():
    for app in kit.APPS.values():  # a typo would quietly switch the prompt off
        assert kit.parse_version(app["version"]) and app["url"].startswith("https://apps.apple.com/")


def test_parse_register_feedback_error():
    assert kit.parse_register({"bundleId": "com.x.app"}) == {
        "bundle_id": "com.x.app", "device_check_token": None, "development": False}
    with pytest.raises(ValueError):
        kit.parse_register({"bundleId": 5})
    assert kit.parse_feedback({"message": "hi", "appVersion": "1.0"})["meta"]["appVersion"] == "1.0"
    with pytest.raises(ValueError):
        kit.parse_feedback({"message": ""})
    assert kit.parse_error({"errorType": "URLError", "errorMessage": "offline"})["type"] == "URLError"
    with pytest.raises(ValueError):
        kit.parse_crash([1, 2])
