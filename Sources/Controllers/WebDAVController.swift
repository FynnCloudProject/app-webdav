import AsyncHTTPClient
import Foundation
import Vapor

struct WebDAVController: RouteCollection {
    let client: FynnCloudAPIClient?

    init(client: FynnCloudAPIClient? = nil) {
        self.client = client
    }

    private func apiClient(for req: Request) -> FynnCloudAPIClient {
        client ?? FynnCloudAPIClient(req: req)
    }

    private static let hrefAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove("/")
        return set
    }()

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped(WebDAVAuthenticator())

        let methods: [HTTPMethod] = [
            .OPTIONS, .GET, .HEAD, .PUT, .DELETE,
            HTTPMethod(rawValue: "PROPFIND"),
            HTTPMethod(rawValue: "PROPPATCH"),
            HTTPMethod(rawValue: "MKCOL"),
            HTTPMethod(rawValue: "MOVE"),
            HTTPMethod(rawValue: "COPY"),
            HTTPMethod(rawValue: "LOCK"),
            HTTPMethod(rawValue: "UNLOCK")
        ]

        for method in methods {
            if method == .PUT {
                auth.on(method, body: .stream, use: handle)
                auth.on(method, "**", body: .stream, use: handle)
            } else {
                auth.on(method, use: handle)
                auth.on(method, "**", use: handle)
            }
        }
    }

    func handle(req: Request) async throws -> Response {
        switch req.method.rawValue {
        case "OPTIONS": return try await options(req: req)
        case "PROPFIND": return try await propfind(req: req)
        case "PROPPATCH": return try await proppatch(req: req)
        case "GET", "HEAD": return try await get(req: req)
        case "PUT": return try await put(req: req)
        case "DELETE": return try await delete(req: req)
        case "MKCOL": return try await mkcol(req: req)
        case "MOVE": return try await move(req: req)
        case "COPY": return try await copy(req: req)
        case "LOCK": return try await lock(req: req)
        case "UNLOCK": return try await unlock(req: req)
        default: throw Abort(.methodNotAllowed)
        }
    }

    // MARK: - Handlers

    func options(req: Request) async throws -> Response {
        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: "DAV", value: "1, 2")
        res.headers.replaceOrAdd(name: "MS-Author-Via", value: "DAV")
        res.headers.replaceOrAdd(
            name: .allow,
            value: "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK"
        )
        res.headers.replaceOrAdd(name: .contentLength, value: "0")
        return res
    }

    func propfind(req: Request) async throws -> Response {
        let user = try req.auth.require(WebDAVUser.self)
        let api = apiClient(for: req)
        let segments = pathSegments(req)
        let depth = req.headers.first(name: "Depth") ?? "1"

        var entries: [DAVEntry] = []

        if segments.isEmpty {
            entries.append(DAVEntry(
                href: href(req: req, segments: [], isCollection: true),
                displayName: "/",
                isCollection: true,
                size: 0,
                contentType: "httpd/unix-directory",
                lastModified: Date(),
                created: nil
            ))
            if depth != "0" {
                let children = try await api.listChildren(folderID: nil, token: user.token)
                for child in children {
                    entries.append(makeEntry(child, req: req, segments: [child.filename]))
                }
            }
        } else {
            guard let target = try await api.resolvePath(segments, token: user.token) else {
                throw Abort(.notFound)
            }
            entries.append(makeEntry(target, req: req, segments: segments))
            if target.isDirectory && depth != "0" {
                let children = try await api.listChildren(folderID: target.id, token: user.token)
                for child in children {
                    entries.append(makeEntry(child, req: req, segments: segments + [child.filename]))
                }
            }
        }

        return multistatusResponse(buildMultistatus(entries))
    }

    func proppatch(req: Request) async throws -> Response {
        let user = try req.auth.require(WebDAVUser.self)
        let api = apiClient(for: req)
        let segments = pathSegments(req)
        let target = try await api.resolvePath(segments, token: user.token)
        guard target != nil else { throw Abort(.notFound) }

        let isCollection = target?.isDirectory ?? true
        let targetHREF = escapeXML(href(req: req, segments: segments, isCollection: isCollection))
        let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
            <D:response>
            <D:href>\(targetHREF)</D:href>
            <D:propstat><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            </D:response>
            </D:multistatus>
            """
        return multistatusResponse(body)
    }

    func get(req: Request) async throws -> Response {
        let user = try req.auth.require(WebDAVUser.self)
        let api = apiClient(for: req)
        let segments = pathSegments(req)
        guard !segments.isEmpty,
              let file = try await api.resolvePath(segments, token: user.token) else {
            throw Abort(.notFound)
        }
        guard !file.isDirectory else {
            throw Abort(.methodNotAllowed, reason: "Cannot GET a directory")
        }
        guard let fileID = file.id else {
            throw Abort(.internalServerError)
        }

        let res = try await api.download(fileID: fileID, headers: req.headers, token: user.token)
        if req.method == .HEAD {
            res.body = .init()
            res.headers.replaceOrAdd(name: .contentLength, value: String(file.size))
        }
        return res
    }

    func put(req: Request) async throws -> Response {
        let user = try req.auth.require(WebDAVUser.self)
        let api = apiClient(for: req)
        let segments = pathSegments(req)
        guard let filename = segments.last, !filename.isEmpty else {
            throw Abort(.badRequest)
        }

        if isPlatformMetadata(filename) {
            for try await _ in req.body {}
            return Response(status: .created)
        }

        let contentType = req.headers.first(name: .contentType) ?? "application/octet-stream"
        guard let contentLength = req.headers.first(name: .contentLength).flatMap(Int64.init),
              contentLength >= 0 else {
            throw Abort(.lengthRequired)
        }
        let parentSegments = Array(segments.dropLast())
        let parentID = try await resolveParentID(req, segments: parentSegments, token: user.token)

        let existing = try await api.resolvePath(segments, token: user.token)
        if existing?.isDirectory == true {
            for try await _ in req.body {}
            throw Abort(.methodNotAllowed, reason: "Cannot PUT to a directory")
        }

        return try await api.upload(
            filename: filename,
            parentID: parentID,
            existingFileID: existing?.id,
            body: req.body,
            contentLength: contentLength,
            contentType: contentType,
            token: user.token
        )
    }

    func mkcol(req: Request) async throws -> Response {
        let user = try req.auth.require(WebDAVUser.self)
        let api = apiClient(for: req)
        let segments = pathSegments(req)
        guard let name = segments.last, !name.isEmpty else { throw Abort(.badRequest) }

        if try await api.resolvePath(segments, token: user.token) != nil {
            throw Abort(.methodNotAllowed, reason: "Resource already exists")
        }

        let parentSegments = Array(segments.dropLast())
        let parentID = try await resolveParentID(req, segments: parentSegments, token: user.token)

        _ = try await api.createDirectory(name: name, parentID: parentID, token: user.token)
        return Response(status: .created)
    }

    func delete(req: Request) async throws -> Response {
        let user = try req.auth.require(WebDAVUser.self)
        let api = apiClient(for: req)
        let segments = pathSegments(req)
        guard !segments.isEmpty,
              let file = try await api.resolvePath(segments, token: user.token) else {
            if let name = segments.last, isPlatformMetadata(name) {
                return Response(status: .noContent)
            }
            throw Abort(.notFound)
        }

        guard let fileID = file.id else { throw Abort(.internalServerError) }
        try await api.delete(fileID: fileID, token: user.token)
        return Response(status: .noContent)
    }

    func move(req: Request) async throws -> Response {
        let user = try req.auth.require(WebDAVUser.self)
        let api = apiClient(for: req)
        let srcSegments = pathSegments(req)
        guard !srcSegments.isEmpty,
              let source = try await api.resolvePath(srcSegments, token: user.token),
              let sourceID = source.id else {
            throw Abort(.notFound)
        }

        let destSegments = try destinationSegments(req)
        guard let destName = destSegments.last, !destName.isEmpty else { throw Abort(.badRequest) }
        let overwrite = (req.headers.first(name: "Overwrite") ?? "T").uppercased() != "F"
        let destParentSegments = Array(destSegments.dropLast())
        let destParentID = try await resolveParentID(req, segments: destParentSegments, token: user.token)

        var created = true
        if let existingDest = try await api.resolvePath(destSegments, token: user.token),
           let existingID = existingDest.id {
            guard overwrite else { throw Abort(.preconditionFailed) }
            try await api.delete(fileID: existingID, token: user.token)
            created = false
        }

        if source.parent?.id == destParentID {
            _ = try await api.rename(fileID: sourceID, to: destName, token: user.token)
        } else {
            try await api.move(fileID: sourceID, toParentID: destParentID, token: user.token)
            if destName != source.filename {
                _ = try await api.rename(fileID: sourceID, to: destName, token: user.token)
            }
        }

        return Response(status: created ? .created : .noContent)
    }

    func copy(req: Request) async throws -> Response {
        let user = try req.auth.require(WebDAVUser.self)
        let api = apiClient(for: req)
        let srcSegments = pathSegments(req)
        guard !srcSegments.isEmpty,
              let source = try await api.resolvePath(srcSegments, token: user.token),
              let sourceID = source.id else {
            throw Abort(.notFound)
        }

        let destSegments = try destinationSegments(req)
        guard let destName = destSegments.last, !destName.isEmpty else { throw Abort(.badRequest) }
        let overwrite = (req.headers.first(name: "Overwrite") ?? "T").uppercased() != "F"
        let destParentSegments = Array(destSegments.dropLast())
        let destParentID = try await resolveParentID(req, segments: destParentSegments, token: user.token)

        var created = true
        if let existingDest = try await api.resolvePath(destSegments, token: user.token),
           let existingID = existingDest.id {
            guard overwrite else { throw Abort(.preconditionFailed) }
            try await api.delete(fileID: existingID, token: user.token)
            created = false
        }

        _ = try await api.copy(fileID: sourceID, toParentID: destParentID, newName: destName, token: user.token)
        return Response(status: created ? .created : .noContent)
    }

    func lock(req: Request) async throws -> Response {
        let token = "opaquelocktoken:\(UUID().uuidString)"
        let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:prop xmlns:D="DAV:">
            <D:lockdiscovery>
            <D:activelock>
            <D:locktype><D:write/></D:locktype>
            <D:lockscope><D:exclusive/></D:lockscope>
            <D:depth>infinity</D:depth>
            <D:timeout>Second-3600</D:timeout>
            <D:locktoken><D:href>\(token)</D:href></D:locktoken>
            </D:activelock>
            </D:lockdiscovery>
            </D:prop>
            """
        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "application/xml; charset=utf-8")
        res.headers.replaceOrAdd(name: "Lock-Token", value: "<\(token)>")
        res.body = .init(string: body)
        return res
    }

    func unlock(req: Request) async throws -> Response {
        Response(status: .noContent)
    }

    // MARK: - Helpers

    private func resolveParentID(_ req: Request, segments: [String], token: String) async throws -> UUID? {
        if segments.isEmpty { return nil }
        let api = apiClient(for: req)
        guard let parent = try await api.resolvePath(segments, token: token), parent.isDirectory else {
            throw Abort(.conflict, reason: "Parent collection does not exist")
        }
        return parent.id
    }

    private func pathSegments(_ req: Request) -> [String] {
        var comps = req.url.path.split(separator: "/").map(String.init)
        if let idx = comps.firstIndex(of: "proxy") {
            comps = Array(comps[(idx + 1)...])
        }
        return comps
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { !$0.isEmpty }
    }

    private func destinationSegments(_ req: Request) throws -> [String] {
        guard let raw = req.headers.first(name: "Destination") else {
            throw Abort(.badRequest, reason: "Missing Destination header")
        }
        let pathString: String
        if let url = URL(string: raw), url.host != nil {
            pathString = url.path
        } else {
            pathString = raw
        }
        var comps = pathString.split(separator: "/").map(String.init)
        if let idx = comps.firstIndex(of: "proxy") {
            comps = Array(comps[(idx + 1)...])
        }
        return comps.map { $0.removingPercentEncoding ?? $0 }.filter { !$0.isEmpty }
    }

    private func isPlatformMetadata(_ name: String) -> Bool {
        if name.hasPrefix("._") { return true }
        switch name {
        case ".DS_Store", ".localized", ".metadata_never_index",
            ".Spotlight-V100", ".Trashes", ".fseventsd", ".apdisk", ".TemporaryItems",
            "Thumbs.db", "desktop.ini":
            return true
        default:
            return false
        }
    }

    private func makeEntry(_ file: FileIndexItemDTO, req: Request, segments: [String]) -> DAVEntry {
        DAVEntry(
            href: href(req: req, segments: segments, isCollection: file.isDirectory),
            displayName: file.filename,
            isCollection: file.isDirectory,
            size: file.size,
            contentType: file.isDirectory ? "httpd/unix-directory" : file.contentType,
            lastModified: file.lastModified ?? file.createdAt,
            created: file.createdAt ?? file.uploadedAt
        )
    }

    private func href(req: Request, segments: [String], isCollection: Bool) -> String {
        var base = ""
        if let prefix = req.headers.first(name: "X-Forwarded-Prefix") {
            base = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        } else if req.url.path.contains("/api/apps/webdav/proxy") {
            base = "/api/apps/webdav/proxy"
        }

        var full = base
        for segment in segments {
            let encoded = segment.addingPercentEncoding(withAllowedCharacters: Self.hrefAllowed) ?? segment
            full += "/" + encoded
        }
        if segments.isEmpty || isCollection { full += "/" }
        return full.isEmpty ? "/" : full
    }

    private func multistatusResponse(_ body: String) -> Response {
        let res = Response(status: HTTPResponseStatus(statusCode: 207, reasonPhrase: "Multi-Status"))
        res.headers.replaceOrAdd(name: .contentType, value: "application/xml; charset=utf-8")
        res.body = .init(string: body)
        return res
    }

    private func buildMultistatus(_ entries: [DAVEntry]) -> String {
        let httpDate = Self.makeHTTPDateFormatter()
        let iso = ISO8601DateFormatter()

        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n"
        for entry in entries {
            xml += "<D:response><D:href>\(escapeXML(entry.href))</D:href><D:propstat><D:prop>"
            xml += "<D:displayname>\(escapeXML(entry.displayName))</D:displayname>"
            if let modified = entry.lastModified {
                xml += "<D:getlastmodified>\(httpDate.string(from: modified))</D:getlastmodified>"
            }
            if let created = entry.created {
                xml += "<D:creationdate>\(iso.string(from: created))</D:creationdate>"
            }
            if entry.isCollection {
                xml += "<D:resourcetype><D:collection/></D:resourcetype>"
            } else {
                xml += "<D:resourcetype/>"
                xml += "<D:getcontentlength>\(entry.size)</D:getcontentlength>"
                xml += "<D:getcontenttype>\(escapeXML(entry.contentType))</D:getcontenttype>"
            }
            xml += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"
        }
        xml += "</D:multistatus>"
        return xml
    }

    private func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func makeHTTPDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }
}
