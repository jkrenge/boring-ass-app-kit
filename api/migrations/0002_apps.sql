-- Newest version of each app, per platform. On launch, devices on an older version are asked to update and linked to url.
-- Set it once a release is live on the App Store. A Mac app gets its own row, even with its iPhone app's bundle ID:
--   INSERT OR REPLACE INTO apps (bundle_id, version, url) VALUES ('com.you.app', '1.4.0', 'https://apps.apple.com/app/id1234567890');
--   INSERT OR REPLACE INTO apps (bundle_id, platform, version, url) VALUES ('com.you.app', 'macOS', '1.4.0', 'https://apps.apple.com/app/id1234567890');
CREATE TABLE apps (
  bundle_id TEXT NOT NULL,
  platform TEXT NOT NULL DEFAULT 'iOS',  -- iOS or macOS
  version TEXT NOT NULL,                 -- CFBundleShortVersionString: up to three numbers, such as 1.4.0
  url TEXT NOT NULL CHECK (url LIKE 'https://apps.apple.com/%'),
  PRIMARY KEY (bundle_id, platform)
);
