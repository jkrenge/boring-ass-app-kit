# Changelog

This project follows [Semantic Versioning](https://semver.org). Until 1.0, a minor version (0.x) may include breaking changes, so pin with "Up to Next Minor".

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
