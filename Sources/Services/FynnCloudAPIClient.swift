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

    init(req: Request, baseURL: String = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080") {
        self.init(client: req.application.http.client.shared, baseURL: baseURL)
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
}
