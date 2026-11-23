# boring-ass-app-kit

Crash reporting, feedback and basic usage analytics for my iOS apps, with no paid product involved.

| Piece | What | Where |
|---|---|---|
| Crashes | [KSCrash](https://github.com/kstenerud/KSCrash) (signals, Mach and ObjC/C++ exceptions, hangs and watchdog kills), plus its MetricKit monitor, which adds the crash reports iOS itself collects | `Sources/BoringKit` |
| Analytics + handled errors | [aptabase-swift](https://github.com/aptabase/aptabase-swift), pointed at our Worker | `Sources/BoringKit` |
| Feedback | `FeedbackView` (SwiftUI sheet) or `BoringKit.sendFeedback(_:)` | `Sources/BoringKit` |
| Update prompt | `.updatePrompt()` asks users on an old version to update, linking to the App Store | `Sources/BoringKit`, `APPS` in `api/src/kit.py` |
| API | Python Cloudflare Worker + D1 (SQLite) | `api/` |
| Device check | Apple DeviceCheck: a device registers once, then sends its token on every request | both |

## How it fits together

1. `BoringKit.start(api:)` installs KSCrash right away, then registers the device: it asks Apple's DeviceCheck for a token and posts it to `POST /v1/register`.
2. The Worker asks Apple whether the token is genuine. If it is, the Worker hands back a random device token and stores its sha256 in `devices`.
3. The app keeps that token in the Keychain (this device only) and sends it with everything else. Requests without a known token get a 401. On each launch the app also checks its token with `POST /v1/ping` and registers again if it got a 401. The ping carries the app's version, and the reply says whether a newer one is out.
4. Aptabase sends to `/api/v0/events` and `/api/v0/error` with the token in its `App-Key` header (`A-SH-<token>`). Crash reports and feedback go to `/v1/crashes` and `/v1/feedback` with `Authorization: Bearer <token>`.

Each device gets about 120 requests a minute (large crash reports count for more), and each IP gets 10 registrations a minute. Past that, the Worker returns 429.

The Simulator can't make DeviceCheck tokens. The Worker accepts tokenless registration only when `ALLOW_UNATTESTED=true`, which is set in `api/.dev.vars` for local dev and never in production.

## One-time setup

**Apple:** in the developer portal, go to Certificates, IDs & Profiles → Keys and create a key with **DeviceCheck** enabled. Download `AuthKey_XXXXXXXXXX.p8` and note its Key ID and your Team ID. One key covers all apps in the team, and apps need no extra entitlement.

**Cloudflare** (needs `uv` and Node):

```bash
cd api
uv run pywrangler login
uv run pywrangler d1 create boring-api        # paste the database_id into wrangler.jsonc
uv run pywrangler d1 migrations apply boring-api --remote
uv run pywrangler deploy                      # prints https://boring-api.<subdomain>.workers.dev
uv run pywrangler secret put APPLE_TEAM_ID
uv run pywrangler secret put APPLE_KEY_ID
uv run pywrangler secret put APPLE_DEVICECHECK_KEY < ~/Downloads/AuthKey_XXXXXXXXXX.p8
```

Redeploy after changes with `uv run pywrangler deploy`. Schema changes go in a new file in `api/migrations/`, then run `migrations apply --remote`.

## Add it to an app

In Xcode, choose File → Add Package Dependencies. Use this repo's git URL, or **Add Local…** for the folder.

```swift
import BoringKit

@main
struct MyApp: App {
    init() {
        BoringKit.start(api: URL(string: "https://boring-api.<subdomain>.workers.dev")!)
    }
    // ...
}

Aptabase.shared.trackEvent("export_tapped", with: ["format": "pdf"])   // analytics
Aptabase.shared.trackError(error)                                       // a handled error
.sheet(isPresented: $showFeedback) { FeedbackView() }                   // feedback
ContentView().updatePrompt()                                            // on the root view
```

`import BoringKit` re-exports Aptabase. Debug builds are flagged `is_debug = 1`.

**Telling users about an update:** once a release is live on the App Store, set its version in `APPS` in `api/src/kit.py` and run `uv run pywrangler deploy`:

```python
APPS = {
    "com.you.app": {"version": "1.4.0", "url": "https://apps.apple.com/app/id1234567890"},
}
```

On their next launch, users on an older version get an "Update available" alert with an **Update** button that opens the App Store and a **Not now** button. It asks again on every launch until they update. Bump the version only after the release is live, or the App Store won't have the update yet when users get there. Phased release is fine, because users can always update by hand. For your own UI, use `await BoringKit.availableUpdate()` instead.

App Store privacy label: declare Crash Data, Performance Data, Product Interaction and Other Diagnostic Data, none of them linked to the user's identity. If you keep the optional feedback email, also declare Email Address.

## Local dev and tests

```bash
cd api
echo 'ALLOW_UNATTESTED=true' > .dev.vars
uv run pywrangler d1 migrations apply boring-api --local
uv run pywrangler dev                         # http://127.0.0.1:8787
```

Point an app running in the Simulator at `http://127.0.0.1:8787`.

```bash
cd api && uv run pytest                       # Worker unit tests
```

The integration test runs in the Simulator against the local Worker started above. It then checks that the event, error, crash and feedback it sent all reached local D1:

```bash
scripts/integration-test.sh "iPhone 17 Pro"
```

## Reading the data

Use the Cloudflare dashboard (D1 → `boring-api` → Console), or run `uv run pywrangler d1 execute boring-api --remote --command "…"`.

```sql
-- daily active devices per app (release builds)
SELECT d.bundle_id, date(e.ts) AS day, count(DISTINCT e.device_id) AS devices, count(*) AS events
FROM events e JOIN devices d ON d.id = e.device_id
WHERE e.is_debug = 0 GROUP BY 1, 2 ORDER BY day DESC;

-- latest crashes, release builds only, without MetricKit's second copy of crashes KSCrash already caught
SELECT c.id, d.bundle_id, c.received_at,
       json_extract(c.report, '$.system.CFBundleShortVersionString') AS version,
       json_extract(c.report, '$.report.monitor_id') AS source,
       json_extract(c.report, '$.crash.error.type') AS type,
       json_extract(c.report, '$.crash.error.signal.name') AS signal,
       json_extract(c.report, '$.crash.error.reason') AS reason
FROM crashes c JOIN devices d ON d.id = c.device_id
WHERE ifnull(json_extract(c.report, '$.system.build_type'), '') NOT IN ('debug', 'simulator')
  AND NOT (json_extract(c.report, '$.report.monitor_id') = 'MetricKit'
           AND json_extract(c.report, '$.report.run_id') IN (
             SELECT json_extract(report, '$.report.run_id') FROM crashes
             WHERE ifnull(json_extract(report, '$.report.monitor_id'), '') <> 'MetricKit'))
ORDER BY c.id DESC LIMIT 20;

-- handled errors by type
SELECT type, count(*) AS n, max(received_at) AS last_seen FROM errors WHERE is_debug = 0 GROUP BY type ORDER BY n DESC;

-- feedback
SELECT f.received_at, d.bundle_id, f.message, f.email, f.meta
FROM feedback f JOIN devices d ON d.id = f.device_id ORDER BY f.id DESC;
```

Your own code shows up in crash stacks as raw addresses in release builds. Symbolicate them with the build's dSYM:
`atos -o MyApp.app.dSYM/Contents/Resources/DWARF/MyApp -l <load address> <address>`.

**Revoking a token:** `UPDATE devices SET token_hash = 'revoked-' || id WHERE id = 42;`. This doesn't ban the device. On its next launch, the ping gets a 401 and a genuine device simply registers again. A real ban would need something that survives re-registration, such as DeviceCheck's two per-device bits, and that isn't built. The same ping is what lets every install recover if the database is ever reset.

## What this does and doesn't protect against

DeviceCheck shows that a registration came from a real Apple device. It doesn't prove the request came from your unmodified app; App Attest would, at much more cost. The bundle ID is self-reported. Cloudflare's rate limits are approximate and counted per location, so they slow a flood down but don't cap storage. Someone with many IPs or devices could still fill D1, whose free plan holds 500 MB. This is meant to keep out casual junk, not a determined attacker.
