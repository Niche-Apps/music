import Foundation
import OSLog
import Security

let orLog = Logger(subsystem: "com.standardmusic", category: "openrouter")

/// Which service writes artists, albums, lyrics and artwork.
public enum AIProvider: String, Sendable, CaseIterable, Identifiable {
    case chatGPT, openRouter
    public var id: String { rawValue }
    public var displayName: String { self == .chatGPT ? "ChatGPT" : "OpenRouter" }
}

/// One entry of `GET https://openrouter.ai/api/v1/models`.
public struct OpenRouterModel: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var contextLength: Int?
    public var promptPrice: Double?
    public var completionPrice: Double?
    public var outputModalities: [String]
    public var supportedParameters: [String]

    public var isFree: Bool { promptPrice == 0 && completionPrice == 0 }
    public var outputsImages: Bool { outputModalities.contains("image") }
    public var outputsText: Bool { outputModalities.isEmpty || outputModalities.contains("text") }
    /// Whether the catalog says this model accepts `response_format: json_schema`.
    public var supportsStructuredOutputs: Bool { supportedParameters.contains("structured_outputs") }
    /// "$0.30 / $2.50 per M tokens", "Free", or nil when unknown/variable.
    public var priceSummary: String? {
        if isFree { return "Free" }
        guard let p = promptPrice, let c = completionPrice, p >= 0, c >= 0 else { return nil }
        return String(format: "$%.2f / $%.2f per M tokens", p * 1_000_000, c * 1_000_000)
    }
}

public enum OpenRouterCatalog {
    public static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    /// Free router that picks among currently-available free models (verified live, Nov 2026).
    public static let defaultModel = "openrouter/free"
    /// Cheap paid backup when free models are rate-limited.
    public static let cheapBackupModel = "google/gemini-2.5-flash-lite"
    /// Suggested image model (only used if the listener opts in to paid artwork).
    public static let suggestedImageModel = "google/gemini-2.5-flash-image"

    public static func parse(_ data: Data) throws -> [OpenRouterModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["data"] as? [[String: Any]]
        else { throw ChatGPTError.malformed("models: no data") }
        func price(_ any: Any?) -> Double? {
            if let s = any as? String { return Double(s) }
            return (any as? NSNumber)?.doubleValue
        }
        return items.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let arch = m["architecture"] as? [String: Any]
            let pricing = m["pricing"] as? [String: Any]
            return OpenRouterModel(
                id: id, name: m["name"] as? String ?? id,
                contextLength: (m["context_length"] as? NSNumber)?.intValue,
                promptPrice: price(pricing?["prompt"]), completionPrice: price(pricing?["completion"]),
                outputModalities: arch?["output_modalities"] as? [String] ?? [],
                supportedParameters: m["supported_parameters"] as? [String] ?? [])
        }
    }

    /// Free models first, then cheapest, then by name.
    public static func filter(
        _ models: [OpenRouterModel], search: String, freeOnly: Bool, imageOnly: Bool = false
    ) -> [OpenRouterModel] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return models.filter { m in
            (!freeOnly || m.isFree) && (!imageOnly || m.outputsImages)
                && (q.isEmpty || m.id.lowercased().contains(q) || m.name.lowercased().contains(q))
        }.sorted { a, b in
            if a.isFree != b.isFree { return a.isFree }
            let pa = (a.promptPrice ?? .infinity) < 0 ? .infinity : (a.promptPrice ?? .infinity)
            let pb = (b.promptPrice ?? .infinity) < 0 ? .infinity : (b.promptPrice ?? .infinity)
            if pa != pb { return pa < pb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Any slug the listener types: trimmed, non-empty, no inner whitespace. Not checked against the catalog
    /// on purpose so brand-new or private slugs work immediately.
    public static func normalizedModelID(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return s
    }

    /// Fetches the public catalog (unauthenticated, free) and caches it on disk.
    public static func fetch(cache: URL?) async throws -> [OpenRouterModel] {
        let (data, response) = try await URLSession.shared.data(from: modelsURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatGPTError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "Couldn't load OpenRouter models")
        }
        let models = try parse(data)
        if let cache { try? data.write(to: cache, options: .atomic) }
        return models
    }

    public static func cached(at url: URL?) -> [OpenRouterModel] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? parse(data)) ?? []
    }
}

