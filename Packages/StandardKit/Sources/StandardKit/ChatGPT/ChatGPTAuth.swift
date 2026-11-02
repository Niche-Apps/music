import CryptoKit
import Foundation
import Network
import OSLog

let authLog = Logger(subsystem: "com.standardmusic", category: "auth")

public struct ChatGPTCredentials: Codable, Sendable, Equatable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var accountID: String
    public var email: String?
    public var name: String?
    public var planType: String?
    public var expiresAt: Date
    /// True when these tokens are shared with the Codex CLI (`~/.codex/auth.json`). Refresh tokens rotate,
    /// so linked credentials are always read from and written back to that file to keep both signed in.
    public var linkedToCodex: Bool?

    init(idToken: String, accessToken: String, refreshToken: String) throws {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        let id = JWT.claims(idToken)
        let access = JWT.claims(accessToken)
        let auth = (id?["https://api.openai.com/auth"] ?? access?["https://api.openai.com/auth"]) as? [String: Any]
        guard let account = auth?["chatgpt_account_id"] as? String else { throw ChatGPTError.missingAccount }
        accountID = account
        let profile = access?["https://api.openai.com/profile"] as? [String: Any]
        email = (id?["email"] as? String) ?? (profile?["email"] as? String)
        name = id?["name"] as? String
        planType = auth?["chatgpt_plan_type"] as? String
        let exp = (access?["exp"] as? Double) ?? Date().addingTimeInterval(3600).timeIntervalSince1970
        expiresAt = Date(timeIntervalSince1970: exp)
    }

    public var planDisplayName: String {
        switch planType?.lowercased() {
        case "plus": "ChatGPT Plus"
        case "pro": "ChatGPT Pro"
        case "team": "ChatGPT Team"
        case "business": "ChatGPT Business"
        case "enterprise": "ChatGPT Enterprise"
        case "edu": "ChatGPT Edu"
        case "free": "ChatGPT Free"
        case let other?: "ChatGPT \(other.capitalized)"
        case nil: "ChatGPT"
        }
    }
}

