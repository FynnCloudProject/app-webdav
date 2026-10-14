# WebDAV

RFC 4918 WebDAV server for FynnCloud that lets users mount their cloud storage as a network drive in macOS Finder, Windows Explorer, Cyberduck, rclone, and other WebDAV clients.

## Connecting a Client

WebDAV requires an **App-Specific Password** rather than your regular FynnCloud account password (this allows WebDAV access even when 2FA or Passkeys are enabled, and lets you revoke individual devices at any time).

1. In FynnCloud, go to **Settings → Security → App-Specific Passwords** and click **Generate App Password**.
2. Copy the generated password (starts with `fc_app_...`). It is only shown once.
3. Connect your WebDAV client using:
   - **Server URL**: `https://<your-fynncloud-domain>/api/apps/webdav/proxy`
   - **Username**: Your FynnCloud username
   - **Password**: The `fc_app_...` password generated in step 1

### Client Setup

- **macOS Finder**: Press `⌘K` (**Go → Connect to Server…**), paste the Server URL, select **Registered User**, and enter your username and `fc_app_...` password.
- **Windows Explorer**: Right-click **This PC → Map network drive…**, paste the Server URL into **Folder**, check **Connect using different credentials**, and sign in with your username and `fc_app_...` password.
- **Cyberduck / Mountain Duck / rclone**: Select **WebDAV (HTTPS)**, set the path to `/api/apps/webdav/proxy`, and authenticate with your username and `fc_app_...` password.

## Features

- Full RFC 4918 support (`OPTIONS`, `PROPFIND`, `PROPPATCH`, `GET`, `HEAD`, `PUT`, `MKCOL`, `MOVE`, `COPY`, `DELETE`, `LOCK`, `UNLOCK`).
- Streams file uploads and downloads directly between the WebDAV client and FynnCloud without buffering full files in memory.
- Verifies `fc_app_...` credentials against `/api/auth/app-passwords/verify` and caches short-lived access tokens in memory.
- Filters OS metadata sidecar files (`.DS_Store`, `._*`, `Thumbs.db`, `desktop.ini`) so they don't clutter user storage.

## Development

When installed via the FynnCloud App Store, the container runs on the internal `fynncloud-apps-network` and FynnCloud automatically injects `FYNNCLOUD_API_URL` (`http://fynncloud-server:8080`), `FYNNCLOUD_APP_ID`, and `FYNNCLOUD_APP_SECRET`.

For local development (defaults to `http://127.0.0.1:8080`):

```bash
swift build
swift run
```

## Docker

```bash
docker build -t ghcr.io/fynncloudproject/app-webdav:1.0.0 .
docker run -p 8080:8080 ghcr.io/fynncloudproject/app-webdav:1.0.0
```
