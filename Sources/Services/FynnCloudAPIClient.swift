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

    private struct CreateFilePayload: Encodable {
        let name: String
        let parentID: UUID?
    }

    private struct InitiateMultipartPayload: Encodable {
        let fileID: UUID?
        let filename: String
        let contentType: String
        let totalSize: Int64
        let parentID: UUID?
    }

    private struct InitiateMultipartResponseDTO: Decodable {
        let sessionID: UUID
        let fileID: UUID
        let uploadID: String
        let maxChunkSize: Int64
        let token: String
    }

    private struct PartResultDTO: Codable {
        let partNumber: Int
        let etag: String
        let size: Int64
    }

    private struct CompleteMultipartPayload: Encodable {
        let parts: [PartResultDTO]
    }

    func createEmptyFile(name: String, parentID: UUID?, token: String) async throws -> Response {
        var req = HTTPClientRequest(url: "\(baseURL)/api/files/create-file")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(CreateFilePayload(name: name, parentID: parentID)))

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok || res.status == .created else {
            throw Abort(res.status)
        }
        return Response(status: .created)
    }

    func upload(
        filename: String,
        parentID: UUID?,
        existingFileID: UUID?,
        body: Request.Body,
        contentLength: Int64?,
        contentType: String,
        token: String
    ) async throws -> Response {
        if contentLength == 0, existingFileID == nil {
            for try await _ in body {}
            return try await createEmptyFile(name: filename, parentID: parentID, token: token)
        }

        if let declaredSize = contentLength {
            let session = try await initiateMultipart(
                fileID: existingFileID,
                filename: filename,
                contentType: contentType,
                totalSize: declaredSize,
                parentID: parentID,
                token: token
            )
            try await uploadStreamParts(body: body, totalSize: declaredSize, session: session)
            return Response(status: existingFileID == nil ? .created : .noContent)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("webdav-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let writeHandle = try FileHandle(forWritingTo: tempURL)
        var totalSize: Int64 = 0
        do {
            for try await chunk in body {
                let data = Data(buffer: chunk)
                if !data.isEmpty {
                    try writeHandle.write(contentsOf: data)
                    totalSize += Int64(data.count)
                }
            }
            try? writeHandle.close()
        } catch {
            try? writeHandle.close()
            throw error
        }

        if totalSize == 0, existingFileID == nil {
            return try await createEmptyFile(name: filename, parentID: parentID, token: token)
        }

        let session = try await initiateMultipart(
            fileID: existingFileID,
            filename: filename,
            contentType: contentType,
            totalSize: totalSize,
            parentID: parentID,
            token: token
        )
        try await uploadFileParts(fileURL: tempURL, totalSize: totalSize, session: session)
        return Response(status: existingFileID == nil ? .created : .noContent)
    }

    private func initiateMultipart(
        fileID: UUID?,
        filename: String,
        contentType: String,
        totalSize: Int64,
        parentID: UUID?,
        token: String
    ) async throws -> InitiateMultipartResponseDTO {
        let payload = InitiateMultipartPayload(
            fileID: fileID,
            filename: filename,
            contentType: contentType,
            totalSize: totalSize,
            parentID: parentID
        )
        var req = HTTPClientRequest(url: "\(baseURL)/api/files/multipart/initiate")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(payload))

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok || res.status == .created else {
            throw Abort(res.status)
        }
        let buffer = try await res.body.collect(upTo: 64 * 1024)
        return try Self.decoder.decode(InitiateMultipartResponseDTO.self, from: buffer)
    }

    private final class BodyPartCursor: @unchecked Sendable {
        private var iterator: Request.Body.AsyncIterator
        private var leftover = ByteBuffer()

        init(body: Request.Body) {
            self.iterator = body.makeAsyncIterator()
        }

        func nextChunk(maxBytes: Int) async throws -> ByteBuffer? {
            if leftover.readableBytes > 0 {
                let count = Swift.min(maxBytes, leftover.readableBytes)
                let slice = leftover.readSlice(length: count)
                leftover.discardReadBytes()
                return slice
            }
            guard var frame = try await iterator.next() else {
                return nil
            }
            if frame.readableBytes <= maxBytes {
                return frame
            }
            let slice = frame.readSlice(length: maxBytes)
            leftover.writeBuffer(&frame)
            return slice
        }
    }

    private func uploadStreamParts(
        body: Request.Body,
        totalSize: Int64,
        session: InitiateMultipartResponseDTO
    ) async throws {
        let chunkSize = Swift.max(Int64(5 * 1024 * 1024), Swift.min(session.maxChunkSize, Int64(16 * 1024 * 1024)))
        var completedParts: [PartResultDTO] = []

        do {
            if totalSize <= 0 {
                for try await _ in body {}
            } else if totalSize <= chunkSize {
                let part = try await sendPart(
                    body: .stream(body, length: .known(totalSize)),
                    size: totalSize,
                    partNumber: 1,
                    session: session
                )
                completedParts.append(part)
            } else {
                let cursor = BodyPartCursor(body: body)
                var remainingTotal = totalSize
                var partNumber = 1

                while remainingTotal > 0 {
                    let partSize = Swift.min(chunkSize, remainingTotal)
                    let partStream = AsyncThrowingStream<ByteBuffer, Error> { continuation in
                        Task {
                            var remainingPart = Int(partSize)
                            do {
                                while remainingPart > 0 {
                                    guard let slice = try await cursor.nextChunk(maxBytes: remainingPart),
                                          slice.readableBytes > 0 else {
                                        break
                                    }
                                    remainingPart -= slice.readableBytes
                                    continuation.yield(slice)
                                }
                                continuation.finish()
                            } catch {
                                continuation.finish(throwing: error)
                            }
                        }
                    }

                    let part = try await sendPart(
                        body: .stream(partStream, length: .known(partSize)),
                        size: partSize,
                        partNumber: partNumber,
                        session: session
                    )
                    completedParts.append(part)
                    remainingTotal -= partSize
                    partNumber += 1
                }
            }
            try await completeMultipart(parts: completedParts, session: session)
        } catch {
            await abortMultipart(session: session)
            throw error
        }
    }

    private func uploadFileParts(
        fileURL: URL,
        totalSize: Int64,
        session: InitiateMultipartResponseDTO
    ) async throws {
        let chunkSize = Swift.max(Int64(5 * 1024 * 1024), Swift.min(session.maxChunkSize, Int64(16 * 1024 * 1024)))
        let readHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? readHandle.close() }

        var completedParts: [PartResultDTO] = []
        var partNumber = 1
        var remainingTotal = totalSize

        do {
            while remainingTotal > 0 {
                let partSize = Swift.min(chunkSize, remainingTotal)
                var partRemaining = partSize

                let partStream = AsyncStream<ByteBuffer> { continuation in
                    while partRemaining > 0 {
                        let toRead = Int(Swift.min(partRemaining, Int64(64 * 1024)))
                        guard let slice = try? readHandle.read(upToCount: toRead), !slice.isEmpty else {
                            break
                        }
                        var buffer = ByteBufferAllocator().buffer(capacity: slice.count)
                        buffer.writeBytes(slice)
                        continuation.yield(buffer)
                        partRemaining -= Int64(slice.count)
                    }
                    continuation.finish()
                }

                let part = try await sendPart(
                    body: .stream(partStream, length: .known(partSize)),
                    size: partSize,
                    partNumber: partNumber,
                    session: session
                )
                completedParts.append(part)
                remainingTotal -= partSize
                partNumber += 1
            }
            try await completeMultipart(parts: completedParts, session: session)
        } catch {
            await abortMultipart(session: session)
            throw error
        }
    }

    private func sendPart(
        body: HTTPClientRequest.Body,
        size: Int64,
        partNumber: Int,
        session: InitiateMultipartResponseDTO
    ) async throws -> PartResultDTO {
        var req = HTTPClientRequest(
            url: "\(baseURL)/api/files/multipart/\(session.sessionID.uuidString)/part/\(partNumber)"
        )
        req.method = .PUT
        req.headers.bearerAuthorization = BearerAuthorization(token: session.token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
        req.headers.replaceOrAdd(name: .contentLength, value: String(size))
        req.body = body

        let res = try await client.execute(req, timeout: .minutes(10))
        guard res.status == .ok || res.status == .created else {
            throw Abort(res.status)
        }
        let resBody = try await res.body.collect(upTo: 64 * 1024)
        return try Self.decoder.decode(PartResultDTO.self, from: resBody)
    }

    private func completeMultipart(
        parts: [PartResultDTO],
        session: InitiateMultipartResponseDTO
    ) async throws {
        var req = HTTPClientRequest(
            url: "\(baseURL)/api/files/multipart/\(session.sessionID.uuidString)/complete"
        )
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: session.token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(CompleteMultipartPayload(parts: parts)))

        let res = try await client.execute(req, timeout: .minutes(2))
        guard res.status == .ok || res.status == .created else {
            throw Abort(res.status)
        }
    }

    private func abortMultipart(session: InitiateMultipartResponseDTO) async {
        var req = HTTPClientRequest(
            url: "\(baseURL)/api/files/multipart/\(session.sessionID.uuidString)/abort"
        )
        req.method = .DELETE
        req.headers.bearerAuthorization = BearerAuthorization(token: session.token)
        _ = try? await client.execute(req, timeout: .seconds(15))
    }
}
