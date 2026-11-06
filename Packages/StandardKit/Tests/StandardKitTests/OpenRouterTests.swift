import Foundation
import ImageIO
import Testing
@testable import StandardKit

/// Records requests and replays canned responses so no test ever touches the network or spends credits.
final class MockTransport: @unchecked Sendable {
    var responses: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func bodies() -> [[String: Any]] {
        requests.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }
    var transport: OpenRouterClient.Transport {
        { [self] request in
            requests.append(request)
            let (status, body) = responses.isEmpty ? (500, "{}") : responses.removeFirst()
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
            return (Data(body.utf8), http)
        }
    }
}

func chat(_ content: String) -> String {
    let escaped = String(data: try! JSONSerialization.data(withJSONObject: [content], options: [.fragmentsAllowed]), encoding: .utf8)!
    return #"{"choices":[{"message":{"role":"assistant","content":"# + String(escaped.dropFirst().dropLast()) + "}}]}"
}

struct Pet: Decodable, Equatable, Sendable { var name: String; var age: Int }
let petSchema: JSON = Schema.object(["name": ["type": "string"], "age": ["type": "integer"]])

@Suite struct OpenRouterCatalogTests {
    static let sample = """
    {"data":[
     {"id":"openrouter/free","name":"Free Models Router","context_length":200000,
      "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
      "pricing":{"prompt":"0","completion":"0"},"supported_parameters":["response_format","structured_outputs"]},
     {"id":"google/gemini-2.5-flash-image","name":"Google: Nano Banana","context_length":32768,
      "architecture":{"input_modalities":["text","image"],"output_modalities":["image","text"]},
      "pricing":{"prompt":"0.0000003","completion":"0.0000025"},"supported_parameters":["max_tokens"]},
     {"id":"meta-llama/llama-3.3-70b-instruct:free","name":"Meta: Llama 3.3 70B (free)","context_length":65536,
      "architecture":{"output_modalities":["text"]},"pricing":{"prompt":"0","completion":"0"}},
     {"id":"anthropic/claude-sonnet-4","name":"Anthropic: Claude Sonnet 4","context_length":200000,
      "pricing":{"prompt":"0.000003","completion":"0.000015"},"supported_parameters":["tools"]},
     {"id":"openrouter/auto","name":"Auto Router","pricing":{"prompt":"-1","completion":"-1"}}
    ]}
    """

    @Test func parsesModels() throws {
        let models = try OpenRouterCatalog.parse(Data(Self.sample.utf8))
        #expect(models.count == 5)
        let free = models.first { $0.id == "openrouter/free" }!
        #expect(free.isFree && free.supportsStructuredOutputs && !free.outputsImages)
        #expect(free.contextLength == 200000)
        let img = models.first { $0.id == "google/gemini-2.5-flash-image" }!
        #expect(img.outputsImages && !img.isFree && !img.supportsStructuredOutputs)
        #expect(models.first { $0.id == "meta-llama/llama-3.3-70b-instruct:free" }!.isFree)
        #expect(!models.first { $0.id == "openrouter/auto" }!.isFree)  // variable pricing is not free
    }

    @Test func filtersAndSorts() throws {
        let models = try OpenRouterCatalog.parse(Data(Self.sample.utf8))
        #expect(OpenRouterCatalog.filter(models, search: "", freeOnly: true).map(\.id).allSatisfy { $0.contains("free") })
        #expect(OpenRouterCatalog.filter(models, search: "claude", freeOnly: false).map(\.id) == ["anthropic/claude-sonnet-4"])
        #expect(OpenRouterCatalog.filter(models, search: "banana", freeOnly: false, imageOnly: true).count == 1)
        #expect(OpenRouterCatalog.filter(models, search: "", freeOnly: false, imageOnly: true).map(\.id) == ["google/gemini-2.5-flash-image"])
        // Free first.
        #expect(OpenRouterCatalog.filter(models, search: "", freeOnly: false).first?.isFree == true)
    }

