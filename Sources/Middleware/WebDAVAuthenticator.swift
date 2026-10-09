import Foundation
import Vapor

struct WebDAVAuthenticator: AsyncMiddleware {
    let apiURL: String
    let appID: String
    let appSecret: String

    init(
        apiURL: String = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080",
        appID: String = Environment.get("FYNNCLOUD_APP_ID") ?? Environment.get("APP_ID") ?? "webdav",
        appSecret: String = Environment.get("FYNNCLOUD_APP_SECRET") ?? Environment.get("APP_SECRET") ?? ""
    ) {
        self.apiURL = apiURL.hasSuffix("/") ? String(apiURL.dropLast()) : apiURL
        self.appID = appID
        self.appSecret = appSecret
    }

    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let basic = req.headers.basicAuthorization else {
            return challenge()
        }

        let username = basic.username.lowercased()
        let password = basic.password

        // Only app passwords (prefixed with fc_app_) are accepted for WebDAV
        guard password.hasPrefix("fc_app_") else {
            return challenge()
        }

        let cacheKey = "\(username):\(password)"

        if let cachedToken = await TokenCache.shared.get(cacheKey) {
            req.auth.login(WebDAVUser(username: username, token: cachedToken))
            return try await next.respond(to: req)
        }

        let verifyURI = URI(string: "\(apiURL)/api/auth/app-passwords/verify")
        let authHeader = req.headers.first(name: .authorization) ?? ""

        do {
            let res = try await req.client.post(verifyURI) { clientReq in
                clientReq.headers.replaceOrAdd(name: .authorization, value: authHeader)
                clientReq.headers.replaceOrAdd(name: "X-FynnCloud-App-ID", value: self.appID)
                if !self.appSecret.isEmpty {
                    clientReq.headers.replaceOrAdd(name: "X-FynnCloud-App-Secret", value: self.appSecret)
                }
            }

            guard res.status == .ok, let body = res.body else {
                return challenge()
            }

            let verified = try JSONDecoder().decode(VerifyAppPasswordResponse.self, from: body)
            await TokenCache.shared.set(cacheKey, token: verified.token, expiresIn: verified.expiresIn)

            req.auth.login(WebDAVUser(username: username, token: verified.token))
            return try await next.respond(to: req)
        } catch {
            req.logger.error("Failed to verify app password with backend: \(error)")
            return challenge()
        }
    }

    private func challenge() -> Response {
        let res = Response(status: .unauthorized)
        res.headers.replaceOrAdd(
            name: .wwwAuthenticate,
            value: #"Basic realm="FynnCloud WebDAV", charset="UTF-8""#
        )
        return res
    }
}
