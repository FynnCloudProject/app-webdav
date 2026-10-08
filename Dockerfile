# Build stage
FROM swift:6.0-noble AS build

WORKDIR /build
COPY Package.* ./
RUN swift package resolve

COPY . .
RUN swift build -c release --static-swift-stdlib

# Runtime stage
FROM ubuntu:noble-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /build/.build/release/WebDAV /app/webdav
COPY manifest.json /app/manifest.json

ENV PORT=8080
ENV HOST=0.0.0.0
EXPOSE 8080

ENTRYPOINT ["/app/webdav"]
