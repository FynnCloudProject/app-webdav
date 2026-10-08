// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "apps-webdav",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.112.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "WebDAV",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "Sources"
        )
    ]
)
