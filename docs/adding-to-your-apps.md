# Adding the kit to your apps

This guide takes you from nothing to apps that send crash reports, events and feedback to your own Worker. You deploy one Worker, add the package to each app, test on a device, and update a few things before release. The [README](../README.md) has the details behind each step.

## Before you start

- **One Worker serves all your apps.** Deploy it once. Each app's data is stored under its bundle ID.
- **One Apple team per Worker.** The Worker holds one team's DeviceCheck key, and Apple only accepts tokens from apps signed by that team. An app signed by another team can't register, so it sends nothing, not even crash reports. Sign every app that shares a Worker with the same team. The Worker doesn't support several teams yet.
- **iOS and macOS.** BoringKit supports iOS 16 and macOS 14 or later, but not watchOS, tvOS or visionOS. A Mac app may share its iPhone app's bundle ID: the Worker keeps each device's platform, and each platform gets its own update prompt row.
- **The Simulator can't register** with the deployed Worker, because it can't make DeviceCheck tokens. Test on a real device or a Mac, or against a local Worker as described in [CONTRIBUTING.md](../CONTRIBUTING.md).
- **Your privacy promises change.** If an app's privacy policy, website, App Store description, README or contributor rules say it collects nothing, has no analytics, talks to no server or uses no third-party code, they stop being true. Plan to rewrite them before the first release with the kit.

## 1. Deploy the Worker (once)

The setup below is the one to start with: your own private copy of this repo, deployed by GitHub Actions, on your own domain. For other ways to deploy, see the README's [Quick start](../README.md#1-deploy-the-api-once) and [Keeping your copy up to date](../README.md#keeping-your-copy-up-to-date).

**Get an Apple key.** In the developer portal of the team that signs your apps, go to Certificates, IDs & Profiles → Keys and create a key with **DeviceCheck** enabled. Download `AuthKey_XXXXXXXXXX.p8` and note the Key ID and the Team ID.