/// Pulls a JSON document out of whatever a model returned: code fences, `<think>` blocks, chatter.
public enum OpenRouterJSON {
    public static func extract(_ raw: String) -> String? {
        var text = raw
        // Drop reasoning blocks.
        for tag in ["think", "thinking", "reasoning"] {
            while let open = text.range(of: "<\(tag)>"),
                let close = text.range(of: "</\(tag)>", range: open.upperBound ..< text.endIndex)
            {
                text.removeSubrange(open.lowerBound ..< close.upperBound)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isJSON(text) { return text }
        // Fenced block.
        if let fence = text.range(of: "```") {
            var inner = text[fence.upperBound...]
            if let nl = inner.firstIndex(of: "\n") { inner = inner[inner.index(after: nl)...] }
            if let end = inner.range(of: "```") {
                let candidate = inner[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if isJSON(candidate) { return candidate }
            }
        }
        // First balanced {...} or [...] that parses.
        let chars = Array(text)
        for (i, c) in chars.enumerated() where c == "{" || c == "[" {
            if let end = balancedEnd(chars, from: i) {
                let candidate = String(chars[i ... end])
                if isJSON(candidate) { return candidate }
            }
        }
        return nil
    }

    static func isJSON(_ s: String) -> Bool {
        guard let first = s.first, first == "{" || first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) != nil
    }

    static func balancedEnd(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for i in start ..< chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
        }
        return nil
    }
}

/// The OpenRouter API key: Keychain first, then `OPENROUTER_API_KEY` from the environment.
public enum OpenRouterKey {
    static let service = "com.standardmusic.openrouter"
    static let account = "api-key"

    public static func resolve(stored: String?, environment: [String: String]) -> String? {
        for candidate in [stored, environment["OPENROUTER_API_KEY"]] {
            if let k = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        }
        return nil
    }

    public static var current: String? {
        resolve(stored: load(), environment: ProcessInfo.processInfo.environment)
    }

    public static var environmentKeyAvailable: Bool {
        resolve(stored: nil, environment: ProcessInfo.processInfo.environment) != nil
    }

    public static var isStored: Bool { load() != nil }

    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        delete()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// `/api/v1/chat/completions` client that works across model families: native JSON-schema models,
/// free endpoints, reasoning models and providers that reject `response_format`.
public actor OpenRouterClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private let apiKey: String
    private let transport: Transport
    /// Models that rejected (or per the catalog don't support) `response_format: json_schema`.
    private var schemaUnsupported: Set<String> = []

