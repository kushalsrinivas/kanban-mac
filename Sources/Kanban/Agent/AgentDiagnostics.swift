#if DEBUG
import AppKit
import Foundation

/// Debug-only end-to-end probe for the real Gemini path. Enabled with
/// `KANBAN_AGENT_PROMPT`; writes the transcript, pending operations and resulting
/// task titles to `KANBAN_AGENT_RESULT` (default `/tmp/kanban-agent-result.txt`).
///
/// This uses the same `AgentSession.send` the composer uses. It exists because the
/// deterministic planner and the model seam are easy to test separately but the
/// combination is what the user actually sees.
@MainActor
enum AgentDiagnostics {
    static func runIfRequested(_ app: AppModel) {
        guard let prompt = ProcessInfo.processInfo.environment["KANBAN_AGENT_PROMPT"],
              !prompt.isEmpty else { return }
        let path = ProcessInfo.processInfo.environment["KANBAN_AGENT_RESULT"]
            ?? "/tmp/kanban-agent-result.txt"

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            app.section = .agent
            app.agent.send(prompt)

            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline {
                if !app.agent.isBusy { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            var lines: [String] = ["PROMPT: \(prompt)", ""]
            for message in app.agent.messages {
                lines.append("[\(message.kind)] \(message.text)")
                for artifact in message.artifacts {
                    lines.append("  artifact: \(artifact.title)")
                }
            }
            lines.append("")
            lines.append("pending: \(app.agent.pending.count)")
            for action in app.agent.pending {
                lines.append("  pending: \(action.tool) · \(action.summary)")
            }
            lines.append("tasks: \(app.store.tasks.count)")
            for task in app.store.tasks {
                lines.append("  task: \(task.title) · \(task.status.rawValue)")
            }
            try? lines.joined(separator: "\n").write(
                toFile: path, atomically: true, encoding: .utf8)

            if ProcessInfo.processInfo.environment["KANBAN_AUTO_QUIT"] == "1" {
                NSApp.terminate(nil)
            }
        }
    }
}
#endif