**Pick the API's address now.** Apps keep calling the URL they were built with, so you can't move it later without cutting off installed versions. A hostname on a domain you have on Cloudflare, such as `api.example.com`, is best: it allows the [WAF rules](../README.md#hardening-on-your-own-domain), and `workers.dev` gets turned off. Without a domain, the Worker lives at `https://boring-api.<subdomain>.workers.dev`.

**Make a private copy** of this repo. Replace `<you>` with your GitHub account:

```bash
gh repo create <you>/boring-api --private
```

```bash
git clone https://github.com/jkrenge/boring-ass-app-kit boring-api && cd boring-api && git remote rename origin upstream && git remote add origin https://github.com/<you>/boring-api && git push -u origin main
```

A public fork works too. Nothing private goes into the repo, but you have to turn on Actions in a fork's **Actions** tab.

**Configure the deploy.** Create a Cloudflare API token from the **Edit Cloudflare Workers** template, with **Account → D1 → Edit** added, and copy your account ID from the Cloudflare dashboard. Then:

```bash
gh secret set CLOUDFLARE_API_TOKEN --repo <you>/boring-api
```

```bash
gh variable set CLOUDFLARE_ACCOUNT_ID --repo <you>/boring-api --body <account-id>
```

```bash
gh variable set API_DOMAIN --repo <you>/boring-api --body api.example.com
```

Skip `API_DOMAIN` if you're staying on `workers.dev`.

**Deploy.** The first run creates the D1 database and the Worker:

```bash
gh workflow run deploy.yml --repo <you>/boring-api
```

```bash
gh run watch --repo <you>/boring-api
```

**Set the Apple secrets.** Run this and every other `pywrangler` command in this guide from the `api` folder of your copy. The secrets stay on the Worker, and the workflow never sees them:

```bash
uv run pywrangler login && uv run pywrangler secret put APPLE_TEAM_ID && uv run pywrangler secret put APPLE_KEY_ID
```

```bash
uv run pywrangler secret put APPLE_DEVICECHECK_KEY < ~/Downloads/AuthKey_XXXXXXXXXX.p8
```

**Check it.** This should answer `{"error": "device check token required"}`:

```bash
curl -s https://api.example.com/v1/register -d '{"bundleId":"check"}'
```

And this should show an empty `devices` table, which means the migrations ran:

```bash
uv run pywrangler d1 execute boring-api --remote --json --command "SELECT count(*) FROM devices"
```

## 2. Add the kit to each app

Open the app's repo in a coding agent such as Claude Code, and paste this, with your Worker's URL:

```text
Add Boring Ass App Kit to this app: crash reporting, analytics, handled errors,
a feedback screen and an update prompt. Follow the integration guide at
https://raw.githubusercontent.com/jkrenge/boring-ass-app-kit/main/AGENTS.md
My Worker URL is https://api.example.com
Suggest a few analytics events for the key actions in this app before adding them.
Find every place that promises no analytics, no data collection, no server or no
third-party code, and show me new wording for each before you commit.
```

[AGENTS.md](../AGENTS.md) covers Xcode projects, `Package.swift`, XcodeGen and Tuist, on iOS and on the Mac. When you review the agent's work, check these:

- **The events answer real questions.** A handful of key actions and screens, not every tap.
- **No personal data.** This matters most in apps that hold people's content or accounts: notes, tasks, messages, calendars, email. Event props should be counts, flags and fixed names, never titles, text people typed, list names, IDs or email addresses. The same goes for `trackError`: errors from a server API often carry IDs or email addresses in their message, so don't send those raw.
- **A sandboxed Mac app has network access.** It needs the Outgoing Connections (Client) entitlement, or nothing reaches the Worker.
- **The privacy wording is true.** It should say the app sends crash reports, usage events and feedback to your own server, and that none of it is linked to the user.

To set it up by hand instead, follow the README's [Quick start](../README.md#2-add-the-package-to-your-app) from step 2.

## 3. Test on a device

1. Run a Debug build from Xcode on a real iPhone or iPad, or on your Mac. Debug builds use Apple's development DeviceCheck server, and TestFlight and App Store builds use the production one. The Worker handles both.
2. Check that the device registered:
   ```bash
   uv run pywrangler d1 execute boring-api --remote --json --command "SELECT id, bundle_id, attested, created_at FROM devices ORDER BY id DESC LIMIT 5"
   ```
   If no row appears, run `uv run pywrangler tail` and launch the app again. A `devicecheck rejected` line means Apple refused the token. Check the three Apple secrets, and that the app is signed by the key's team.
3. Use the app for a minute, send feedback from the sheet, then check the `events` and `feedback` tables. The README's [Reading your data](../README.md#reading-your-data) has the queries. Events from Debug builds have `is_debug = 1`.
4. To test crash reporting, stop the app in Xcode, then launch it from the home screen or the Dock. Crash reporters can't catch a crash while the debugger is attached. Crash the app, for example with a temporary button that calls `fatalError()`, then launch it again. The report arrives in `crashes`.

## 4. Before you release

- **Privacy policy, website and App Store description:** publish the new wording.
- **App Store privacy label:** declare Crash Data, Performance Data, Product Interaction and Other Diagnostic Data, none of them linked to the user's identity. Add Email Address if you keep the optional email in the feedback form.
- **Privacy manifest:** if the app's own `PrivacyInfo.xcprivacy` declares that it collects no data, add the same data types. KSCrash and Aptabase ship their own manifests.
- **Update prompt:** once the release is live on the App Store, add the app's row to the `apps` table, as described in [Telling users about an update](../README.md#telling-users-about-an-update). A Mac app gets its own row. Do the same for every later release. TestFlight builds have no App Store link, so don't add a row for them.

## Keeping it running

- **Updates:** pull this repo into your copy with `git pull upstream main && git push`. The push deploys the new Worker. Update the Worker before you raise the package version in your apps. See [Keeping your copy up to date](../README.md#keeping-your-copy-up-to-date).
- **Your data:** query D1 from the Cloudflare dashboard or the CLI, using the README's [Reading your data](../README.md#reading-your-data).
- **The limits:** the free plan's quotas and what DeviceCheck does and doesn't prove are in the [Security model](../README.md#security-model).
