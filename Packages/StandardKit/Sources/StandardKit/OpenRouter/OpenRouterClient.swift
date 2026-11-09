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

    /// `openrouter/free` and any `:free` slug. A paid id, including a last-resort override, is not free.
    public static func isFreeModel(_ model: String) -> Bool {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id == defaultModel || id.hasSuffix(":free")
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

    /// Data-protection Keychain items are tied to the app's signature. An ad-hoc re-sign after
    /// reinstall returns `errSecMissingEntitlement` or `errSecAuthFailed` instead of the key.
    /// Those statuses fall back to a 0600 file. A normal "not found" does not, so Clear still forgets the key.
    public static func isAdHocKeychainFailure(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecAuthFailed || status == errSecInteractionNotAllowed
    }

    public static func load() -> String? {
        resolveStored(keychainRead: readKeychain, root: fallbackRoot)
    }

    public static var isStored: Bool { load() != nil }

    public static var fileFallbackIsPresent: Bool {
        FileManager.default.fileExists(atPath: fallbackFile(root: fallbackRoot).path)
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        persist(key, keychainWrite: writeKeychain, keychainDelete: deleteKeychainItem, root: fallbackRoot)
    }

    public static func delete() {
        _ = deleteKeychainItem()
        try? FileManager.default.removeItem(at: fallbackFile(root: fallbackRoot))
    }

    static func resolveStored(keychainRead: () -> (OSStatus, String?), root: URL) -> String? {
        let (status, value) = keychainRead()
        if let value, !value.isEmpty { return value }
        // Item-not-found still checks the file: an ad-hoc save may have had nowhere else to put the key.
        // Clear deletes the file, so a real removal stays removed.
        if status == errSecItemNotFound || isAdHocKeychainFailure(status) {
            return readFile(root: root)
        }
        return nil
    }

    static func persist(
        _ key: String, keychainWrite: (String) -> OSStatus, keychainDelete: () -> OSStatus, root: URL
    ) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = keychainDelete()
        guard !trimmed.isEmpty else {
            try? FileManager.default.removeItem(at: fallbackFile(root: root))
            return true
        }
        let status = keychainWrite(trimmed)
        if status == errSecSuccess {
            try? FileManager.default.removeItem(at: fallbackFile(root: root))
            return true
        }
        if status == errSecDuplicateItem {
            _ = keychainDelete()
            if keychainWrite(trimmed) == errSecSuccess {
                try? FileManager.default.removeItem(at: fallbackFile(root: root))
                return true
            }
        }
        guard isAdHocKeychainFailure(status) || status == errSecDuplicateItem else { return false }
        return writeFile(trimmed, root: root)
    }

    static var fallbackRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appending(path: "StandardMusic", directoryHint: .isDirectory)
    }

    private static func fallbackFile(root: URL) -> URL {
        root.appending(path: "openrouter-key", directoryHint: .notDirectory)
    }

    private static func readKeychain() -> (OSStatus, String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return (status, nil) }
        let value = String(decoding: data, as: UTF8.self)
        return (status, value.isEmpty ? nil : value)
    }

    private static func writeKeychain(_ key: String) -> OSStatus {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(attrs as CFDictionary, nil)
    }

    @discardableResult
    private static func deleteKeychainItem() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    private static func readFile(root: URL) -> String? {
        guard let data = try? Data(contentsOf: fallbackFile(root: root)) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func writeFile(_ key: String, root: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = fallbackFile(root: root)
            try Data(key.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

/// `/api/v1/chat/completions` client that works across model families: native JSON-schema models,
/// free endpoints, reasoning models and providers that reject `response_format`.
public actor OpenRouterClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private let apiKey: String
    private let transport: Transport
    private let clock: any OpenRouterClock
    private var paidFallback: OpenRouterPaidFallback
    /// Models that rejected (or per the catalog don't support) `response_format: json_schema`.
    private var schemaUnsupported: Set<String> = []
    /// Free text models from the last catalog refresh. Image-only models are left out.
    private var catalogFree: [String] = []
    /// Reserved start time of the next free-model request. Set before any await so concurrent callers share it.
    private var nextFreeAt: Date?
    private var activityHandler: (@Sendable (LibraryWorkStatus) -> Void)?

    public init(
        apiKey: String, transport: Transport? = nil, clock: any OpenRouterClock = SystemOpenRouterClock(),
        paidFallback: OpenRouterPaidFallback = .off
    ) {
        self.apiKey = apiKey
        self.clock = clock
        self.paidFallback = paidFallback
        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = OpenRouterFreeChain.requestTimeout
            config.timeoutIntervalForResource = OpenRouterFreeChain.requestTimeout
            let session = URLSession(configuration: config)
            self.transport = { request in
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: request)
                } catch let error as URLError where error.code == .timedOut {
                    throw error
                } catch let error as URLError where OpenRouterClient.isTransient(error) {
                    // Dropped connections are retryable (ChatGPTError.failed), not batch-ending.
                    throw ChatGPTError.failed("Lost the connection to OpenRouter (\(error.localizedDescription)). Retrying…")
                }
                guard let http = response as? HTTPURLResponse else { throw ChatGPTError.failed("No response") }
                return (data, http)
            }
        }
    }

    static func isTransient(_ error: URLError) -> Bool {
        [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
         .dnsLookupFailed, .secureConnectionFailed, .badServerResponse, .resourceUnavailable].contains(error.code)
    }

    public func noteCatalog(_ models: [OpenRouterModel]) {
        for m in models where !m.supportsStructuredOutputs && !m.supportedParameters.isEmpty { schemaUnsupported.insert(m.id) }
        catalogFree = models.filter { $0.isFree && $0.outputsText && !$0.outputsImages }.map(\.id)
    }

    public func markSchemaUnsupported(_ model: String) { schemaUnsupported.insert(model) }

    public func setPaidFallback(_ fallback: OpenRouterPaidFallback) { paidFallback = fallback }

    public func setActivityHandler(_ handler: (@Sendable (LibraryWorkStatus) -> Void)?) {
        activityHandler = handler
    }

    /// Returns UTF-8 JSON data for the schema; the caller decodes it.
    public func json(schemaName: String, schema: JSON, instructions: String, prompt: String, model: String) async throws -> Data {
        let schemaText = String(decoding: (try? JSONEncoder().encode(schema)) ?? Data(), as: UTF8.self)
        let system = instructions + """


        Respond with ONLY a single JSON object that matches this JSON schema (named "\(schemaName)"). \
        Include every property, no extra keys, no markdown fences, no commentary:
        \(schemaText)
        """
        return try await attemptChain(model) { candidate in
            var useSchema = !self.schemaUnsupported.contains(candidate)
            while true {
                var body = self.lightBody(model: candidate, system: system, prompt: prompt)
                if useSchema {
                    body["response_format"] = [
                        "type": "json_schema",
                        "json_schema": ["name": .string(schemaName), "strict": true, "schema": schema],
                    ]
                }
                do {
                    let message = try await self.send(body)
                    guard let json = OpenRouterJSON.extract(message.content) ?? OpenRouterJSON.extract(message.reasoning)
                    else {
                        if useSchema {
                            self.schemaUnsupported.insert(candidate)
                            useSchema = false
                            continue
                        }
                        throw ChatGPTError.malformed("\(schemaName): model didn't return JSON")
                    }
                    return Data(json.utf8)
                } catch ChatGPTError.http(let status, let text) where useSchema && [400, 404, 422].contains(status) {
                    orLog.info("\(candidate, privacy: .public) rejected json_schema (\(status)); retrying with prompt-guided JSON")
                    _ = text
                    self.schemaUnsupported.insert(candidate)
                    useSchema = false
                }
            }
        }
    }

    public func text(instructions: String, prompt: String, model: String) async throws -> String {
        try await attemptChain(model) { candidate in
            let body = self.lightBody(model: candidate, system: instructions, prompt: prompt)
            let message = try await self.send(body)
            let text = message.content.isEmpty ? message.reasoning : message.content
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ChatGPTError.malformed("empty text")
            }
            return text
        }
    }

    /// Light tasks ask for low reasoning effort. Image calls do not; some image routers reject the field.
    private func lightBody(model: String, system: String, prompt: String) -> [String: JSON] {
        [
            "model": .string(model),
            "messages": [["role": "system", "content": .string(system)], ["role": "user", "content": .string(prompt)]],
            "reasoning": ["effort": .string("low")],
        ]
    }

    /// Free models walk `OpenRouterFreeChain` after a 429 or a timeout. A paid starting model stays put
    /// so the caller's existing dead-model fallback to `openrouter/free` still runs.
    private func attemptChain<T>(_ model: String, _ operation: (String) async throws -> T) async throws -> T {
        let models = OpenRouterFreeChain.order(starting: model, catalogFree: catalogFree, paid: paidFallback)
        let freeStart = OpenRouterCatalog.isFreeModel(model)
        var last = ChatGPTError.exhausted("OpenRouter produced no response.")
        for (index, candidate) in models.enumerated() {
            do {
                return try await operation(candidate)
            } catch let error as ChatGPTError where freeStart && Self.advancesFreeChain(error) {
                last = error
                if index < models.count - 1 { continue }
                throw ChatGPTError.exhausted(error.localizedDescription ?? "OpenRouter free models are unavailable.")
            }
        }
        throw last
    }

    static func advancesFreeChain(_ error: ChatGPTError) -> Bool {
        switch error {
        case .rateLimited, .exhausted: true
        case .http(let code, _) where code == 408: true
        default: false
        }
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
        request.timeoutInterval = OpenRouterFreeChain.requestTimeout
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
        let model = body["model"]?.stringValue ?? ""
        var attempt = 0
        while true {
            await pace(model: model)
            var request = URLRequest(url: Self.endpoint)
            request.timeoutInterval = OpenRouterFreeChain.requestTimeout
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(JSON.object(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            authorize(&request)
            let response: (Data, HTTPURLResponse)
            do {
                response = try await transport(request)
            } catch let error as URLError where error.code == .timedOut {
                attempt += 1
                if attempt >= OpenRouterFreeChain.maxAttemptsPerModel {
                    let message = "OpenRouter timed out after \(Int(OpenRouterFreeChain.requestTimeout))s."
                    report(.failed, message)
                    throw ChatGPTError.exhausted(message)
                }
                let delay = OpenRouterFreeChain.delay(status: 408, retryAfter: nil, attempt: attempt)
                report(.waiting, "OpenRouter timed out. Retrying in \(Int(delay.rounded()))s.")
                await clock.sleep(seconds: delay)
                continue
            } catch let error as URLError where OpenRouterClient.isTransient(error) {
                throw ChatGPTError.failed("Lost the connection to OpenRouter (\(error.localizedDescription)). Retrying…")
            }
            let (data, http) = response
            if http.statusCode == 200 {
                let message = try parse(data)
                report(.idle, "")
                return message
            }
            if http.statusCode == 429 || http.statusCode >= 500 || http.statusCode == 408 {
                attempt += 1
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let message = Self.error(status: http.statusCode, data: data).localizedDescription
                if attempt >= OpenRouterFreeChain.maxAttemptsPerModel {
                    report(.failed, message)
                    if http.statusCode == 429 {
                        throw ChatGPTError.rateLimited(retryAfter: retryAfter, message: message)
                    }
                    throw Self.error(status: http.statusCode, data: data)
                }
                let delay = OpenRouterFreeChain.delay(status: http.statusCode, retryAfter: retryAfter, attempt: attempt)
                let capped = retryAfter.map { $0 > OpenRouterFreeChain.retryAfterCap } ?? false
                let detail = capped
                    ? "\(message) Retry-After was capped at \(Int(OpenRouterFreeChain.retryAfterCap))s."
                    : "\(message) Retrying in \(Int(delay.rounded()))s."
                report(.waiting, detail)
                await clock.sleep(seconds: delay)
                continue
            }
            throw Self.error(status: http.statusCode, data: data)
        }
    }

    /// Reserves the next free slot before awaiting, so overlapping batches share one pace.
    private func pace(model: String) async {
        guard OpenRouterCatalog.isFreeModel(model) else { return }
        let now = clock.now()
        let start = nextFreeAt.map { max($0, now) } ?? now
        let delay = start.timeIntervalSince(now)
        nextFreeAt = start.addingTimeInterval(OpenRouterFreeChain.gap)
        guard delay > 0 else { return }
        report(.waiting, "Free models are paced. Waiting \(String(format: "%.1f", delay))s.")
        await clock.sleep(seconds: delay)
    }

    private func report(_ phase: LibraryWorkStatus.Phase, _ detail: String) {
        activityHandler?(LibraryWorkStatus(phase: phase, step: "OpenRouter", completed: 0, total: 0, detail: detail))
    }

    private func parse(_ data: Data) throws -> Message {
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
        var reasoning = message["reasoning"] as? String ?? ""
        if reasoning.isEmpty, let alternate = message["reasoning_content"] as? String { reasoning = alternate }
        let images = (message["images"] as? [[String: Any]] ?? []).compactMap {
            ($0["image_url"] as? [String: Any])?["url"] as? String
        }
        if content.isEmpty, reasoning.isEmpty, images.isEmpty {
            throw ChatGPTError.malformed("OpenRouter returned an empty response.")
        }
        return Message(content: content, reasoning: reasoning, imageURLs: images)
    }

    static func error(status: Int, data: Data) -> ChatGPTError {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (root?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(240), as: UTF8.self)
        if status == 401 { return .http(401, "OpenRouter rejected the API key. Check it in Settings › Account.") }
        if status == 402 { return .http(402, "OpenRouter: out of credits. Pick a free model or add credits.") }
        if status == 403 { return .http(403, "OpenRouter: \(message) (check your key's limit at openrouter.ai/settings/keys)") }
        return .http(status, "OpenRouter: \(message)")
    }
}
