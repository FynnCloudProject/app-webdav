import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Vapor

struct FynnCloudAPIClient {
    let baseURL: String

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .customISO8601
        return d
    }()

    init(baseURL: String = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080") {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    func resolvePath(_ segments: [String], token: String, on req: Request) async throws -> FileIndexItemDTO? {
        let path = segments.joined(separator: "/")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        let res = try await req.client.get(URI(string: "\(baseURL)/api/files/resolve?path=\(encoded)")) { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: token)
        }

        if res.status == .notFound {
            return nil
        }
        guard res.status == .ok, let body = res.body else {
            throw Abort(res.status)
        }
        return try Self.decoder.decode(FileIndexItemDTO.self, from: body)
    }

    func listChildren(folderID: UUID?, token: String, on req: Request) async throws -> [FileIndexItemDTO] {
        let uri = folderID.map { "\(baseURL)/api/files?parentID=\($0.uuidString)" } ?? "\(baseURL)/api/files"
        let res = try await req.client.get(URI(string: uri)) { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: token)
        }
        guard res.status == .ok, let body = res.body else {
            throw Abort(res.status)
        }
        let listing = try Self.decoder.decode(FileIndexDTO.self, from: body)
        return listing.files
    }

    func createDirectory(name: String, parentID: UUID?, token: String, on req: Request) async throws -> FileIndexItemDTO {
        struct RequestBody: Content {
            let name: String
            let parentID: UUID?
        }

        let res = try await req.client.post(URI(string: "\(baseURL)/api/files/create-directory")) { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: token)
            try clientReq.content.encode(RequestBody(name: name, parentID: parentID))
        }

        if res.status == .conflict {
            throw Abort(.methodNotAllowed, reason: "Resource already exists")
        }
        guard res.status == .ok || res.status == .created, let body = res.body else {
            throw Abort(res.status)
        }
        return try Self.decoder.decode(FileIndexItemDTO.self, from: body)
    }

    func rename(fileID: UUID, to newName: String, token: String, on req: Request) async throws -> FileIndexItemDTO {
        struct RequestBody: Content {
            let name: String
        }

        let res = try await req.client.patch(URI(string: "\(baseURL)/api/files/\(fileID.uuidString)")) { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: token)
            try clientReq.content.encode(RequestBody(name: newName))
        }
        guard res.status == .ok, let body = res.body else {
            throw Abort(res.status)
        }
        return try Self.decoder.decode(FileIndexItemDTO.self, from: body)
    }

    func move(fileID: UUID, toParentID: UUID?, token: String, on req: Request) async throws {
        struct RequestBody: Content {
            let ids: [UUID]
            let parentID: UUID?
        }

        let res = try await req.client.post(URI(string: "\(baseURL)/api/files/move")) { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: token)
            try clientReq.content.encode(RequestBody(ids: [fileID], parentID: toParentID))
        }
        guard res.status == .ok else {
            throw Abort(res.status)
        }
    }

    func copy(fileID: UUID, toParentID: UUID?, newName: String?, token: String, on req: Request) async throws -> FileIndexItemDTO {
        struct RequestBody: Content {
            let id: UUID
            let parentID: UUID?
            let name: String?
        }

        let res = try await req.client.post(URI(string: "\(baseURL)/api/files/copy")) { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: token)
            try clientReq.content.encode(RequestBody(id: fileID, parentID: toParentID, name: newName))
        }
        guard res.status == .ok || res.status == .created, let body = res.body else {
            throw Abort(res.status)
        }
        return try Self.decoder.decode(FileIndexItemDTO.self, from: body)
    }

    func delete(fileID: UUID, token: String, on req: Request) async throws {
        struct RequestBody: Content {
            let ids: [UUID]
        }

        let res = try await req.client.post(URI(string: "\(baseURL)/api/files/trash")) { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: token)
            try clientReq.content.encode(RequestBody(ids: [fileID]))
        }
        guard res.status == .ok || res.status == .noContent else {
            throw Abort(res.status)
        }
    }

    func download(fileID: UUID, headers: HTTPHeaders, token: String, on req: Request) async throws -> Response {
        var clientReq = HTTPClientRequest(url: "\(baseURL)/api/files/\(fileID.uuidString)/download")
        clientReq.method = .GET
        clientReq.headers.bearerAuthorization = BearerAuthorization(token: token)

        if let range = headers.first(name: .range) {
            clientReq.headers.replaceOrAdd(name: .range, value: range)
        }
        if let ifNoneMatch = headers.first(name: .ifNoneMatch) {
            clientReq.headers.replaceOrAdd(name: .ifNoneMatch, value: ifNoneMatch)
        }

        let client = req.application.http.client.shared
        let clientRes = try await client.execute(clientReq, timeout: .minutes(60))

        let response = Response(status: clientRes.status, headers: clientRes.headers)
        response.body = .init(managedAsyncStream: { writer in
            for try await chunk in clientRes.body {
                try await writer.write(.buffer(chunk))
            }
        })
        return response
    }

    func upload(
        filename: String,
        parentID: UUID?,
        stream: Request.Body,
        contentLength: Int64?,
        contentType: String,
        token: String,
        overwrite: Bool,
        on req: Request
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

        var clientReq = HTTPClientRequest(url: "\(baseURL)/api/files/upload?\(query.joined(separator: "&"))")
        clientReq.method = .POST
        clientReq.headers.bearerAuthorization = BearerAuthorization(token: token)
        clientReq.headers.replaceOrAdd(name: .contentType, value: contentType)

        if let contentLength {
            clientReq.headers.replaceOrAdd(name: .contentLength, value: String(contentLength))
            clientReq.body = .stream(stream, length: .known(contentLength))
        } else {
            clientReq.body = .stream(stream, length: .unknown)
        }

        let client = req.application.http.client.shared
        let clientRes = try await client.execute(clientReq, timeout: .hours(4))

        guard clientRes.status == .ok || clientRes.status == .created else {
            throw Abort(clientRes.status)
        }
        return Response(status: clientRes.status)
    }
}
