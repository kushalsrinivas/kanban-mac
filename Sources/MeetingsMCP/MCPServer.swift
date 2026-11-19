import Foundation

/// MCP over stdio for the Mac's own meeting store.
///
/// This reads the same SQLite file the app writes, so another agent can ask about
/// meetings even when the app is closed and no VPS is configured. Writes go through
/// the same `TaskService` the app uses; there is no second implementation.
@MainActor
final class MCPServer {
    private let store = LocalStore()
    private let decoder = JSONDecoder()

    func run() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                write(error(nil, -32700, "parse error"))
                continue
            }
            if let response = handle(message) { write(response) }
        }
    }

    private func handle(_ message: [String: Any]) -> [String: Any]? {
        let method = message["method"] as? String
        let id = message["id"]
        let isNotification = id == nil

        guard let method else { return error(id, -32600, "invalid request") }

        switch method {
        case "initialize":
            guard !isNotification else { return nil }
            return result(id, [
                "protocolVersion": "2025-03-26",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "meet-local", "version": "1.0.0"],
                "instructions": "Local meeting memory and commitments from this Mac. "
                    + "Use search_memory or ask_memory over past meetings, list_commitments "
                    + "to follow up, and get_meeting_brief before a meeting."
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": toolManifests])
        case "tools/call":
            guard let params = message["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return error(id, -32602, "tools/call needs a tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let payload = try call(name, arguments)
                return result(id, [
                    "content": [["type": "text", "text": pretty(payload)]],
                    "isError": false
                ])
            } catch {
                return result(id, [
                    "content": [["type": "text", "text": "\(error)"]],
                    "isError": true
                ])
            }
        case "resources/list":
            return result(id, ["resources": []])
        case "prompts/list":
            return result(id, ["prompts": []])
        default:
            return isNotification ? nil : error(id, -32601, "method not found: \(method)")
        }
    }

    // MARK: Tools

    private func call(_ name: String, _ args: [String: Any]) throws -> Any {
        switch name {
        case "search_meetings":
            let needle = (args["query"] as? String ?? "").lowercased()
            let limit = int(args["limit"], 10)
            let meetings = store.meetings.filter { meeting in
                needle.isEmpty || meeting.title.lowercased().contains(needle)
                    || meeting.summary.lowercased().contains(needle)
            }.prefix(limit)
            return meetings.map { compact($0) }

        case "get_meeting":
            guard let id = uuid(args["id"]), let meeting = store.meeting(id) else {
                throw ToolError.notFound("meeting")
            }
            return full(meeting)

        case "search_memory":
            guard let query = args["query"] as? String, !query.isEmpty else {
                throw ToolError.invalid("query is required")
            }
            let hits = MeetingMemory.search(
                query, meetings: store.meetings, transcripts: transcripts(),
                kind: (args["kind"] as? String).flatMap(LocalMemoryEntry.Kind.init(rawValue:)),
                participant: args["participant"] as? String,
                since: (args["since"] as? String).flatMap { DateInput.parse($0) },
                until: (args["until"] as? String).flatMap { DateInput.parse($0) },
                limit: int(args["limit"], 20))
            return hits.map { hit($0) }

        case "ask_memory":
            guard let question = args["question"] as? String, !question.isEmpty else {
                throw ToolError.invalid("question is required")
            }
            let answer = MeetingMemory.answer(
                question, meetings: store.meetings, transcripts: transcripts(),
                since: (args["since"] as? String).flatMap { DateInput.parse($0) })
            return [
                "answer": answer.answer,
                "confident": answer.confident,
                "citations": answer.citations.map { hit($0) }
            ]

        case "list_commitments":
            let state = (args["state"] as? String) ?? "open"
            let owner = (args["owner"] as? String)?.lowercased()
            let limit = int(args["limit"], 100)
            var rows: [(ActionItem, Meeting)] = []
            for meeting in store.meetings {
                for item in meeting.actionItems where item.state != .dismissed {
                    if let owner, !(item.assignee ?? "").lowercased().contains(owner) { continue }
                    switch state {
                    case "open": guard item.isOpen else { continue }
                    case "done": guard item.commitmentState == .done else { continue }
                    case "cancelled": guard item.commitmentState == .cancelled else { continue }
                    case "overdue": guard item.isOverdue() else { continue }
                    default: break
                    }
                    rows.append((item, meeting))
                }
            }
            rows.sort { ($0.0.dueDate ?? .distantFuture) < ($1.0.dueDate ?? .distantFuture) }
            return rows.prefix(limit).map { commitment($0.0, meeting: $0.1) }

        case "complete_commitment":
            guard let id = uuid(args["id"]), let found = store.commitment(id) else {
                throw ToolError.notFound("commitment")
            }
            store.setCommitmentState(id, in: found.meeting.id, to: .done)
            guard let updated = store.commitment(id) else {
                throw ToolError.notFound("commitment")
            }
            return commitment(updated.item, meeting: updated.meeting)

        case "create_task":
            guard let title = args["title"] as? String, !title.isEmpty else {
                throw ToolError.invalid("title is required")
            }
            let created = try TaskService(store: store, syncEnabled: false).create(
                CreateTaskBody(title: title, notes: args["notes"] as? String,
                               status: args["status"] as? String,
                               priority: args["priority"] as? String,
                               due: args["due"] as? String,
                               source: TaskSource.agent.rawValue))
            return [
                "id": created.id.uuidString, "title": created.title,
                "status": created.status.rawValue,
                "due": json(created.dueDate.map { DateInput.iso($0) })
            ]

        case "list_upcoming_meetings":
            let days = int(args["days"], 7)
            let cutoff = Date().addingTimeInterval(TimeInterval(days) * 86_400)
            return store.scheduledMeetings
                .filter { $0.startsAt <= cutoff && $0.endsAt >= Date() }
                .map { scheduled($0) }

        case "get_meeting_brief":
            guard let id = uuid(args["eventId"]),
                  let event = store.scheduledMeeting(id) else {
                throw ToolError.notFound("scheduled meeting")
            }
            let brief = MeetingMemory.brief(
                for: event, meetings: store.meetings,
                scheduledMeetings: store.scheduledMeetings, tasks: store.tasks)
            return [
                "eventId": event.id.uuidString,
                "summary": brief.summary,
                "previousMeetings": brief.relatedMeetings.map {
                    ["meetingId": $0.meetingID.uuidString, "title": $0.title,
                     "date": DateInput.iso($0.date), "summary": $0.summary]
                },
                "openCommitments": brief.openActions.map {
                    ["id": $0.itemID.uuidString, "title": $0.title,
                     "assignee": $0.assignee ?? "", "overdue": $0.overdue,
                     "due": json($0.dueDate.map { DateInput.iso($0) }),
                     "quote": json($0.quote), "start": json($0.sourceStart)]
                },
                "unresolvedDecisions": brief.decisions.map {
                    ["meetingId": $0.meetingID.uuidString, "text": $0.text]
                },
                "unresolvedQuestions": brief.unresolvedQuestions.map {
                    ["meetingId": $0.meetingID.uuidString, "text": $0.text]
                },
                "conflicts": brief.conflicts.map { $0.other.title },
                "suggestedTimes": brief.suggestedSlots.map {
                    ["startsAt": DateInput.iso($0.start), "endsAt": DateInput.iso($0.end)]
                },
                "overdueCount": brief.overdueCount
            ]

        case "list_automation_rules":
            return store.automationRules.map { rule in
                ["id": rule.id.uuidString, "name": rule.name,
                 "enabled": rule.enabled, "trigger": rule.trigger.rawValue,
                 "actions": rule.actions.map { $0.type },
                 "lastRun": json(rule.lastRunAt.map { DateInput.iso($0) })]
            }

        case "list_drafts":
            return store.localMessages.prefix(int(args["limit"], 20)).map { message in
                ["id": message.id.uuidString, "kind": message.kind.rawValue,
                 "status": message.status.rawValue, "subject": message.subject,
                 "body": message.body, "recipients": message.recipients]
            }

        default:
            throw ToolError.invalid("unknown tool '\(name)'")
        }
    }

    // MARK: Serialisation

    private func compact(_ meeting: Meeting) -> [String: Any] {
        ["id": meeting.id.uuidString, "title": meeting.title,
         "date": DateInput.iso(meeting.startedAt), "summary": meeting.summary,
         "status": meeting.status.rawValue,
         "suggestions": meeting.suggestedCount]
    }

    private func full(_ meeting: Meeting) -> [String: Any] {
        [
            "id": meeting.id.uuidString, "title": meeting.title,
            "date": DateInput.iso(meeting.startedAt),
            "duration": meeting.duration,
            "summary": meeting.summary,
            "keyPoints": meeting.keyPoints, "decisions": meeting.decisions,
            "questions": meeting.questions, "topics": meeting.topics,
            "participants": meeting.participants,
            "actionItems": meeting.actionItems.map { commitment($0, meeting: meeting) },
            "transcript": store.transcript(for: meeting.id).map {
                ["start": $0.start, "end": $0.end, "speaker": json($0.speaker),
                 "text": $0.text]
            }
        ]
    }

    private func commitment(_ item: ActionItem, meeting: Meeting) -> [String: Any] {
        [
            "id": item.id.uuidString, "meetingId": meeting.id.uuidString,
            "meetingTitle": meeting.title,
            "title": item.title, "assignee": json(item.assignee),
            "due": json(item.dueDate.map { DateInput.iso($0) }),
            "state": item.commitmentState.rawValue,
            "review": item.state.rawValue,
            "overdue": item.isOverdue(),
            "quote": json(item.quote),
            "start": json(item.sourceStart),
            "taskId": json(item.taskID?.uuidString)
        ]
    }

    private func hit(_ value: LocalMemoryHit) -> [String: Any] {
        ["meetingId": value.meetingID.uuidString,
         "meetingTitle": value.meetingTitle,
         "date": DateInput.iso(value.meetingDate),
         "kind": value.kind.rawValue,
         "text": value.text,
         "snippet": value.snippet,
         "start": json(value.entry.start),
         "score": value.score]
    }

    private func scheduled(_ meeting: ScheduledMeeting) -> [String: Any] {
        ["id": meeting.id.uuidString, "title": meeting.title,
         "startsAt": DateInput.iso(meeting.startsAt),
         "endsAt": DateInput.iso(meeting.endsAt),
         "participants": meeting.participants,
         "meetingId": json(meeting.meetingID?.uuidString)]
    }

    private func transcripts() -> [UUID: [TranscriptSegment]] {
        var out: [UUID: [TranscriptSegment]] = [:]
        for meeting in store.meetings {
            let segments = store.transcript(for: meeting.id)
            if !segments.isEmpty { out[meeting.id] = segments }
        }
        return out
    }

    // MARK: Manifests

    private var toolManifests: [[String: Any]] {
        func schema(_ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required]
        }
        func string(_ description: String) -> [String: Any] {
            ["type": "string", "description": description]
        }
        func integer(_ description: String) -> [String: Any] {
            ["type": "integer", "description": description]
        }
        return [
            ["name": "search_meetings",
             "description": "Find recorded meetings by title or summary.",
             "inputSchema": schema(["query": string("text to find"),
                                    "limit": integer("maximum results")])],
            ["name": "get_meeting",
             "description": "Fetch one meeting with decisions, commitments, participants and transcript.",
             "inputSchema": schema(["id": string("meeting id")], ["id"])],
            ["name": "search_memory",
             "description": "Search decisions, commitments, discussions, questions and transcript text across all meetings.",
             "inputSchema": schema(["query": string("what to find"),
                                    "kind": string("summary|decision|commitment|discussion|question|transcript"),
                                    "participant": string("name filter"),
                                    "since": string("ISO date"), "until": string("ISO date"),
                                    "limit": integer("maximum results")], ["query"])],
            ["name": "ask_memory",
             "description": "Answer a question from meeting history with citations.",
             "inputSchema": schema(["question": string("the question"),
                                    "since": string("ISO date")], ["question"])],
            ["name": "list_commitments",
             "description": "List commitments with owner, due date, quote and overdue state.",
             "inputSchema": schema(["state": string("open|done|cancelled|overdue|all"),
                                    "owner": string("name filter"),
                                    "limit": integer("maximum results")])],
            ["name": "complete_commitment",
             "description": "Mark a commitment done; a linked board task completes too.",
             "inputSchema": schema(["id": string("commitment id")], ["id"])],
            ["name": "create_task",
             "description": "Create a task on the local board.",
             "inputSchema": schema(["title": string("task title"),
                                    "notes": string("details"), "due": string("ISO date or TODAY"),
                                    "priority": string("low|medium|high|urgent"),
                                    "status": string("inbox|todo|in_progress|done")], ["title"])],
            ["name": "list_upcoming_meetings",
             "description": "List locally scheduled meetings for the next N days.",
             "inputSchema": schema(["days": integer("days ahead")])],
            ["name": "get_meeting_brief",
             "description": "Pre-meeting brief: last conversations, open commitments, unresolved decisions, conflicts and better times.",
             "inputSchema": schema(["eventId": string("scheduled meeting id")], ["eventId"])],
            ["name": "list_automation_rules",
             "description": "List local automation rules.",
             "inputSchema": schema([:])],
            ["name": "list_drafts",
             "description": "List locally composed follow-up emails and commitment notifications.",
             "inputSchema": schema(["limit": integer("maximum results")])]
        ]
    }

    // MARK: JSON-RPC

    private func result(_ id: Any?, _ payload: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": payload]
    }

    private func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(),
         "error": ["code": code, "message": message]]
    }

    private func write(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    private func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                    options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    private func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    private func int(_ value: Any?, _ fallback: Int) -> Int {
        (value as? NSNumber)?.intValue ?? fallback
    }

    private func json(_ value: Any?) -> Any { value ?? NSNull() }
}

private enum ToolError: Error, CustomStringConvertible {
    case invalid(String)
    case notFound(String)

    var description: String {
        switch self {
        case .invalid(let detail): return "Invalid arguments: \(detail)"
        case .notFound(let what): return "No \(what) with that id"
        }
    }
}
