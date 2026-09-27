import XCTest
@testable import AriaKit

final class OpenRouterClientTests: XCTestCase {
    func testSendsModelMessagesAndToolsAndParsesToolCalls() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.url.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.header("Authorization"), "Bearer sk-or-test")
            XCTAssertEqual(request.header("X-Title"), "Aria")
            let body = bodyJSON(request)
            XCTAssertEqual(body?["model"], "anthropic/claude-sonnet-4.5")
            XCTAssertEqual(body?["tool_choice"], "auto")
            XCTAssertEqual(body?["tools"]?.arrayValue?.count, AriaTools.definitions.count)
            XCTAssertEqual(body?["messages"]?.arrayValue?.last?["content"], "Add milk")
            return json(200, """
            {"id":"gen-1","model":"anthropic/claude-sonnet-4.5","choices":[{"index":0,"finish_reason":"tool_calls",
              "message":{"role":"assistant","content":"","tool_calls":[
                {"id":"call_a","type":"function","function":{"name":"create_task","arguments":"{\\"title\\":\\"Milk\\"}"}},
                {"type":"function","function":{"name":"list_tasks_for_range","arguments":{"start":"2026-09-27"}}}]}}]}
            """)
        }
        let client = OpenRouterClient(apiKey: { "sk-or-test" }, transport: transport)
        let completion = try await client.complete(model: "anthropic/claude-sonnet-4.5", messages: [.user("Add milk")],
                                                   tools: AriaTools.definitions)
        XCTAssertEqual(completion.finishReason, "tool_calls")
        let calls = try XCTUnwrap(completion.message.toolCalls)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].id, "call_a")
        XCTAssertEqual(calls[0].function.arguments, #"{"title":"Milk"}"#)
        XCTAssertFalse(calls[1].id.isEmpty, "missing ids are filled in")
        XCTAssertEqual(try JSONValue.parse(calls[1].function.arguments), ["start": "2026-09-27"])
    }

    func testContentPartsAreFlattened() async throws {
        let transport = MockTransport { _ in
            json(200, #"{"choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"Hello "},{"type":"text","text":"there"}]}}]}"#)
        }
        let client = OpenRouterClient(apiKey: { "k" }, transport: transport)
        let completion = try await client.complete(model: "m", messages: [.user("hi")], tools: nil)
        XCTAssertEqual(completion.message.content, "Hello there")
        XCTAssertNil(bodyJSON(transport.requests[0])?["tools"], "no tools → no tool_choice either")
        XCTAssertNil(bodyJSON(transport.requests[0])?["tool_choice"])
    }

    func testErrorsAreMapped() async {
        let cases: [(HTTPResponse, AriaError)] = [
            (json(401, #"{"error":{"message":"No auth credentials found","code":401}}"#), .openRouter(status: 401, message: "No auth credentials found")),
            (json(200, #"{"error":{"message":"Provider returned error","code":502}}"#), .openRouter(status: 502, message: "Provider returned error")),
            (json(200, #"{"choices":[]}"#), .openRouter(status: 502, message: "The model returned no answer.")),
        ]
        for (response, expected) in cases {
            let client = OpenRouterClient(apiKey: { "k" }, transport: MockTransport { _ in response })
            do {
                _ = try await client.complete(model: "m", messages: [.user("hi")], tools: nil)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AriaError, expected)
            }
        }
    }

    func testMissingKeyFailsWithoutARequest() async {
        let transport = MockTransport { _ in XCTFail("no request expected"); return json(500, "{}") }
        let client = OpenRouterClient(apiKey: { "  " }, transport: transport)
        do {
            _ = try await client.complete(model: "m", messages: [.user("hi")], tools: nil)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AriaError, .missingAPIKey)
        }
    }

    func testListModelsAndCatalogMerge() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.url.absoluteString, "https://openrouter.ai/api/v1/models")
            return json(200, """
            {"data":[{"id":"openai/gpt-4o","name":"OpenAI: GPT-4o","supported_parameters":["tools","temperature"]},
                     {"id":"x/no-tools","name":"No Tools","supported_parameters":["temperature"]},
                     {"id":"z/new-model","name":"Zed New","supported_parameters":["tools"]},
                     {"id":"a/another","name":"Another","supported_parameters":["tool_choice","tools"]}]}
            """)
        }
        let models = try await OpenRouterClient(apiKey: { nil }, transport: transport).listModels()
        XCTAssertEqual(models.count, 4)
        XCTAssertNil(transport.requests[0].header("Authorization"))
        let merged = ModelCatalog.merged(withLive: models)
        XCTAssertEqual(Array(merged.prefix(ModelCatalog.curated.count)), ModelCatalog.curated)
        XCTAssertEqual(merged.dropFirst(ModelCatalog.curated.count).map(\.id), ["a/another", "z/new-model"])
    }

    func testAssistantToolCallTurnEncodesNullContent() throws {
        let message = ChatMessage.assistant(nil, toolCalls: [toolCall("c1", "create_task", "{}")])
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(encoded["content"], .null)
        XCTAssertEqual(encoded["tool_calls"]?.arrayValue?.first?["function"]?["name"], "create_task")
        let tool = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ChatMessage.tool(callId: "c1", name: "create_task", content: "{}")))
        XCTAssertEqual(tool["tool_call_id"], "c1")
        XCTAssertEqual(tool["role"], "tool")
    }
}
