import Foundation

/// One message in an OpenAI-compatible chat completion (the format OpenRouter speaks).
public struct ChatMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Hashable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?
    public var name: String?

    public init(role: Role, content: String?, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }
    public static func assistant(_ text: String?, toolCalls: [ToolCall]? = nil) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, toolCalls: toolCalls)
    }
    public static func tool(callId: String, name: String, content: String) -> ChatMessage {
        ChatMessage(role: .tool, content: content, toolCallId: callId, name: name)
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? container.decode(Role.self, forKey: .role)) ?? .assistant
        // Most providers return a string; some return an array of content parts.
        if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
            content = text
        } else if let parts = try? container.decodeIfPresent([JSONValue].self, forKey: .content) {
            let texts = parts.compactMap { $0["text"]?.stringValue }
            content = texts.isEmpty ? nil : texts.joined()
        } else {
            content = nil
        }
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content) // explicit null for tool-calling assistant turns
        if let toolCalls, !toolCalls.isEmpty { try container.encode(toolCalls, forKey: .toolCalls) }
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

public struct ToolCall: Codable, Hashable, Sendable {
    public struct Function: Codable, Hashable, Sendable {
        public var name: String
        /// JSON-encoded arguments, exactly as the model produced them.
        public var arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }

        enum CodingKeys: String, CodingKey { case name, arguments }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            if let text = try? container.decode(String.self, forKey: .arguments) {
                arguments = text
            } else if let object = try? container.decode(JSONValue.self, forKey: .arguments) {
                arguments = object.jsonString() // a few providers send an object instead of a string
            } else {
                arguments = "{}"
            }
        }
    }

    public var id: String
    public var type: String
    public var function: Function

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.type = "function"
        self.function = Function(name: name, arguments: arguments)
    }

    enum CodingKeys: String, CodingKey { case id, type, function }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? "function"
        function = try container.decode(Function.self, forKey: .function)
    }
}

/// A model listed by OpenRouter's `/models` endpoint.
public struct OpenRouterModel: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var supportedParameters: [String]?

    public init(id: String, name: String, supportedParameters: [String]? = nil) {
        self.id = id
        self.name = name
        self.supportedParameters = supportedParameters
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case supportedParameters = "supported_parameters"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? id
        supportedParameters = try? container.decodeIfPresent([String].self, forKey: .supportedParameters)
    }

    /// Aria needs function calling; models that don't advertise it can't drive the planner.
    public var supportsTools: Bool { supportedParameters?.contains("tools") ?? false }
}

/// Anything that can run a chat completion (OpenRouter in the app, a fake in tests).
public protocol ChatCompleting: Sendable {
    func complete(model: String, messages: [ChatMessage], tools: [JSONValue]?, toolChoice: String?) async throws -> ChatCompletion
}

public struct ChatCompletion: Hashable, Sendable {
    public var message: ChatMessage
    public var finishReason: String?
    public var model: String?

    public init(message: ChatMessage, finishReason: String? = nil, model: String? = nil) {
        self.message = message
        self.finishReason = finishReason
        self.model = model
    }
}

/// Minimal OpenRouter client: chat completions with tool calling, and the model list.
/// The API key is read from the Keychain for every request and never persisted elsewhere.
public final class OpenRouterClient: ChatCompleting, @unchecked Sendable {
    public static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!

    private let apiKey: @Sendable () -> String?
    private let transport: HTTPTransport
    private let baseURL: URL

    public init(apiKey: @escaping @Sendable () -> String?, transport: HTTPTransport = URLSessionTransport(),
                baseURL: URL = OpenRouterClient.defaultBaseURL) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    private struct CompletionRequest: Encodable {
        var model: String
        var messages: [ChatMessage]
        var tools: [JSONValue]?
        var toolChoice: String?

        enum CodingKeys: String, CodingKey {
            case model, messages, tools
            case toolChoice = "tool_choice"
        }
    }

    private struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            var message: ChatMessage?
            var finishReason: String?
            var error: JSONValue?

