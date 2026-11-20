import Foundation

/// The model seam for open-ended turns. The deterministic planner answers most
/// questions without it; this is only consulted after a fallback.
@MainActor
protocol AgentModelProvider: Sendable {
    func reply(prompt: String,
               history: [(role: String, content: String)],
               boardContext: String,
               meetingContext: String,
               onText: @Sendable @escaping (String) async -> Void) async throws -> LocalAgentReply
}

/// Production implementation: reads the current key/model from settings on each
/// turn, so changing Settings does not require rebuilding the session.
@MainActor
struct GeminiModelProvider: AgentModelProvider {
    let settings: AppSettings

    func reply(prompt: String,
               history: [(role: String, content: String)],
               boardContext: String,
               meetingContext: String,
               onText: @Sendable @escaping (String) async -> Void) async throws -> LocalAgentReply {
        let client = GeminiClient(apiKey: settings.geminiAPIKey, model: settings.geminiModel)
        // The buffered endpoint is the reliable path for tool actions. The SSE
        // stream can stay open without finishing, which used to consume the whole
        // agent timeout before any write could be applied. Emit the final text once
        // so the placeholder still ends with the model's reply.
        let reply = try await client.agentTurn(
            message: prompt, history: history,
            boardContext: boardContext, meetingContext: meetingContext)
        if !reply.reply.isEmpty { await onText(reply.reply) }
        return reply
    }
}
