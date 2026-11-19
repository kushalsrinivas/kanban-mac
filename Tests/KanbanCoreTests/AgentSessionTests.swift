import Foundation
import XCTest

/// Direct tests of the session states the console relies on: incremental text,
/// cancellation keeping the partial answer, retry rerunning the same prompt, and a
/// timeout becoming a visible failure instead of a spinner.
@MainActor
final class AgentSessionTests: XCTestCase {

    private var store: LocalStore!
    private var settings: AppSettings!
    private var client: APIClient!
    private var sync: SyncEngine!

    private let fallbackPrompt = "quantum chromodynamics"

    override func setUp() {
        super.setUp()
        // Keep AppSettings out of the real preferences suite.
        setenv("KANBAN_DEFAULTS_SUITE", "com.kanban.tests.agent.\(UUID().uuidString)", 1)
        store = LocalStore(ephemeral: true)
        settings = AppSettings.testing()
        client = APIClient()
        sync = SyncEngine(store: store, client: client)
    }

    private func session(_ model: AgentModelProvider,
                         timeout: TimeInterval = 5) -> AgentSession {
        AgentSession(store: store, client: client, settings: settings, sync: sync,
                     model: model, requestTimeout: timeout)
    }

    private func waitUntil(timeout: TimeInterval = 4,
                           _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    // MARK: Streaming

    func testStreamedTextAppearsBeforeTheTurnFinishes() async {
        let model = ScriptedModel([[
            .text("First "),
            .wait(150_000_000),
            .text("second")
        ]])
        let agent = session(model)

        agent.send(fallbackPrompt)
        await waitUntil {
            agent.messages.contains { $0.isStreaming && $0.text == "First " }
        }
        XCTAssertTrue(agent.isBusy)

        await waitUntil { !agent.isBusy }
        XCTAssertEqual(agent.messages.last?.text, "First second")
        XCTAssertFalse(agent.messages.last?.isStreaming ?? true)
        XCTAssertFalse(agent.messages.last?.wasCancelled ?? true)
    }

    // MARK: Retry

    func testFailureExposesRetryAndRerunsTheSamePrompt() async {
        let model = ScriptedModel([
            [.fail(URLError(.cannotConnectToHost))],
            [.text("Recovered")]
        ])
        let agent = session(model)

        agent.send(fallbackPrompt)
        await waitUntil { agent.canRetry && !agent.isBusy }
        XCTAssertTrue(agent.messages.contains { $0.kind == .failure })

        agent.retry()
        await waitUntil {
            !agent.isBusy && agent.messages.contains { $0.text == "Recovered" }
        }
        XCTAssertEqual(model.calls, 2)
        XCTAssertFalse(agent.canRetry)
    }

    // MARK: Cancellation

    func testCancelKeepsPartialTextAndStopsUpdates() async {
        let model = ScriptedModel([[
            .text("Partial "),
            .wait(5_000_000_000),
            .text("never")
        ]])
        let agent = session(model)

        agent.send(fallbackPrompt)
        await waitUntil { agent.messages.last?.text == "Partial " && agent.isBusy }

        agent.cancel()
        XCTAssertFalse(agent.isBusy)
        XCTAssertEqual(agent.messages.last?.text, "Partial ")
        XCTAssertTrue(agent.messages.last?.wasCancelled ?? false)

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(agent.messages.last?.text, "Partial ",
                       "no fragment may be appended after cancellation")
        XCTAssertFalse(agent.messages.last?.text.contains("never") ?? true)
    }

    // MARK: Scheduling

    func testScheduleRequiresConfirmationThenPersistsLocally() async {
        let model = ScriptedModel([[]])
        let agent = session(model)

        agent.send("schedule a meeting about onboarding with Sarah tomorrow at 2pm for 45 minutes")
        await waitUntil { !agent.isBusy && agent.pending.count == 1 }

        XCTAssertTrue(store.scheduledMeetings.isEmpty, "nothing may be written before EXECUTE")
        let action = agent.pending[0]
        XCTAssertEqual(action.tool, "schedule_meeting")
        XCTAssertTrue(action.summary.contains("ONBOARDING") || action.summary.contains("Onboarding"))

        await agent.execute(action)
        await waitUntil { !agent.isBusy }
        XCTAssertEqual(store.scheduledMeetings.count, 1)
        XCTAssertEqual(store.scheduledMeetings.first?.title, "Onboarding")
        XCTAssertEqual(store.scheduledMeetings.first?.participants, ["Sarah"])
        XCTAssertTrue(agent.messages.contains {
            $0.artifacts.contains { $0.kind == .scheduledMeeting }
        })
    }

    // MARK: Timeout

    func testTimeoutSurfacesAFailureAndAllowsRetry() async {
        let model = ScriptedModel([[.wait(5_000_000_000)]])
        let agent = session(model, timeout: 0.15)

        agent.send(fallbackPrompt)
        await waitUntil { agent.canRetry && !agent.isBusy }
        XCTAssertTrue(agent.messages.contains {
            $0.kind == .failure && $0.text.contains("took too long")
        })
    }
}

// MARK: - Scripted model

@MainActor
private final class ScriptedModel: AgentModelProvider {
    enum Step {
        case text(String)
        case fail(Error)
        case wait(UInt64)
    }

    private let scripts: [[Step]]
    private(set) var calls = 0

    init(_ scripts: [[Step]]) {
        self.scripts = scripts
    }

    func reply(prompt: String,
               history: [(role: String, content: String)],
               boardContext: String,
               meetingContext: String,
               onText: @Sendable @escaping (String) async -> Void) async throws -> LocalAgentReply {
        let index = min(calls, max(0, scripts.count - 1))
        calls += 1
        var output = ""
        for step in scripts[index] {
            switch step {
            case .text(let text):
                output += text
                await onText(output)
            case .fail(let error):
                throw error
            case .wait(let nanoseconds):
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        }
        return LocalAgentReply(reply: output.isEmpty ? "Done" : output, actions: [])
    }
}
