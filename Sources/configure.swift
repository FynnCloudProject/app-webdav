import Vapor

func configure(_ app: Application) async throws {
    let port = Environment.get("PORT").flatMap(Int.init) ?? 3080
    let host = Environment.get("HOST") ?? "0.0.0.0"

    app.http.server.configuration.hostname = host
    app.http.server.configuration.port = port
    app.routes.defaultMaxBodySize = "50gb"

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .customISO8601
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    try routes(app)
    app.logger.info("WebDAV listening on http://\(host):\(port)")
}