    public init(apiKey: String, transport: Transport? = nil) {
        self.apiKey = apiKey
        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 180
            config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ChatGPTError.failed("No response") }
                return (data, http)
            }
        }
    }

    public func noteCatalog(_ models: [OpenRouterModel]) {
        for m in models where !m.supportsStructuredOutputs && !m.supportedParameters.isEmpty { schemaUnsupported.insert(m.id) }
    }

    public func markSchemaUnsupported(_ model: String) { schemaUnsupported.insert(model) }

    /// Returns UTF-8 JSON data for the schema; the caller decodes it.
    public func json(schemaName: String, schema: JSON, instructions: String, prompt: String, model: String) async throws -> Data {
        let schemaText = String(decoding: (try? JSONEncoder().encode(schema)) ?? Data(), as: UTF8.self)
        let system = instructions + """


        Respond with ONLY a single JSON object that matches this JSON schema (named "\(schemaName)"). \
        Include every property, no extra keys, no markdown fences, no commentary:
        \(schemaText)
        """
        var useSchema = !schemaUnsupported.contains(model)
        while true {
            var body: [String: JSON] = [
                "model": .string(model),
                "messages": [["role": "system", "content": .string(system)], ["role": "user", "content": .string(prompt)]],
            ]
            if useSchema {
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": ["name": .string(schemaName), "strict": true, "schema": schema],
                ]
            }
            do {
                let message = try await send(body)
                guard let json = OpenRouterJSON.extract(message.content) ?? OpenRouterJSON.extract(message.reasoning)
                else {
                    if useSchema { schemaUnsupported.insert(model); useSchema = false; continue }
                    throw ChatGPTError.malformed("\(schemaName): model didn't return JSON")
                }
                return Data(json.utf8)
            } catch ChatGPTError.http(let status, let text) where useSchema && [400, 404, 422].contains(status) {
                orLog.info("\(model, privacy: .public) rejected json_schema (\(status)); retrying with prompt-guided JSON")
                _ = text
                schemaUnsupported.insert(model)
                useSchema = false
            }
        }
    }

    public func text(instructions: String, prompt: String, model: String) async throws -> String {
        let body: [String: JSON] = [
            "model": .string(model),
            "messages": [["role": "system", "content": .string(instructions)], ["role": "user", "content": .string(prompt)]],
        ]
        let m = try await send(body)
        return m.content.isEmpty ? m.reasoning : m.content
    }

    /// Image generation through chat completions with `modalities`; returns raw image bytes.
    public func image(prompt: String, model: String) async throws -> Data {
        let body: [String: JSON] = [
            "model": .string(model),
            "messages": [["role": "user", "content": .string(prompt)]],
            "modalities": ["image", "text"],
        ]
        let m = try await send(body)
        guard let url = m.imageURLs.first, let data = Self.decodeDataURI(url) else {
            throw ChatGPTError.failed("No image was returned.")
        }
        return data
    }

    /// Free check of the key (`GET /api/v1/key`).
    public func checkKey() async throws -> String? {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        authorize(&request)
        let (data, http) = try await transport(request)
        guard http.statusCode == 200 else { throw Self.error(status: http.statusCode, data: data) }
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["data"] as? [String: Any])?["label"] as? String
    }

    public static func decodeDataURI(_ uri: String) -> Data? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(uri[uri.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }

    struct Message { var content: String; var reasoning: String; var imageURLs: [String] }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/standardagents/music", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Standard Music", forHTTPHeaderField: "X-Title")
    }

    private func send(_ body: [String: JSON]) async throws -> Message {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(JSON.object(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        let (data, http) = try await transport(request)
        guard http.statusCode == 200 else {
            if http.statusCode == 429 {
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                throw ChatGPTError.rateLimited(
                    retryAfter: retry, message: "OpenRouter is rate-limiting this model for now. Generation will resume automatically.")
            }
            throw Self.error(status: http.statusCode, data: data)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTError.malformed("OpenRouter returned non-JSON")
        }
        if let err = root["error"] as? [String: Any] {
            let code = (err["code"] as? NSNumber)?.intValue ?? 0
            let message = err["message"] as? String ?? "OpenRouter request failed."
            if code == 429 { throw ChatGPTError.rateLimited(retryAfter: nil, message: message) }
            throw ChatGPTError.failed("OpenRouter: \(message)")
        }
        guard let choice = (root["choices"] as? [[String: Any]])?.first,
            let message = choice["message"] as? [String: Any]
        else { throw ChatGPTError.malformed("OpenRouter: no choices") }
        var content = message["content"] as? String ?? ""
        if content.isEmpty, let parts = message["content"] as? [[String: Any]] {
            content = parts.compactMap { $0["text"] as? String }.joined()
        }
        let images = (message["images"] as? [[String: Any]] ?? []).compactMap {
            ($0["image_url"] as? [String: Any])?["url"] as? String
        }
        return Message(content: content, reasoning: message["reasoning"] as? String ?? "", imageURLs: images)
    }

    static func error(status: Int, data: Data) -> ChatGPTError {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (root?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(240), as: UTF8.self)
        if status == 401 { return .failed("OpenRouter rejected the API key. Check it in Settings › Account.") }
        if status == 402 { return .failed("OpenRouter: out of credits. Pick a free model or add credits.") }
        return .http(status, "OpenRouter: \(message)")
    }
}
