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
        let lower = prompt.lowercased()
        let wantsWrite = ["add ", "create ", "make ", "remind ", "delete ", "remove ",
                          "complete ", "finish ", "rename ", "set ", "move ", "archive ",
                          "tag ", "update "].contains { lower.hasPrefix($0) }
            || lower.contains("todo")
        do {
            let streamed = try await client.agentTurnStreaming(
                message: prompt,
                history: history,
                boardContext: boardContext,
                meetingContext: meetingContext,
                onText: onText)
            if wantsWrite, streamed.actions.isEmpty {
                // Streaming can finish without the write actions; the buffered
                // endpoint is the authority for a mutation.
                return try await client.agentTurn(
                    message: prompt, history: history,
                    boardContext: boardContext, meetingContext: meetingContext)
            }
            return streamed
        } catch let error as LocalAIError {
            // A broken SSE stream must not lose a write request. Retry once without
            // streaming: the JSON contract is the same and actions are what matter.
            guard case .malformed = error else { throw error }
            return try await client.agentTurn(
                message: prompt, history: history,
                boardContext: boardContext, meetingContext: meetingContext)
        }
    }
}
