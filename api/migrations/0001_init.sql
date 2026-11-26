CREATE TABLE devices (
  id INTEGER PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE, -- sha256 of the device's bearer token; overwrite it to revoke a device
  bundle_id TEXT NOT NULL,
  platform TEXT NOT NULL DEFAULT 'iOS', -- iOS or macOS; a Mac app can share its iPhone app's bundle ID
  attested INTEGER NOT NULL,       -- 1 = Apple DeviceCheck said genuine, 0 = ALLOW_UNATTESTED (local dev)
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  device_id INTEGER NOT NULL REFERENCES devices(id),
  ts TEXT NOT NULL,
  session_id TEXT NOT NULL,
  name TEXT NOT NULL,
  props TEXT,                      -- JSON
  system TEXT NOT NULL,            -- JSON: appVersion, osVersion, deviceModel, locale, ...
  is_debug INTEGER NOT NULL,
  received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE errors (
  id INTEGER PRIMARY KEY,
  device_id INTEGER NOT NULL REFERENCES devices(id),
  type TEXT NOT NULL,
  message TEXT NOT NULL,
  is_debug INTEGER NOT NULL,
  report TEXT NOT NULL,            -- JSON, full Aptabase error report incl. stackTrace
  received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE crashes (
  id INTEGER PRIMARY KEY,
  device_id INTEGER NOT NULL REFERENCES devices(id),
  report TEXT NOT NULL,            -- JSON, raw KSCrash report (crashes + MetricKit diagnostics)
  received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE feedback (
  id INTEGER PRIMARY KEY,
  device_id INTEGER NOT NULL REFERENCES devices(id),
  message TEXT NOT NULL,
  email TEXT,
  meta TEXT NOT NULL,              -- JSON: appVersion, osVersion, deviceModel, isDebug
  received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
