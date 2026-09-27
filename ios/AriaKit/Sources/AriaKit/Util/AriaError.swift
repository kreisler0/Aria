import Foundation

public enum AriaError: Error, Equatable, LocalizedError, Sendable {
    /// The Supabase URL / anon key have not been provided.
    case notConfigured
    /// No signed-in user, or the session could not be refreshed.
    case notAuthenticated
    /// The request never got an HTTP response.
    case network(String)
    /// Supabase (PostgREST or Auth) answered with an error.
    case server(status: Int, code: String?, message: String)
    /// A response could not be decoded.
    case decoding(String)
    /// Input rejected before any request was made.
    case invalidInput(String)
    /// The OpenRouter API key has not been saved in the Keychain.
    case missingAPIKey
    /// OpenRouter answered with an error.
    case openRouter(status: Int, message: String)
    /// Sign-up succeeded but the project requires email confirmation first.
    case emailConfirmationRequired

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Aria isn't connected to a Supabase project yet."
        case .notAuthenticated:
            return "Your session has expired. Please sign in again."
        case .network(let message):
            return "Couldn't reach the server (\(message))."
        case .server(_, _, let message):
            return message
        case .decoding(let message):
            return "Unexpected response from the server: \(message)"
        case .invalidInput(let message):
            return message
        case .missingAPIKey:
            return "Add your OpenRouter API key in Settings to use the assistant."
        case .openRouter(let status, let message):
            switch status {
            case 401: return "OpenRouter rejected the API key. Check it in Settings. (\(message))"
            case 402: return "Your OpenRouter account is out of credits. (\(message))"
            case 429: return "OpenRouter is rate-limiting requests. Try again in a moment."
            default: return "The AI request failed: \(message)"
            }
        case .emailConfirmationRequired:
            return "Check your inbox to confirm your email, then sign in."
        }
    }

    /// Extracts a readable message from Supabase/GoTrue/PostgREST/OpenRouter error bodies.
    static func message(from body: Data, fallbackStatus status: Int) -> (code: String?, message: String) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, text.isEmpty ? "HTTP \(status)" : String(text.prefix(300)))
        }
        let code = json["error_code"]?.stringValue ?? json["code"]?.stringValue
        let candidates: [JSONValue?] = [
            json["msg"], json["message"], json["error_description"], json["error"]?["message"], json["error"],
        ]
        for candidate in candidates {
            if let text = candidate?.stringValue, !text.isEmpty {
                return (code, text)
            }
        }
        return (code, "HTTP \(status)")
    }
}
