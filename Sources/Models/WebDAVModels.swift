import Foundation
import Vapor

struct WebDAVUser: Authenticatable {
    let username: String
    let token: String
}

struct FileIndexItemDTO: Content {
    let id: UUID?
    let filename: String
    let contentType: String
    let size: Int64
    let isDirectory: Bool
    let lastModified: Date?
    let createdAt: Date?
    let uploadedAt: Date?
    let parent: ParentID?

    struct ParentID: Content {
        let id: UUID
    }
}

struct FileIndexDTO: Content {
    let files: [FileIndexItemDTO]
    let parentID: UUID?
    let totalCount: Int
    let hasMore: Bool
}

struct VerifyAppPasswordResponse: Content {
    let token: String
    let expiresIn: Int
}

struct DAVEntry {
    let href: String
    let displayName: String
    let isCollection: Bool
    let size: Int64
    let contentType: String
    let lastModified: Date?
    let created: Date?
}