    @Test func acceptsAnyModelSlug() {
        for slug in ["openrouter/auto", "x/y:free", "perplexity/sonar:online", "my-org/brand-new-model-2027", " a/b \n"] {
            #expect(OpenRouterCatalog.normalizedModelID(slug) != nil)
        }
        #expect(OpenRouterCatalog.normalizedModelID("a/b ") == "a/b")
        #expect(OpenRouterCatalog.normalizedModelID("") == nil)
        #expect(OpenRouterCatalog.normalizedModelID("has space/x") == nil)
    }
}

@Suite struct OpenRouterJSONTests {
    @Test func extractsPlain() { #expect(OpenRouterJSON.extract(#"{"a":1}"#) == #"{"a":1}"#) }
    @Test func extractsFenced() {
        #expect(OpenRouterJSON.extract("Here you go:\n```json\n{\"a\": {\"b\": \"}\"}}\n```\nEnjoy") == "{\"a\": {\"b\": \"}\"}}")
    }
    @Test func stripsThinking() {
        #expect(OpenRouterJSON.extract("<think>maybe {\"x\":0} hmm</think>\n{\"a\":2}") == #"{"a":2}"#)
    }
    @Test func extractsArray() { #expect(OpenRouterJSON.extract("result: [1,2,3] done") == "[1,2,3]") }
    @Test func nothing() { #expect(OpenRouterJSON.extract("no json here") == nil) }
}

@Suite struct OpenRouterClientTests {
    @Test func sendsHeadersAndSchema() async throws {
        let mock = MockTransport([(200, chat(#"{"name":"Rex","age":3}"#))])
        let client = OpenRouterClient(apiKey: "sk-test", transport: mock.transport)
        let data = try await client.json(schemaName: "pet", schema: petSchema, instructions: "i", prompt: "p", model: "openrouter/free")
        #expect(try JSONDecoder().decode(Pet.self, from: data) == Pet(name: "Rex", age: 3))
        let req = mock.requests[0]
        #expect(req.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(req.value(forHTTPHeaderField: "X-Title") == "Standard Music")
        #expect(req.value(forHTTPHeaderField: "HTTP-Referer") != nil)
        let body = mock.bodies()[0]
        #expect(body["model"] as? String == "openrouter/free")
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func fallsBackWhenSchemaRejected() async throws {
        for status in [400, 404] {
            let mock = MockTransport([
                (status, #"{"error":{"message":"No endpoints found that can handle the requested parameters.","code":\#(status)}}"#),
                (200, chat("<think>ok</think>```json\n{\"name\":\"Ada\",\"age\":7}\n```")),
            ])
            let client = OpenRouterClient(apiKey: "k", transport: mock.transport)
            let data = try await client.json(schemaName: "pet", schema: petSchema, instructions: "i", prompt: "p", model: "deepseek/deepseek-r1:free")
            #expect(try JSONDecoder().decode(Pet.self, from: data) == Pet(name: "Ada", age: 7))
            let bodies = mock.bodies()
            #expect(bodies.count == 2)
            #expect(bodies[1]["response_format"] == nil)
            let system = ((bodies[1]["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
            #expect(system.contains("\"age\""))  // schema embedded in prompt
            // The model is remembered as not supporting schemas.
            _ = try? await client.json(schemaName: "pet", schema: petSchema, instructions: "i", prompt: "p", model: "deepseek/deepseek-r1:free")
            #expect(mock.bodies().last?["response_format"] == nil)
        }
    }

    @Test func skipsSchemaWhenCatalogSaysUnsupported() async throws {
        let mock = MockTransport([(200, chat(#"{"name":"Z","age":1}"#))])
        let client = OpenRouterClient(apiKey: "k", transport: mock.transport)
        await client.noteCatalog(try OpenRouterCatalog.parse(Data(OpenRouterCatalogTests.sample.utf8)))
        _ = try await client.json(schemaName: "pet", schema: petSchema, instructions: "i", prompt: "p", model: "anthropic/claude-sonnet-4")
        #expect(mock.bodies()[0]["response_format"] == nil)
    }

    @Test func rateLimitMapsToRetryable() async {
        let mock = MockTransport([(429, #"{"error":{"message":"Rate limit exceeded: free-models-per-min","code":429}}"#)])
        let client = OpenRouterClient(apiKey: "k", transport: mock.transport)
        await #expect {
            _ = try await client.json(schemaName: "p", schema: petSchema, instructions: "", prompt: "", model: "x/y:free")
        } throws: { error in
            if case ChatGPTError.rateLimited = error { return true }
            return false
        }
    }

    @Test func errorPayloadInside200() async {
        let mock = MockTransport([(200, #"{"error":{"message":"Provider returned error","code":502}}"#)])
        let client = OpenRouterClient(apiKey: "k", transport: mock.transport)
        await #expect(throws: ChatGPTError.self) {
            _ = try await client.text(instructions: "", prompt: "", model: "a/b")
        }
    }

    @Test func emptyContentUsesReasoning() async throws {
        let mock = MockTransport([(200, #"{"choices":[{"message":{"content":null,"reasoning":"I think: {\"name\":\"R\",\"age\":2}"}}]}"#)])
        let client = OpenRouterClient(apiKey: "k", transport: mock.transport)
        await client.markSchemaUnsupported("a/b")
        let data = try await client.json(schemaName: "pet", schema: petSchema, instructions: "", prompt: "", model: "a/b")
        #expect(try JSONDecoder().decode(Pet.self, from: data).name == "R")
    }

    @Test func parsesImageDataURI() async throws {
        let png = ProceduralArtwork.jpeg(prompt: "seed", size: "64x64")!
        let uri = "data:image/jpeg;base64," + png.base64EncodedString()
        let body = #"{"choices":[{"message":{"content":"","images":[{"type":"image_url","image_url":{"url":"\#(uri)"}}]}}]}"#
        let mock = MockTransport([(200, body)])
        let client = OpenRouterClient(apiKey: "k", transport: mock.transport)
        let data = try await client.image(prompt: "cover", model: "google/gemini-2.5-flash-image")
        #expect(data == png)
        #expect((mock.bodies()[0]["modalities"] as? [String]) == ["image", "text"])
        #expect(OpenRouterClient.decodeDataURI("data:image/png;base64,AAAA") == Data([0, 0, 0]))
    }
}

@Suite struct ProviderTests {
    @Test func proceduralArtworkIsDeterministicAndSized() throws {
        let a = ProceduralArtwork.jpeg(prompt: "Album cover for 'Neon Rain' by Velvet Static, shoegaze", size: "1024x1024")!
        let b = ProceduralArtwork.jpeg(prompt: "Album cover for 'Neon Rain' by Velvet Static, shoegaze", size: "1024x1024")!
        let c = ProceduralArtwork.jpeg(prompt: "Portrait of a jazz trio", size: "1024x1024")!
        #expect(a == b && a != c)
        #expect(a.count > 10_000)
        let src = CGImageSourceCreateWithData(a as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        #expect(img.width == 1024 && img.height == 1024)
        #expect(!ArtworkStore.palette(from: a).isEmpty)
    }

    @Test func openRouterReadinessWithoutChatGPT() async throws {
        let auth = ChatGPTAuth(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let client = ChatGPTClient(auth: auth)
        #expect(await client.isReady == false)
        await client.configureOpenRouter(apiKey: "sk-or-test", writing: "openrouter/free", fast: "x/y:free", imageModel: nil)
        #expect(await client.provider == .openRouter)
        #expect(await client.isReady == true)
        await client.configureOpenRouter(apiKey: "", writing: "a/b", fast: "a/b", imageModel: nil)
        #expect(await client.isReady == false)
        await client.useChatGPT()
        #expect(await client.provider == .chatGPT)
    }

    @Test func routesJsonAndImageThroughOpenRouter() async throws {
        let mock = MockTransport([
            (200, chat(#"{"name":"Kit","age":4}"#)),
            (500, #"{"error":{"message":"image provider down"}}"#),
            (500, "{}"), (500, "{}"), (500, "{}"),
        ])
        let auth = ChatGPTAuth(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let client = ChatGPTClient(auth: auth, openRouterTransport: mock.transport)
        await client.configureOpenRouter(apiKey: "k", writing: "w/model", fast: "f/model:free", imageModel: "img/model")
        let pet = try await client.json(Pet.self, schemaName: "pet", schema: petSchema, instructions: "", prompt: "", quality: .fast)
        #expect(pet == Pet(name: "Kit", age: 4))
        #expect(mock.bodies()[0]["model"] as? String == "f/model:free")
        // Image model fails → procedural art, never an error.
        let art = try await client.image(prompt: "cover", retries: 0)
        #expect(art == ProceduralArtwork.jpeg(prompt: "cover", size: "1024x1024"))
        // No image model → no network call at all.
        let before = mock.requests.count
        await client.configureOpenRouter(apiKey: "k", writing: "w", fast: "f", imageModel: nil)
        _ = try await client.image(prompt: "cover")
        #expect(mock.requests.count == before)
    }

    @Test func keyResolutionPrefersStoredThenEnvironment() {
        #expect(OpenRouterKey.resolve(stored: "abc", environment: ["OPENROUTER_API_KEY": "env"]) == "abc")
        #expect(OpenRouterKey.resolve(stored: nil, environment: ["OPENROUTER_API_KEY": " env \n"]) == "env")
        #expect(OpenRouterKey.resolve(stored: "", environment: [:]) == nil)
    }
}

@Suite struct OpenRouterTransientErrorTests {
    @Test func droppedConnectionsAreTransientAndRetryable() {
        #expect(OpenRouterClient.isTransient(URLError(.networkConnectionLost)))
        #expect(OpenRouterClient.isTransient(URLError(.timedOut)))
        #expect(!OpenRouterClient.isTransient(URLError(.cancelled)))
        #expect(ChatGPTError.failed("Lost the connection").isRetryable)
    }
}

@Suite struct OpenRouterFallbackTests {
    @Test func deadModelFallsBackToFreeRouter() async throws {
        // Selected model 404s (schema + prompt-guided), then the free router answers.
        let mock = MockTransport([
            (404, #"{"error":{"message":"No endpoints found"}}"#),
            (404, #"{"error":{"message":"No endpoints found"}}"#),
            (200, chat(#"{"name":"Kit","age":4}"#)),
        ])
        let auth = ChatGPTAuth(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let client = ChatGPTClient(auth: auth, openRouterTransport: mock.transport)
        await client.configureOpenRouter(apiKey: "k", writing: "stealth/dead", fast: "stealth/dead", imageModel: nil)
        let pet = try await client.json(Pet.self, schemaName: "pet", schema: petSchema, instructions: "", prompt: "")
        #expect(pet == Pet(name: "Kit", age: 4))
        #expect(mock.bodies().last?["model"] as? String == OpenRouterCatalog.defaultModel)
    }

    @Test func keyLimitDoesNotFallBackOrLoop() async throws {
        let mock = MockTransport([(403, #"{"error":{"message":"Key limit exceeded"}}"#)])
        let auth = ChatGPTAuth(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let client = ChatGPTClient(auth: auth, openRouterTransport: mock.transport)
        await client.configureOpenRouter(apiKey: "k", writing: "a/b", fast: "a/b", imageModel: nil)
        await #expect(throws: ChatGPTError.self) {
            _ = try await client.json(Pet.self, schemaName: "pet", schema: petSchema, instructions: "", prompt: "")
        }
        #expect(mock.requests.count == 1)
    }
}