            enum CodingKeys: String, CodingKey {
                case message, error
                case finishReason = "finish_reason"
            }
        }

        var choices: [Choice]?
        var model: String?
        var error: JSONValue?
    }

    public func complete(model: String, messages: [ChatMessage], tools: [JSONValue]?,
                         toolChoice: String? = "auto") async throws -> ChatCompletion {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw AriaError.missingAPIKey
        }
        let payload = CompletionRequest(model: model, messages: messages, tools: (tools?.isEmpty ?? true) ? nil : tools,
                                        toolChoice: (tools?.isEmpty ?? true) ? nil : toolChoice)
        let request = HTTPRequest(method: "POST", url: baseURL.appendingPathComponent("chat/completions"),
                                  headers: headers(key: key), body: try JSONEncoder().encode(payload), timeout: 120)
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw AriaError.openRouter(status: response.status,
                                       message: AriaError.message(from: response.body, fallbackStatus: response.status).message)
        }
        let decoded: CompletionResponse
        do {
            decoded = try JSONDecoder().decode(CompletionResponse.self, from: response.body)
        } catch {
            throw AriaError.decoding("chat completion: \(error)")
        }
        if let error = decoded.error ?? decoded.choices?.first?.error {
            let message = error["message"]?.stringValue ?? error.stringValue ?? "Unknown error"
            let status = error["code"]?.doubleValue.map { Int($0) } ?? 500
            throw AriaError.openRouter(status: status, message: message)
        }
        guard let choice = decoded.choices?.first, var message = choice.message else {
            throw AriaError.openRouter(status: 502, message: "The model returned no answer.")
        }
        message.role = .assistant
        // Tool results are matched by id, so make sure every call has one.
        if let calls = message.toolCalls {
            message.toolCalls = calls.enumerated().map { index, call in
                var fixed = call
                if fixed.id.isEmpty { fixed.id = "call_\(index + 1)_\(UUID().uuidString.prefix(8))" }
                return fixed
            }
        }
        return ChatCompletion(message: message, finishReason: choice.finishReason, model: decoded.model)
    }

    /// Models currently offered by OpenRouter (public endpoint; no key required).
    public func listModels() async throws -> [OpenRouterModel] {
        struct ModelList: Decodable { var data: [OpenRouterModel] }
        var headers = ["Accept": "application/json"]
        if let key = apiKey(), !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        let response = try await transport.send(HTTPRequest(method: "GET", url: baseURL.appendingPathComponent("models"),
                                                            headers: headers))
        guard response.isSuccess else {
            throw AriaError.openRouter(status: response.status,
                                       message: AriaError.message(from: response.body, fallbackStatus: response.status).message)
        }
        do {
            return try JSONDecoder().decode(ModelList.self, from: response.body).data
        } catch {
            throw AriaError.decoding("model list: \(error)")
        }
    }

    private func headers(key: String) -> [String: String] {
        [
            "Authorization": "Bearer \(key)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            // Optional OpenRouter app attribution headers.
            "HTTP-Referer": "https://github.com/kreisler0/Aria",
            "X-Title": "Aria",
        ]
    }
}

/// The models offered in Settings before the live list has loaded. Any other OpenRouter
/// model id can be typed in by hand.
public enum ModelCatalog {
    public static let defaultModel = "anthropic/claude-sonnet-4.5"

    public static let curated: [OpenRouterModel] = [
        OpenRouterModel(id: "anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5"),
        OpenRouterModel(id: "anthropic/claude-haiku-4.5", name: "Claude Haiku 4.5"),
        OpenRouterModel(id: "openai/gpt-4o", name: "GPT-4o"),
        OpenRouterModel(id: "openai/gpt-4o-mini", name: "GPT-4o mini"),
        OpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        OpenRouterModel(id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash"),
        OpenRouterModel(id: "meta-llama/llama-3.3-70b-instruct", name: "Llama 3.3 70B Instruct"),
        OpenRouterModel(id: "mistralai/mistral-large", name: "Mistral Large"),
    ]

    /// Curated models first, then every other tool-capable model from the live list.
    public static func merged(withLive live: [OpenRouterModel]) -> [OpenRouterModel] {
        let curatedIds = Set(curated.map(\.id))
        let extra = live.filter { $0.supportsTools && !curatedIds.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return curated + extra
    }
}
