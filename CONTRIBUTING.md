# Contributing

Thanks for helping. This kit stays useful by staying small, so the best changes fix something real with little code. Before building a bigger feature, open an issue to talk it through.

## Layout

| Path | What |
|---|---|
| `Package.swift`, `Sources/BoringKit/` | The Swift package apps depend on |
| `Tests/BoringKitTests/` | Integration test that runs in the Simulator or on this Mac against a local Worker |
| `api/src/entry.py` | Worker routes and the glue to D1, Apple and rate limits |
| `api/src/kit.py` | Pure helpers: request validation, tokens, JWT, version checks. Unit-tested with pytest. |
| `api/migrations/` | D1 schema, one file per change |
| `docs/` | Guides for people setting up the kit |
| `scripts/integration-test.sh` | Runs the Swift test, then checks the rows arrived in local D1 |

## Setup

You need Xcode 16 or later, [uv](https://docs.astral.sh/uv/) and Node (wrangler runs through it).

```bash
cd api
echo 'ALLOW_UNATTESTED=true' > .dev.vars     # lets devices register without asking Apple
uv run pywrangler d1 migrations apply boring-api --local
uv run pywrangler dev                         # http://127.0.0.1:8787
```

## Checks

Run all of these before opening a pull request:

```bash
cd api && uv run pytest
```

```bash
xcodebuild build -scheme BoringKit -destination "generic/platform=iOS Simulator"
```

```bash
xcodebuild build -scheme BoringKit -destination "generic/platform=macOS"
```

```bash
scripts/integration-test.sh "iPhone 17 Pro"   # needs the local Worker from Setup running
```

```bash
scripts/integration-test.sh macOS
```

The Swift build should have no warnings. The package uses Swift 6 strict concurrency.

## Rules of thumb

- **Change the API only additively.** Old app versions keep calling the Worker for months, so add optional fields and new routes, and never break existing payloads.
- **Validate everything a device sends** in `kit.py`, with a test. The Worker is the trust boundary.
- **Schema changes go in a new migration file.** Never edit one that has shipped.
- **Keep per-deployment settings out of the code.** People run their own copy of this repo, so anything they'd have to edit would conflict with every update. Settings go in D1, Worker secrets or GitHub variables.
- **Keep secrets out of the repo.** They belong in `pywrangler secret put` and in `.dev.vars`, which is gitignored.
- **Keep the aptabase-swift pin exact.** The device token travels in its `App-Key` header, which relies on how version 0.4.0 parses it. Bump it only after checking that parsing.
- **Comment the why, not the what.** For a known limit, write `shortcut: <the limit>, <when to upgrade>`.

## Pull requests

Keep each one to one change, and say what it fixes and how you checked it. Add a line to the top of `CHANGELOG.md` for anything users would notice.

## Releasing

1. Move the `CHANGELOG.md` entries under the new version number.
2. For a new minor version, raise the version in the install instructions in README.md, AGENTS.md and docs.
3. Tag the commit with the version, such as `0.2.0`, and push the tag. Swift Package Manager resolves versions from tags.
4. This repo deploys nothing: each user runs their own Worker. Start each changelog entry for a Worker change with "Worker:", so people know to update their Worker before the package.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
