# Changelog

This project follows [Semantic Versioning](https://semver.org). Until 1.0, a minor version (0.x) may include breaking changes, so pin with "Up to Next Minor".

## Unreleased

- macOS 14 and later. Mac apps get crash reports, analytics, feedback and the update prompt, which opens the Mac App Store. A sandboxed Mac app needs the Outgoing Connections (Client) entitlement.
- Worker: devices and app versions are kept per platform, since a Mac app can share its iPhone app's bundle ID. `devices` has a `platform` column, and `apps` has one row per bundle ID and platform.
- Worker: with `ALLOW_UNATTESTED=true`, registration no longer asks Apple at all, so Macs, which send a DeviceCheck token, can register with a local Worker. Never set it in production.
- Worker: the newest version of each app lives in an `apps` table in D1 instead of `APPS` in `api/src/kit.py`. Releasing a version is one SQL command with no deploy, and your copy of the repo needs no code edits.
- Worker: `wrangler.jsonc` has no `database_id`. The first deploy creates the database, and every command finds it by name.
- A GitHub Actions workflow that tests, migrates and deploys the Worker on every push to `main`, optionally on your own domain with `workers.dev` turned off.
- README: deploying from GitHub, keeping your copy up to date, and hardening your own domain with WAF rules.
- Docs: [Adding the kit to your apps](docs/adding-to-your-apps.md), a walkthrough from deploying the Worker to releasing. AGENTS.md covers XcodeGen, Mac apps, personal data in error messages, and rewriting an app's privacy claims.

## 0.1.1 (2026-11-23)

- Security: the Worker's JSON depth check runs in linear time. Crafted input could cost it seconds of CPU per request, even on unauthenticated registration.
- Security: the Worker reads request bodies up to each route's limit and stops there, so a body sent without Content-Length can't make it buffer more.
- Security: the Worker replaces control characters in everything devices send, so stored text can't carry terminal escape codes.
- Security: `.updatePrompt()` and `availableUpdate()` only offer `https://apps.apple.com` links.
- Docs: the README's crash query can't be blinded by a crafted report, `d1 execute` examples use `--json`, and the security model states how much one device can write.

## 0.1.0 (2026-11-22)

First release.

- Crash reporting with KSCrash: signals, Mach and ObjC/C++ exceptions, hangs and watchdog kills, plus the crash reports iOS collects through MetricKit.
- Usage analytics and handled errors through aptabase-swift, sent to your own Worker.
- `FeedbackView`, a ready-made SwiftUI feedback sheet, and `BoringKit.sendFeedback(_:email:)`.
- `.updatePrompt()`, which asks users on an old version to update and links to the App Store.
- A Python Cloudflare Worker with D1 storage. Devices register once through Apple DeviceCheck, and the Worker rate-limits each device and IP.
