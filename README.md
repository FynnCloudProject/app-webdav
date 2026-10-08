# WebDAV (FynnCloud App)

A native Swift microservice providing an RFC 4918 WebDAV endpoint for mounting FynnCloud storage directly into macOS Finder, Windows Explorer, Cyberduck, and other WebDAV clients.

## Architecture

- **Stateless Proxying**: Streams large file uploads and downloads between WebDAV clients and FynnCloud without buffering full files in memory.
- **App Password Authentication**: Authenticates with HTTP Basic auth using app-specific passwords (`fc_app_...`) with an in-memory token cache.
- **Platform Metadata Handling**: Automatically filters macOS and Windows sidecar metadata files (`.DS_Store`, `._*`, `Thumbs.db`).

## Development

```bash
# Build
swift build

# Run locally
FYNNCLOUD_API_URL="http://localhost:8080" PORT=3080 swift run
```

## Docker

```bash
docker build -t ghcr.io/fynncloudproject/app-webdav:latest .
docker run -p 8080:8080 -e FYNNCLOUD_API_URL="http://host.docker.internal:8080" ghcr.io/fynncloudproject/app-webdav:latest
```
