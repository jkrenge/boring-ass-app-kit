# Boring Ass App Kit: guide for coding agents

This file is for a coding agent that is adding the kit to an iOS app, or working on this repo. People should start with the [README](README.md).

The kit gives an app crash reporting, usage analytics, handled-error reports, a feedback sheet and an update prompt. All of it goes to the user's own Cloudflare Worker, which is in `api/`. The Swift module is `BoringKit`.

## Adding it to an iOS app

### 0. Get the Worker URL

You need the URL of the user's deployed Worker, such as `https://boring-api.<subdomain>.workers.dev`. If the user hasn't given you one, ask for it. Don't invent one. If they haven't deployed a Worker yet, point them to "Deploy the API" in the README. That step needs their Cloudflare login and an Apple key, so they have to do it themselves.

For local testing only, `http://127.0.0.1:8787` works in the Simulator while this repo's Worker runs with `pywrangler dev` and `ALLOW_UNATTESTED=true`. The deployed Worker rejects the Simulator, because the Simulator can't make DeviceCheck tokens. Never ship the local URL.

### 1. Add the package

The package is `https://github.com/jkrenge/boring-ass-app-kit`, its product is `BoringKit`, and it needs iOS 16 or later. Until 1.0, pin it with "up to next minor".

- **App built from a `Package.swift`:**
  ```swift
  .package(url: "https://github.com/jkrenge/boring-ass-app-kit", .upToNextMinor(from: "0.1.0")),
  // in the app target's dependencies:
  .product(name: "BoringKit", package: "boring-ass-app-kit"),
  ```
- **XcodeGen (`project.yml`) or Tuist:** add it there, then regenerate the project.
- **Plain `.xcodeproj`:** edit `project.pbxproj` only if you can do it cleanly. You need an `XCRemoteSwiftPackageReference` (kind `upToNextMinorVersion`, minimumVersion `0.1.0`), an `XCSwiftPackageProductDependency` for `BoringKit`, an entry in the app target's `packageProductDependencies`, and a `PBXBuildFile` in its Frameworks phase, all with unique IDs. Otherwise ask the user to add it in Xcode (File → Add Package Dependencies…) and carry on with the code meanwhile.

Then run `xcodebuild -resolvePackageDependencies` and build.

Don't add `aptabase-swift` or `KSCrash` to the app separately. BoringKit brings them in, aptabase-swift at exactly 0.4.0 and KSCrash at any 2.6.x, and `import BoringKit` re-exports Aptabase.

### 2. Start it at launch

Call `BoringKit.start(api:)` once, as early as possible, on the main actor. It installs the crash reporter, so anything that runs before it can crash unseen.

```swift
import BoringKit
import SwiftUI

@main
struct MyApp: App {
    init() {
        BoringKit.start(api: URL(string: "https://boring-api.<subdomain>.workers.dev")!)
    }

    var body: some Scene {
        WindowGroup {
            ContentView().updatePrompt()   // asks users on an old version to update
        }
    }
}
```

In a UIKit app, call it first thing in `application(_:didFinishLaunchingWithOptions:)`.

### 3. Track what matters

```swift
Aptabase.shared.trackEvent("export_tapped", with: ["format": "pdf", "pages": 3])
```

- Track a handful of events that answer real product questions, such as screens opened, key actions finished, or a paywall shown. Don't track every tap.
- Name events in `snake_case`, at most 200 characters. Prop values can be `String`, `Int`, `Double`, `Float` or `Bool`.
- **No personal data in names or props:** no names, emails, free text people typed, account IDs, or anything else that identifies a person. The App Store privacy label this kit recommends says the data isn't linked to the user.
- Aptabase sends events in batches, so you don't need to throttle normal use.

### 4. Report handled errors

Call this in a `catch` for an error you didn't expect, such as a failed save or a decoding error:

```swift
do { try save() } catch {
    Aptabase.shared.trackError(error)
    // ...show the user something
}
```

Skip expected errors like user cancellation or `CancellationError`. Crashes are caught automatically and need no code.

### 5. Offer feedback

Add an entry point, such as a "Send Feedback" row in settings or a menu item:

```swift
@State private var showFeedback = false

Button("Send Feedback") { showFeedback = true }
    .sheet(isPresented: $showFeedback) { FeedbackView() }
```

For your own UI, `await BoringKit.sendFeedback(message, email: optionalEmail)` returns `true` once the message is sent.

### 6. Update prompt

`.updatePrompt()` goes on the root view, once. When the Worker reports a newer version, it shows an alert with **Update**, which opens the App Store, and **Not now**. For custom UI, `await BoringKit.availableUpdate()` returns an `AppUpdate?` with `version` and `url`.

The prompt only appears for apps that have a row in the `apps` table of the user's D1 database. Tell the user to set one when they release, with the version and the App Store URL `https://apps.apple.com/app/id<number>`. The command is under "Telling users about an update" in the README, and it needs no deploy.

### 7. Finish up

- Build the app. The kit adds no warnings.
- Tell the user what to declare in the App Store privacy label: Crash Data, Performance Data, Product Interaction and Other Diagnostic Data, none linked to the user's identity. Add Email Address if they keep the optional feedback email. KSCrash and Aptabase ship their own privacy manifests.
- Add a short note to the app's own `AGENTS.md` or `CLAUDE.md` so future sessions keep using the kit. For example: *"Analytics: `Aptabase.shared.trackEvent` (via BoringKit), no personal data in props. Unexpected errors: `Aptabase.shared.trackError`. Feedback: `FeedbackView`."*

### Don'ts

- Don't add a second crash reporter, such as Crashlytics, Sentry or Bugsnag. Crash reporters fight over the same signal handlers.
- Don't call KSCrash directly or change its configuration. `BoringKit.start` owns it.
- Don't put the Worker URL behind a feature flag or remote config. The crash reporter needs it at launch.

## Public API

| API | What it does |
|---|---|
| `BoringKit.start(api: URL)` | Installs crash reporting, registers the device, starts analytics, uploads pending crash reports, checks for updates. |
| `BoringKit.sendFeedback(_ message: String, email: String? = nil) async -> Bool` | Sends feedback right away. |
| `BoringKit.availableUpdate() async -> AppUpdate?` | The newer version the Worker offers, if any. Waits for the launch ping. |
| `FeedbackView()` | A SwiftUI feedback sheet. |
| `View.updatePrompt()` | An alert offering the update, shown once per launch. |
| `Aptabase.shared.trackEvent(_:with:)` | Re-exported from aptabase-swift. |
| `Aptabase.shared.trackError(_:)` | Re-exported. Sends a handled error. |

## Working on this repo

Read [CONTRIBUTING.md](CONTRIBUTING.md). The essentials:

- `api/src/kit.py` holds the pure logic and has pytest tests (`cd api && uv run pytest`). `api/src/entry.py` is the Worker glue. Validate everything devices send in `kit.py`.
- Keep the Worker API additive-only, because old app versions keep calling it.
- Keep per-deployment settings out of the code, in D1, Worker secrets or GitHub variables, so people's copies of the repo take updates without conflicts.
- Build the Swift package with `xcodebuild build -scheme BoringKit -destination "generic/platform=iOS Simulator"`. It must have no warnings under Swift 6 strict concurrency.
- `scripts/integration-test.sh` runs the full app-to-D1 path against a local Worker.
- Don't deploy, push, or run anything with `--remote` unless the user asks. Secrets go through `pywrangler secret put`, never into files.
