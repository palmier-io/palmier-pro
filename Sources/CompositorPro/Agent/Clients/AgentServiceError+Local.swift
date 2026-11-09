import Foundation

/// Agent-stream transport failures. The hosted Compositor backend client was
/// removed in R1; BYOK routing layers (AgentClientTypes) own direct calls.
enum AgentServiceError: Error {
    case unauthenticated
    case insufficientCredits(String)
    case unavailable(AgentModel)
    case refusal(AgentModel)
    case upstream(String)
    case httpError(status: Int, code: String?, message: String)

    static func from(status: Int, body: String) -> AgentServiceError {
        let parsed = parseErrorEnvelope(body)
        let message = parsed?.message ?? body.prefix(500).description
        switch parsed?.code {
        case "unauthenticated": return .unauthenticated
        case "insufficient_credits": return .insufficientCredits(message)
        default:
            if status == 401 { return .unauthenticated }
            if status == 402 { return .insufficientCredits(message) }
            return .httpError(status: status, code: parsed?.code, message: message.isEmpty ? "HTTP \(status)" : message)
        }
    }

    private static func parseErrorEnvelope(_ body: String) -> (code: String, message: String)? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let code = err["code"] as? String,
              let message = err["message"] as? String
        else { return nil }
        return (code, message)
    }
}

extension AgentServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthenticated: return "Sign-in required."
        case .insufficientCredits(let message): return message
        case .unavailable(let model): return "Model '\(model.rawValue)' is unavailable."
        case .refusal(let model): return "Model '\(model.rawValue)' refused the request."
        case .upstream(let message): return message
        case .httpError(_, _, let message): return message
        }
    }
}