enum JWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// "Sign in with ChatGPT": the same OAuth (PKCE) flow the Codex CLI uses, with a loopback callback on port 1455.
/// Credentials are stored in the app's support directory with owner-only permissions and refreshed automatically.
public actor ChatGPTAuth {
    static let issuer = URL(string: "https://auth.openai.com")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let callbackPort: UInt16 = 1455
    static let redirectURI = "http://localhost:1455/auth/callback"

    private let storeURL: URL
    private var cached: ChatGPTCredentials?
    private var refreshTask: Task<ChatGPTCredentials, Error>?
    private var server: CallbackServer?

    public init(directory: URL) {
        storeURL = directory.appending(path: "chatgpt-auth.json")
        cached = try? JSONDecoder().decode(ChatGPTCredentials.self, from: Data(contentsOf: storeURL))
    }

    public var credentials: ChatGPTCredentials? { cached }

    /// Path of a Codex CLI login on this Mac, if one exists, so users can reuse it.
    public nonisolated static var codexAuthFile: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func importCodexLogin() throws -> ChatGPTCredentials {
        var creds = try Self.readCodexLogin()
        creds.linkedToCodex = true
        try store(creds)
        return creds
    }

    static func readCodexLogin() throws -> ChatGPTCredentials {
        guard let url = Self.codexAuthFile else { throw ChatGPTError.noCodexLogin }
        struct File: Decodable {
            struct Tokens: Decodable {
                var id_token: String
                var access_token: String
                var refresh_token: String
            }
            var tokens: Tokens?
        }
        guard let tokens = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).tokens else {
            throw ChatGPTError.noCodexLogin
        }
        return try ChatGPTCredentials(
            idToken: tokens.id_token, accessToken: tokens.access_token, refreshToken: tokens.refresh_token)
    }

    /// Writes rotated tokens back into the Codex CLI's file, preserving everything else in it.
    static func writeCodexLogin(_ creds: ChatGPTCredentials) {
        guard let url = codexAuthFile, let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        tokens["id_token"] = creds.idToken
        tokens["access_token"] = creds.accessToken
        tokens["refresh_token"] = creds.refreshToken
        tokens["account_id"] = creds.accountID
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) else { return }
        try? out.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Sign in

    /// Starts the browser flow. `open` is called with the authorization URL; returns once the callback arrives.
    public func signIn(open: @Sendable (URL) async -> Void) async throws -> ChatGPTCredentials {
        server?.stop()
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(32)
        var components = URLComponents(url: Self.issuer.appending(path: "oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: "codex_cli_rs"),
        ]
        let server = try CallbackServer(port: Self.callbackPort)
        self.server = server
        defer { server.stop() }
        async let callback = server.waitForCallback()
        await open(components.url!)
        let query = try await callback
        guard query["state"] == state else { throw ChatGPTError.stateMismatch }
        if let error = query["error"] { throw ChatGPTError.oauth(query["error_description"] ?? error) }
        guard let code = query["code"] else { throw ChatGPTError.oauth("No authorization code returned.") }
        let creds = try await exchange(code: code, verifier: verifier)
        try store(creds)
        return creds
    }

    public func cancelSignIn() {
        server?.cancel()
        server = nil
    }

    public func signOut() {
        cached = nil
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: Tokens

    /// A valid credential set, refreshing the access token when it is close to expiry.
    public func validCredentials(forceRefresh: Bool = false) async throws -> ChatGPTCredentials {
        guard var current = cached else { throw ChatGPTError.notSignedIn }
        if current.linkedToCodex == true, let latest = try? Self.readCodexLogin(), latest.refreshToken != current.refreshToken
            || latest.accessToken != current.accessToken
        {
            // Codex refreshed since we last looked; adopt its tokens.
            current = latest
            current.linkedToCodex = true
            try store(current)
        }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 300 { return current }
        if let refreshTask { return try await refreshTask.value }
        let snapshot = current
        let task = Task { try await self.refresh(snapshot) }
        refreshTask = task
        defer { refreshTask = nil }
        var fresh = try await task.value
        fresh.linkedToCodex = current.linkedToCodex
        try store(fresh)
        if fresh.linkedToCodex == true { Self.writeCodexLogin(fresh) }
        return fresh
    }

    private func refresh(_ creds: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        var request = URLRequest(url: Self.issuer.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": creds.refreshToken,
            "scope": "openid profile email",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            authLog.error("Token refresh failed with \(status)")
            if status == 400 || status == 401 { throw ChatGPTError.sessionExpired }
            throw ChatGPTError.http(status, String(decoding: data, as: UTF8.self))
        }
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try ChatGPTCredentials(
            idToken: body["id_token"] as? String ?? creds.idToken,
            accessToken: body["access_token"] as? String ?? creds.accessToken,
            refreshToken: body["refresh_token"] as? String ?? creds.refreshToken)
    }

    private func exchange(code: String, verifier: String) async throws -> ChatGPTCredentials {
        var request = URLRequest(url: Self.issuer.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID, "code_verifier": verifier,
        ]
        request.httpBody = form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = body["id_token"] as? String, let access = body["access_token"] as? String,
            let refresh = body["refresh_token"] as? String
        else { throw ChatGPTError.http(status, String(decoding: data, as: UTF8.self)) }
        return try ChatGPTCredentials(idToken: id, accessToken: access, refreshToken: refresh)
    }

    private func store(_ creds: ChatGPTCredentials) throws {
        cached = creds
        let data = try JSONEncoder().encode(creds)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storeURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

// MARK: - Loopback callback server

/// Minimal HTTP listener on 127.0.0.1 that captures the OAuth redirect.
final class CallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "oauth-callback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private let lock = NSLock()

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        do {
            listener = try NWListener(using: params)
        } catch {
            throw ChatGPTError.portInUse
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(.failure(ChatGPTError.portInUse)) }
        }
        listener.start(queue: queue)
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let pending {
                lock.unlock()
                cont.resume(with: pending)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    func stop() { listener.cancel() }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let continuation {
            continuation.resume(with: result)
            self.continuation = nil
        } else if pending == nil {
            pending = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                let line = request.split(separator: "\r\n").first
            else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            let components = URLComponents(string: "http://localhost\(target)")
            guard components?.path == "/auth/callback" else {
                self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value }
            let ok = query["code"] != nil
            self.respond(connection, status: "200 OK", body: Self.page(success: ok))
            self.finish(.success(query))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(success: Bool) -> String {
        let title = success ? "You're signed in" : "Sign-in didn't finish"
        let message = success
            ? "Head back to Standard Music — your library is about to start taking shape."
            : "Return to Standard Music and try again."
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>Standard Music</title>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
            :root{color-scheme:light dark}
            body{margin:0;height:100vh;display:grid;place-items:center;font:15px -apple-system,system-ui;
            background:radial-gradient(1200px 600px at 30% 20%,#ff2d55 0%,transparent 60%),radial-gradient(900px 600px at 80% 90%,#5e5ce6 0%,transparent 55%),#111;color:#fff}
            .card{padding:40px 48px;border-radius:24px;background:rgba(255,255,255,.08);backdrop-filter:blur(30px);
            border:1px solid rgba(255,255,255,.15);text-align:center;max-width:380px}
            h1{font-size:24px;margin:0 0 8px} p{opacity:.75;line-height:1.5;margin:0}
            .mark{font-size:44px;margin-bottom:12px}
            </style></head><body><div class="card"><div class="mark">\(success ? "♫" : "!")</div>
            <h1>\(title)</h1><p>\(message)</p></div>
            <script>setTimeout(()=>window.close(),2500)</script></body></html>
            """
    }
}
