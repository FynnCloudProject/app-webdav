import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Vapor

struct FynnCloudAPIClient: Sendable {
    let client: HTTPClient
    let baseURL: String

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .customISO8601
        return d
    }()

    init(client: HTTPClient, baseURL: String = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080") {
        self.client = client
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    init(app: Application, baseURL: String = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080") {
        self.init(client: app.http.client.shared, baseURL: baseURL)
    }

    init(req: Request, baseURL: String = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080") {
        self.init(client: req.application.http.client.shared, baseURL: baseURL)
    }

    // MARK: - File Metadata & Navigation

    func getFile(id: UUID, token: String) async throws -> FileIndexItemDTO {
        var req = HTTPClientRequest(url: "\(baseURL)/api/files/\(id.uuidString)")
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok else {
            throw Abort(res.status, reason: "Unable to retrieve file \(id)")
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try Self.decoder.decode(FileIndexItemDTO.self, from: buffer)
    }

    func resolvePath(_ segments: [String], token: String) async throws -> FileIndexItemDTO? {
        let path = segments.joined(separator: "/")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/resolve?path=\(encoded)")
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        let res = try await client.execute(req, timeout: .seconds(30))
        if res.status == .notFound {
            return nil
        }
        guard res.status == .ok else {
            throw Abort(res.status)
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try Self.decoder.decode(FileIndexItemDTO.self, from: buffer)
    }

    func listChildren(folderID: UUID?, token: String) async throws -> [FileIndexItemDTO] {
        let url = folderID.map { "\(baseURL)/api/files?parentID=\($0.uuidString)" } ?? "\(baseURL)/api/files"
        var req = HTTPClientRequest(url: url)
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok else {
            throw Abort(res.status)
        }

        let buffer = try await res.body.collect(upTo: 10 * 1024 * 1024)
        let listing = try Self.decoder.decode(FileIndexDTO.self, from: buffer)
        return listing.files
    }

    // MARK: - Directory & File Operations

    func createDirectory(name: String, parentID: UUID?, token: String) async throws -> FileIndexItemDTO {
        struct Payload: Content {
            let name: String
            let parentID: UUID?
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/create-directory")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(Payload(name: name, parentID: parentID)))

        let res = try await client.execute(req, timeout: .seconds(30))
        if res.status == .conflict {
            throw Abort(.methodNotAllowed, reason: "Resource already exists")
        }
        guard res.status == .ok || res.status == .created else {
            throw Abort(res.status)
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try Self.decoder.decode(FileIndexItemDTO.self, from: buffer)
    }

    func rename(fileID: UUID, to newName: String, token: String) async throws -> FileIndexItemDTO {
        struct Payload: Content {
            let name: String
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/\(fileID.uuidString)")
        req.method = .PATCH
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(Payload(name: newName)))

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok else {
            throw Abort(res.status)
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try Self.decoder.decode(FileIndexItemDTO.self, from: buffer)
    }

    func move(fileID: UUID, toParentID: UUID?, token: String) async throws {
        struct Payload: Content {
            let ids: [UUID]
            let parentID: UUID?
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/move")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(Payload(ids: [fileID], parentID: toParentID)))

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok else {
            throw Abort(res.status)
        }
    }

    func copy(fileID: UUID, toParentID: UUID?, newName: String?, token: String) async throws -> FileIndexItemDTO {
        struct Payload: Content {
            let id: UUID
            let parentID: UUID?
            let name: String?
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/copy")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(Payload(id: fileID, parentID: toParentID, name: newName)))

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok || res.status == .created else {
            throw Abort(res.status)
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try Self.decoder.decode(FileIndexItemDTO.self, from: buffer)
    }

    func delete(fileID: UUID, token: String) async throws {
        struct Payload: Content {
            let ids: [UUID]
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/trash")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(Payload(ids: [fileID])))

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok || res.status == .noContent else {
            throw Abort(res.status)
        }
    }

    // MARK: - Download & Upload Streaming

    func download(fileID: UUID, headers: HTTPHeaders = [:], token: String) async throws -> Response {
        var req = HTTPClientRequest(url: "\(baseURL)/api/files/\(fileID.uuidString)/download")
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        if let range = headers.first(name: .range) {
            req.headers.replaceOrAdd(name: .range, value: range)
        }
        if let ifNoneMatch = headers.first(name: .ifNoneMatch) {
            req.headers.replaceOrAdd(name: .ifNoneMatch, value: ifNoneMatch)
        }

        let res = try await client.execute(req, timeout: .minutes(60))
        let response = Response(status: res.status, headers: res.headers)
        response.body = .init(managedAsyncStream: { writer in
            for try await chunk in res.body {
                try await writer.write(.buffer(chunk))
            }
        })
        return response
    }

    func download(fileID: UUID, to destination: URL, token: String) async throws {
        var req = HTTPClientRequest(url: "\(baseURL)/api/files/\(fileID.uuidString)/download")
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        let res = try await client.execute(req, timeout: .minutes(10))
        guard res.status == .ok else {
            throw Abort(res.status, reason: "Failed to download file \(fileID)")
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        for try await chunk in res.body {
            handle.write(Data(buffer: chunk))
        }
    }

    func upload(
        filename: String,
        parentID: UUID?,
        body: HTTPClientRequest.Body,
        contentLength: Int64?,
        contentType: String,
        token: String,
        overwrite: Bool
    ) async throws -> Response {
        var query = [
            "filename=\(filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename)",
            "overwrite=\(overwrite ? "true" : "false")"
        ]
        if let parentID {
            query.append("parentID=\(parentID.uuidString)")
        }
        if let contentLength {
            query.append("size=\(contentLength)")
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/upload?\(query.joined(separator: "&"))")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: contentType)
        if let contentLength {
            req.headers.replaceOrAdd(name: .contentLength, value: String(contentLength))
        }
        req.body = body

        let res = try await client.execute(req, timeout: .hours(4))
        guard res.status == .ok || res.status == .created else {
            throw Abort(res.status)
        }
        return Response(status: res.status)
    }

    func uploadArchive(
        name: String,
        fileURL: URL,
        size: Int64,
        parentID: UUID?,
        token: String
    ) async throws -> (finalName: String, fileID: UUID?) {
        let zipData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var candidateName = name

        for attempt in 1...20 {
            var query = [
                "filename=\(candidateName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? candidateName)",
                "overwrite=false",
                "size=\(size)",
                "contentType=application/zip"
            ]
            if let parentID {
                query.append("parentID=\(parentID.uuidString)")
            }

            var req = HTTPClientRequest(url: "\(baseURL)/api/files/upload?\(query.joined(separator: "&"))")
            req.method = .POST
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            req.headers.replaceOrAdd(name: .contentType, value: "application/zip")
            req.headers.replaceOrAdd(name: .contentLength, value: String(size))
            req.body = .bytes(zipData)

            let res = try await client.execute(req, timeout: .minutes(5))

            if res.status == .ok || res.status == .created {
                var createdID: UUID?
                if let body = try? await res.body.collect(upTo: 64 * 1024) {
                    struct UploadResult: Decodable { let id: UUID? }
                    createdID = try? JSONDecoder().decode(UploadResult.self, from: body).id
                }
                return (candidateName, createdID)
            }

            if res.status == .conflict {
                let stem = (name as NSString).deletingPathExtension
                candidateName = "\(stem) (\(attempt)).zip"
                continue
            }

            throw Abort(res.status, reason: "Failed to upload archive to destination")
        }

        throw Abort(.conflict, reason: "Could not find an available filename for archive")
    }
}
