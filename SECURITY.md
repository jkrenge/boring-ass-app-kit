# Security

## Reporting a vulnerability

Please don't open a public issue. Report it privately through GitHub instead: on this repo, go to **Security → Report a vulnerability**. Include what you found, how to reproduce it, and what an attacker could do with it.

## What's in scope

- The Worker in `api/`: anything that lets an unregistered client write data, read data, take the Worker down, or get around the rate limits much more cheaply than intended.
- The Swift package: anything that leaks the device token or user data, or crashes the host app.

The [README](README.md#security-model) explains what this kit deliberately doesn't protect against. For example, DeviceCheck proves a real Apple device but not an unmodified app. Those limits aren't vulnerabilities, but ideas for closing them cheaply are welcome as normal issues.

## Running your own Worker

- Keep the Apple DeviceCheck key, Team ID and Key ID in Worker secrets (`pywrangler secret put`), never in the repo.
- Never set `ALLOW_UNATTESTED` in production. It lets any client register without DeviceCheck.
- Your D1 database holds your users' crash reports, analytics and feedback. Treat access to your Cloudflare account accordingly.
