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
        try await GeminiClient(apiKey: settings.geminiAPIKey, model: settings.geminiModel)
            .agentTurnStreaming(
                message: prompt,
                history: history,
                boardContext: boardContext,
                meetingContext: meetingContext,
                onText: onText)
    }
}
