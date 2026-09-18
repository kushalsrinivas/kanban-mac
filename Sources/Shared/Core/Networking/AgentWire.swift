import Foundation

// MARK: - Request

/// What the Mac sends to `POST /api/v1/agent/chat`.
///
/// The Mac does no reasoning: it forwards the message, a short transcript for
/// continuity, and a compact snapshot of the board so the agent can answer simple
/// questions without a round trip to its own database.
public struct AgentRequest: Codable, Sendable {
    public struct Turn: Codable, Sendable {
        public var role: String     // "user" | "assistant"
        public var content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public var message: String
    public var history: [Turn]
    public var context: SummaryDTO
    public var clientVersion: String

    public init(message: String, history: [Turn], context: SummaryDTO, clientVersion: String) {
        self.message = message
        self.history = history
        self.context = context
        self.clientVersion = clientVersion
    }
}

// MARK: - Proposed operations

/// A structured operation the agent wants to perform, as validated and described by
/// the server. The Mac renders it and asks for confirmation; it never interprets the
/// arguments or executes anything itself.
public struct AgentAction: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var tool: String
    /// Server-rendered one-liner: "FIX API AUTHENTICATION · TODO → IN PROGRESS".
    public var summary: String
    public var destructive: Bool
    /// Already applied server-side (a read, or a mutation the server auto-approved).
    public var applied: Bool

    public init(id: String, tool: String, summary: String,
                destructive: Bool = false, applied: Bool = false) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.destructive = destructive
        self.applied = applied
    }

    enum CodingKeys: String, CodingKey {
        case id, tool, name, summary, description, destructive, applied
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        tool = (try? c.decode(String.self, forKey: .tool))
            ?? (try? c.decode(String.self, forKey: .name)) ?? "unknown"
        summary = (try? c.decode(String.self, forKey: .summary))
            ?? (try? c.decode(String.self, forKey: .description))
            ?? tool.replacingOccurrences(of: "_", with: " ").uppercased()
        destructive = (try? c.decode(Bool.self, forKey: .destructive)) ?? false
        applied = (try? c.decode(Bool.self, forKey: .applied)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tool, forKey: .tool)
        try c.encode(summary, forKey: .summary)
        try c.encode(destructive, forKey: .destructive)
        try c.encode(applied, forKey: .applied)
    }
}

// MARK: - Response

public struct AgentResponse: Codable, Sendable {
    /// Text for the transcript.
    public var reply: String?
    /// Operations awaiting the user's EXECUTE.
    public var pendingActions: [AgentAction]?
    /// Operations the server already carried out, for the receipt list.
    public var appliedActions: [AgentAction]?
    /// True when the server changed task data, so the Mac should re-pull.
    public var tasksChanged: Bool?

    public init(reply: String? = nil, pendingActions: [AgentAction]? = nil,
                appliedActions: [AgentAction]? = nil, tasksChanged: Bool? = nil) {
        self.reply = reply
        self.pendingActions = pendingActions
        self.appliedActions = appliedActions
        self.tasksChanged = tasksChanged
    }

    enum CodingKeys: String, CodingKey {
        case reply, message, text
        case pendingActions = "pending_actions"
        case appliedActions = "applied_actions"
        case tasksChanged = "tasks_changed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = (try? c.decode(String.self, forKey: .reply))
            ?? (try? c.decode(String.self, forKey: .message))
            ?? (try? c.decode(String.self, forKey: .text))
        pendingActions = try? c.decode([AgentAction].self, forKey: .pendingActions)
        appliedActions = try? c.decode([AgentAction].self, forKey: .appliedActions)
        tasksChanged = try? c.decode(Bool.self, forKey: .tasksChanged)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(reply, forKey: .reply)
        try c.encodeIfPresent(pendingActions, forKey: .pendingActions)
        try c.encodeIfPresent(appliedActions, forKey: .appliedActions)
        try c.encodeIfPresent(tasksChanged, forKey: .tasksChanged)
    }
}

public enum AppInfo {
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
