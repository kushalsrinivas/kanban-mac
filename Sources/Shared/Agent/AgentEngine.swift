import Foundation
import os

/// Executes one agent turn against the app's own store.
///
/// Reads run immediately and return typed artifacts. Writes are validated into
/// `AgentOperation`s and handed back for the user to confirm; this type never
/// mutates a task itself. That split is what keeps "what's on my todo" instant and
/// "delete my board" impossible without a second press.
@MainActor
public final class AgentEngine {

    public struct Turn: Sendable {
        public var reply: String = ""
        public var artifacts: [AgentArtifact] = []
        public var operations: [AgentOperation] = []
        public var navigation: AgentNavigation?
        /// A scheduling proposal awaiting the user's EXECUTE.
        public var scheduledDraft: ScheduledMeetingDraft?
        public var suggestions: [String] = []
        public var autoPlay = false
        /// The parser found nothing it owns; a model may take over.
        public var fallback = false
        public var fallbackQuery: String?

        public var isEmpty: Bool {
            reply.isEmpty && artifacts.isEmpty && operations.isEmpty && navigation == nil
        }
    }

    public let store: LocalStore
    /// The server holds an audio object for uploaded meetings, so a remote playback
    /// URL exists. Without a configured VPS this is false and only local files play.
    public let remotePlayback: Bool
    private let now: () -> Date
    /// Read-only events from the Mac's system calendars. Local scheduled meetings
    /// and external events share one brief/list surface; only local ones are editable.
    private let externalScheduledMeetings: () -> [ScheduledMeeting]
    /// Local Gmail cache. Read-only here; writes become proposed operations.
    private let gmail: GmailDataSource?
    private let logger = Logger(subsystem: "com.kanban.app", category: "agent")
    /// Transcripts are paged from SQLite. One turn may match several meetings, so
    /// each is read at most once per turn rather than once per check.
    private var transcriptCache: [UUID: [TranscriptSegment]] = [:]

    public init(store: LocalStore, remotePlayback: Bool = false,
                now: @escaping () -> Date = Date.init,
                externalScheduledMeetings: @escaping () -> [ScheduledMeeting] = { [] },
                gmail: GmailDataSource? = nil) {
        self.store = store
        self.remotePlayback = remotePlayback
        self.now = now
        self.externalScheduledMeetings = externalScheduledMeetings
        self.gmail = gmail
    }

    // MARK: Turn

    public func run(_ text: String, context: inout AgentContext,
                    onStage: (AgentStage) -> Void = { _ in }) -> Turn {
        transcriptCache.removeAll(keepingCapacity: true)
        let intent = AgentPlanner.plan(text, context: context, now: now())
        onStage(.thinking)
        if intent.isEmailIntent, gmail?.isSecurityLocked == true {
            onStage(.done)
            return Turn(reply: "Mail is locked until FileVault is verified. Open Mail or Settings → Gmail and press RECHECK.",
                        suggestions: ["What's on my todo?", "Show my recent meetings"])
        }
        var turn: Turn

        switch intent {
        case .help:
            turn = helpTurn()

        case .taskList(let filter):
            onStage(.searching("tasks"))
            turn = taskList(filter, context: &context)

        case .meetingList(let filter):
            onStage(.searching("meetings"))
            turn = meetingList(filter, context: &context)

        case .summary(let selector):
            onStage(.retrieving("meeting"))
            turn = summary(selector, context: &context)

        case .recording(let selector):
            onStage(.retrieving("recording"))
            turn = recording(selector, context: &context, autoPlay: wantsPlayback(text))

        case .transcript(let selector, let query):
            onStage(.retrieving("transcript"))
            turn = transcript(selector, query: query, context: &context)

        case .actionItems(let selector, let window):
            onStage(.retrieving("action items"))
            turn = actionItems(selector, window: window, context: &context)

        case .participants(let selector):
            onStage(.retrieving("participants"))
            turn = participants(selector, context: &context)

        case .scheduledMeetingList:
            onStage(.retrieving("schedule"))
            turn = scheduledList(context: &context)

        case .scheduleMeeting(let draft):
            onStage(.processing("schedule"))
            turn = schedule(draft)

        case .scheduledBrief(let selector):
            onStage(.retrieving("schedule"))
            turn = scheduledBrief(selector, context: &context)

        case .openCalendar:
            turn = Turn(reply: "Opening your calendar.",
                        navigation: .calendar(context.lastScheduledMeetingID),
                        suggestions: ["What's on my calendar?", "Schedule a meeting"])

        case .calendarHelp(let reason):
            turn = Turn(reply: reason,
                        suggestions: ["What's on my calendar?",
                                      "Schedule a meeting about onboarding with Sarah tomorrow at 2pm"])

        case .openMeeting(let selector):
            onStage(.processing("navigation"))
            turn = openMeeting(selector, context: &context)

        case .openTask(let selector):
            onStage(.processing("navigation"))
            turn = openTask(selector, context: &context)

        case .openRecorder:
            turn = Turn(reply: "Opening the recorder. Press START RECORDING when you're ready.",
                        navigation: .recorder,
                        suggestions: ["Show my recent meetings", "What's on my todo?"])

        case .openMail:
            turn = Turn(reply: "Opening your mail.",
                        navigation: .mail(accountID: nil, threadID: nil),
                        suggestions: emailSuggestions)

        case .emailUnread:
            onStage(.searching("email"))
            turn = emailUnread(context: &context)

        case .emailAttention:
            onStage(.searching("email"))
            turn = emailAttention(context: &context)

        case .emailSummarize(let selector):
            onStage(.retrieving("email"))
            turn = emailSummarize(selector, context: &context)

        case .emailConversation(let person):
            onStage(.searching("email"))
            turn = emailConversation(person, context: &context)

        case .emailCommitments(let person):
            onStage(.retrieving("email commitments"))
            turn = emailCommitments(person, context: &context)

        case .emailSearch(let query):
            onStage(.searching("email"))
            turn = emailSearch(query, context: &context)

        case .emailOpen(let selector):
            onStage(.processing("navigation"))
            turn = emailOpen(selector, context: &context)

        case .emailDraftReply(let selector, let all):
            onStage(.processing("draft"))
            turn = emailDraftReply(selector, all: all, context: &context)

        case .emailCompose(let to, let subject, let body):
            onStage(.processing("draft"))
            turn = emailCompose(to: to, subject: subject, body: body, context: &context)

        case .emailFollowUp(let selector):
            onStage(.processing("draft"))
            turn = emailFollowUp(selector, context: &context)

        case .emailArchive(let selector):
            onStage(.processing("email"))
            turn = emailAction(selector, action: .archive, context: &context)

        case .emailTrash(let selector):
            onStage(.processing("email"))
            turn = emailAction(selector, action: .trash, context: &context)

        case .emailMarkRead(let selector, let read):
            onStage(.processing("email"))
            turn = emailAction(selector, action: .read(read), context: &context)

        case .emailLabel(let selector, let labels, let add):
            onStage(.processing("email"))
            turn = emailAction(selector, action: .label(labels, add: add), context: &context)

        case .emailSuggestLabels(let selector):
            onStage(.processing("email"))
            turn = emailSuggestLabels(selector, context: &context)

        case .createTask(let title, let notes, let due, let priority, let status, let tags):
            onStage(.processing("board"))
            turn = propose(.create(title: title, notes: notes, due: due, priority: priority,
                                   status: status, tags: tags))

        case .createTasks(let drafts):
            onStage(.processing("board"))
            turn = Turn(operations: drafts.map {
                .create(title: $0.title, notes: $0.notes, due: $0.due,
                        priority: $0.priority, status: $0.status, tags: $0.tags)
            }, suggestions: ["What's on my todo?", "Show my recent meetings"])

        case .renameTask(let selector, let title):
            onStage(.processing("board"))
            turn = update(selector, context: &context) { task in
                .update(task, title: title)
            }

        case .setDue(let selector, let due):
            onStage(.processing("board"))
            let clear = ["none", "clear", "never", "-"].contains(due.lowercased())
            guard clear || DateInput.parse(due, now: now()) != nil else {
                turn = Turn(reply: "I couldn't read “\(due)” as a date. Try “tomorrow”, “friday” or 2026-11-20.")
                break
            }
            turn = update(selector, context: &context) { task in
                .update(task, due: due)
            }

        case .setPriority(let selector, let priority):
            onStage(.processing("board"))
            turn = update(selector, context: &context) { task in
                .update(task, priority: priority)
            }

        case .tagTask(let selector, let tags):
            onStage(.processing("board"))
            turn = update(selector, context: &context) { task in
                .update(task, tags: TaskService.normalise(task.tags + tags))
            }

        case .completeTask(let selector):
            onStage(.processing("board"))
            turn = taskOperation(selector, context: &context, verb: "complete",
                                 pending: .complete) { .complete($0) }

        case .moveTask(let selector, let status):
            onStage(.processing("board"))
            turn = taskOperation(selector, context: &context, verb: "move",
                                 pending: .move(status)) { .move($0, to: status) }

        case .archiveTask(let selector):
            onStage(.processing("board"))
            turn = taskOperation(selector, context: &context, verb: "archive",
                                 pending: .archive) { .archive($0) }

        case .deleteTask(let selector):
            onStage(.processing("board"))
            turn = taskOperation(selector, context: &context, verb: "delete",
                                 pending: .delete) { .delete($0) }

        case .askModel(let query):
            // The session decides whether a model is configured; this is the
            // deterministic engine saying "this needs one".
            turn = Turn(fallback: true, fallbackQuery: query)

        case .keywordSearch(let subject):
            onStage(.searching("everything"))
            turn = keywordSearch(subject, context: &context)
        }

        onStage(.done)
        // Log shape, never content: prompts, titles and transcripts stay out of logs.
        let intentLabel = String(describing: intent).split(separator: "(").first.map(String.init) ?? "unknown"
        logger.debug("agent turn \(intentLabel, privacy: .public) artifacts=\(turn.artifacts.count, privacy: .public) operations=\(turn.operations.count, privacy: .public) fallback=\(turn.fallback, privacy: .public)")
        return turn
    }

    // MARK: Reads — tasks

    private func taskList(_ filter: AgentTaskFilter, context: inout AgentContext) -> Turn {
        var query = ListQuery()
        query.status = filter.status
        query.query = filter.query
        query.priority = filter.priority
        query.tag = filter.tag
        query.due = filter.due?.rawValue
        query.includeDone = filter.includeDone || filter.status == .done
        query.limit = filter.limit
        var tasks = TaskService(store: store).list(query, now: now())
        if filter.status == .done, filter.due == AgentTaskFilter.Due.today {
            // "What did I finish today?" is about completedAt, not dueDate.
            let calendar = Calendar.current
            let current = now()
            tasks = store.tasks.filter { task in
                guard task.status == .done, !task.isArchived,
                      let completed = task.completedAt else { return false }
                return calendar.isDate(completed, inSameDayAs: current)
            }.boardSorted()
        } else if let needle = filter.query, !needle.isEmpty, tasks.isEmpty,
           filter.status == nil, filter.due == nil, filter.priority == nil, filter.tag == nil {
            tasks = matchingTasks(needle, limit: filter.limit,
                                  includeDone: filter.includeDone || filter.status == .done)
        }
        if filter.query == nil, filter.due == nil, filter.status == nil,
           filter.priority == nil, filter.tag == nil {
            tasks = store.openTasks.agendaSorted(now: now())
            tasks = Array(tasks.prefix(filter.limit))
        }

        context.record(tasks: tasks.map(\.id),
                       last: tasks.count == 1 ? tasks[0].id : nil)

        let title = taskListTitle(filter)
        var note: String?
        if !tasks.isEmpty, filter.query == nil, filter.status == nil, filter.due == nil {
            note = "Ordered by urgency: overdue first, then soonest due, then priority."
        }
        if tasks.isEmpty {
            note = emptyTaskNote(filter)
        }
        let artifact = AgentArtifact(.taskList(TaskListArtifact(
            title: title, tasks: tasks, note: note,
            emptyMessage: emptyTaskNote(filter) ?? "No tasks match.")))

        let reply: String
        if tasks.isEmpty {
            reply = emptyTaskNote(filter) ?? "No tasks match."
        } else if filter.status == .done, filter.due == AgentTaskFilter.Due.today {
            reply = "\(tasks.count) finished today."
        } else if filter.status == .done {
            reply = "\(tasks.count) done task\(tasks.count == 1 ? "" : "s")."
        } else {
            let open = tasks.filter(\.isOpen).count
            reply = "\(tasks.count) task\(tasks.count == 1 ? "" : "s")"
                + (open == tasks.count ? "" : " · \(open) open")
                + "."
        }
        return Turn(reply: reply, artifacts: [artifact],
                    suggestions: taskSuggestions(tasks))
    }

    private func taskListTitle(_ filter: AgentTaskFilter) -> String {
        if let query = filter.query, !query.isEmpty { return "TASKS · “\(query.uppercased())”" }
        if let tag = filter.tag { return "#\(tag.uppercased())" }
        if filter.status == .done, filter.due == AgentTaskFilter.Due.today { return "FINISHED TODAY" }
        if filter.due == .overdue { return "OVERDUE" }
        if filter.due == .today { return "DUE TODAY" }
        if filter.due == .week { return "DUE THIS WEEK" }
        if filter.due == AgentTaskFilter.Due.none { return "NO DUE DATE" }
        if let priority = filter.priority { return "\(priority.longLabel) PRIORITY" }
        switch filter.status {
        case .inbox: return "INBOX"
        case .todo: return "TODO"
        case .inProgress: return "IN PROGRESS"
        case .done: return "DONE"
        case nil: return "OPEN TASKS"
        }
    }

    private func emptyTaskNote(_ filter: AgentTaskFilter) -> String? {
        guard filter.query == nil, filter.tag == nil, filter.priority == nil else {
            return "No tasks match that search."
        }
        if filter.status == .done, filter.due == AgentTaskFilter.Due.today {
            return "Nothing has been finished today."
        }
        if filter.due == .overdue { return "Nothing is overdue. The board is clean." }
        if filter.due == .today { return "Nothing is due today." }
        if filter.status == .inProgress { return "Nothing is in progress right now." }
        if filter.status == .todo { return "The TODO column is empty." }
        return "No open tasks. Add one from the board or ask me to create it."
    }

    private func taskSuggestions(_ tasks: [TaskItem]) -> [String] {
        guard !tasks.isEmpty else {
            return ["Show my recent meetings", "Show overdue tasks", "Create a task"]
        }
        var out: [String] = []
        if tasks.count > 1 { out.append("Complete the first one") }
        else { out.append("Complete it") }
        out.append("Show my recent meetings")
        out.append("What's overdue?")
        return out
    }

    // MARK: Reads — meetings

    private func meetingList(_ filter: AgentMeetingFilter, context: inout AgentContext) -> Turn {
        let meetings = filteredMeetings(filter)
        context.record(meetings: meetings.map(\.id),
                       last: meetings.first?.id,
                       topic: filter.query)
        let title: String
        switch filter.window {
        case .today: title = "MEETINGS · TODAY"
        case .yesterday: title = "MEETINGS · YESTERDAY"
        case .thisWeek: title = "MEETINGS · THIS WEEK"
        case .lastWeek: title = "MEETINGS · LAST WEEK"
        case nil:
            title = filter.query.map { "MEETINGS · “\($0.uppercased())”" }
                ?? (filter.recordingOnly ? "RECORDINGS" : "RECENT MEETINGS")
        }

        let artifact = AgentArtifact(.meetingList(MeetingListArtifact(
            title: title, meetings: meetings, note: nil,
            emptyMessage: filter.query == nil
                ? "No meetings here yet. Record one from the MEETINGS section."
                : "No meetings match that search.")))

        let reply: String
        if meetings.isEmpty {
            reply = filter.query == nil
                ? "No meetings to show yet."
                : "No meetings match “\(filter.query ?? "")”."
        } else {
            reply = "\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")."
        }
        var suggestions = ["Summarize it", "Show my last recording", "Action items from this week"]
        if meetings.count > 1 { suggestions[0] = "Summarize the second one" }
        if meetings.isEmpty { suggestions = ["Start recording", "What's on my todo?"] }
        return Turn(reply: reply, artifacts: [artifact], suggestions: suggestions)
    }

    private func filteredMeetings(_ filter: AgentMeetingFilter) -> [Meeting] {
        var meetings = store.meetings.chronological()
        if let query = filter.query, !query.isEmpty {
            // Title/summary matching is cheap; transcript fallback is a per-row read,
            // so bound it to the recent window a person could plausibly mean.
            meetings = matchingMeetings(query)
            if filter.window != nil {
                meetings = meetings.filter { meeting in
                    filter.window.map { isInWindow(meeting.startedAt, $0) } ?? true
                }
            }
            if filter.recordingOnly {
                meetings = meetings.filter {
                    $0.audioFilename != nil || ($0.remoteID != nil && remotePlayback)
                }
            }
            return Array(meetings.prefix(filter.limit))
        }
        if let window = filter.window {
            meetings = meetings.filter { isInWindow($0.startedAt, window) }
        }
        if filter.recordingOnly {
            meetings = meetings.filter { $0.audioFilename != nil || ($0.remoteID != nil && remotePlayback) }
        }
        return Array(meetings.prefix(filter.limit))
    }

    private func summary(_ selector: AgentMeetingSelector, context: inout AgentContext) -> Turn {
        switch resolveMeeting(selector, context: context) {
        case .none:
            return Turn(reply: emptyMeetingReply(selector, subject: "summarize"),
                        suggestions: ["Show my recent meetings", "Start recording"])
        case .many(let meetings):
            context.record(meetings: meetings.map(\.id), last: nil)
            context.awaitQuery(.summary)
            return Turn(reply: "\(meetings.count) meetings match. Which one?",
                        artifacts: [meetingListArtifact(meetings, title: "WHICH MEETING?")],
                        suggestions: meetings.prefix(3).map { "Summarize \($0.title)" })
        case .one(let meeting):
            let transcript = self.transcript(for: meeting)
            let related = store.tasks(fromMeeting: meeting.id)
            let artifact = AgentArtifactBuilder.summary(meeting, transcript: transcript,
                                                        relatedTasks: related)
            context.focus(meeting: meeting.id)
            let reply: String
            if meeting.summary.isEmpty, transcript.isEmpty {
                reply = "“\(meeting.title)” has no summary or transcript yet. It may still need processing."
            } else if meeting.summary.isEmpty {
                reply = "“\(meeting.title)” has no written summary yet — here is what the transcript contains."
            } else {
                reply = "Summary · \(meeting.title) · \(DateInput.shortLabel(meeting.startedAt)) · \(meeting.durationLabel)."
            }
            return Turn(reply: reply, artifacts: [artifact], suggestions: meetingFollowUps(meeting))
        }
    }

    private func meetingListArtifact(_ meetings: [Meeting], title: String) -> AgentArtifact {
        AgentArtifact(.meetingList(MeetingListArtifact(title: title, meetings: meetings)))
    }

    private func recording(_ selector: AgentMeetingSelector, context: inout AgentContext,
                           autoPlay: Bool) -> Turn {
        var chosen = selector
        if case .latest = selector {
            // "Find my last recording" means the last meeting that actually has
            // audio, not the last meeting that happens to exist.
            if let playable = store.meetings.chronological().first(where: {
                AgentArtifactBuilder.recording($0, remotePlayback: remotePlayback)
                    .artifactIsPlayable
            }) {
                chosen = .id(playable.id)
            }
        }
        switch resolveMeeting(chosen, context: context) {
        case .none:
            return Turn(reply: "There are no recordings yet.",
                        suggestions: ["Start recording", "Show my recent meetings"])
        case .many(let meetings):
            context.record(meetings: meetings.map(\.id), last: nil)
            context.awaitQuery(.recording)
            return Turn(reply: "Which recording?",
                        artifacts: [meetingListArtifact(meetings, title: "CHOOSE A RECORDING")],
                        suggestions: meetings.prefix(3).map { "Play \($0.title)" })
        case .one(let meeting):
            let artifact = AgentArtifactBuilder.recording(meeting, remotePlayback: remotePlayback)
            context.focus(meeting: meeting.id)
            let playable = artifact.artifactIsPlayable
            let reply: String
            if playable {
                reply = "\(meeting.title) · \(DateInput.shortLabel(meeting.startedAt)) · \(meeting.durationLabel)."
            } else {
                reply = "“\(meeting.title)” has no audio available. \(artifact.unavailableReason ?? "")"
                    .trimmingCharacters(in: .whitespaces)
            }
            return Turn(reply: reply, artifacts: [artifact],
                        suggestions: ["Summarize it", "What tasks came out of it?",
                                      "Show the transcript"],
                        autoPlay: autoPlay && playable)
        }
    }

    private func transcript(_ selector: AgentMeetingSelector, query: String?,
                            context: inout AgentContext) -> Turn {
        guard case .one(let meeting) = resolveMeeting(selector, context: context) else {
            let meetings = resolveMeetings(selector, context: context)
            if meetings.isEmpty {
                return Turn(reply: "I don't have a meeting to read.",
                            suggestions: ["Show my recent meetings", "Start recording"])
            }
            context.record(meetings: meetings.map(\.id), last: nil)
            context.awaitQuery(.transcript)
            return Turn(reply: "Which meeting's transcript?",
                        artifacts: [meetingListArtifact(meetings, title: "CHOOSE A MEETING")],
                        suggestions: meetings.prefix(3).map { "Show the transcript of \($0.title)" })
        }

        let all = transcript(for: meeting)
        context.focus(meeting: meeting.id)
        guard !all.isEmpty else {
            let artifact = AgentArtifact(.transcript(TranscriptArtifact(
                meeting: meeting, segments: [], totalCount: 0, query: query,
                note: "No transcript was stored for this meeting.")))
            return Turn(reply: "There is no transcript for “\(meeting.title)” yet.",
                        artifacts: [artifact],
                        suggestions: ["Summarize it", "Show my recent meetings"])
        }

        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = needle.isEmpty ? all : all.filter {
            $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let cap = 80
        let shown = Array(matched.prefix(cap))
        var note: String?
        if !needle.isEmpty, matched.isEmpty {
            note = "No segment contains “\(needle)”."
        } else if matched.count > cap {
            note = "Showing \(cap) of \(matched.count) matching segments."
        } else if !needle.isEmpty {
            note = "\(matched.count) of \(all.count) segments mention “\(needle)”."
        }
        let artifact = AgentArtifact(.transcript(TranscriptArtifact(
            meeting: meeting, segments: shown, totalCount: all.count,
            query: needle.isEmpty ? nil : needle, note: note)))

        let reply: String
        if !needle.isEmpty {
            reply = matched.isEmpty
                ? "Nothing in “\(meeting.title)” mentions “\(needle)”."
                : "\(matched.count) segment\(matched.count == 1 ? "" : "s") mention “\(needle)”."
        } else {
            reply = "Transcript · \(meeting.title) · \(all.count) segments · \(meeting.durationLabel)."
        }
        return Turn(reply: reply, artifacts: [artifact],
                    suggestions: ["Summarize it"] + meetingFollowUps(meeting))
    }

    private func actionItems(_ selector: AgentMeetingSelector?,
                             window: AgentMeetingFilter.Window?,
                             context: inout AgentContext) -> Turn {
        var meetings: [Meeting]
        var single: Meeting?

        if let selector {
            switch selector {
            case .thisWeek:
                meetings = store.meetings.chronological().filter { isInWindow($0.startedAt, .thisWeek) }
            case .lastWeek:
                meetings = store.meetings.chronological().filter { isInWindow($0.startedAt, .lastWeek) }
            case .any:
                meetings = Array(store.meetings.chronological().prefix(10))
            default:
                switch resolveMeeting(selector, context: context) {
                case .one(let meeting):
                    meetings = [meeting]
                    single = meeting
                case .many(let found):
                    meetings = found
                case .none:
                    meetings = []
                }
            }
        } else if let window {
            meetings = store.meetings.chronological().filter { isInWindow($0.startedAt, window) }
        } else {
            meetings = Array(store.meetings.chronological().prefix(10))
        }

        guard !meetings.isEmpty else {
            return Turn(reply: "No meetings in that range.",
                        suggestions: ["Show my recent meetings", "What's on my todo?"])
        }

        let pairs = meetings.flatMap { meeting in
            meeting.actionItems.map { ($0, meeting) }
        }.sorted { a, b in
            if a.1.startedAt != b.1.startedAt { return a.1.startedAt > b.1.startedAt }
            return a.0.position < b.0.position
        }

        let tasks = store.tasks
        let artifact = AgentArtifactBuilder.actionItems(meeting: single, items: pairs, tasks: tasks)
        let ids = meetings.map(\.id)
        context.record(meetings: ids, last: single?.id)

        if let single {
            let suggested = pairs.filter { $0.0.isSuggested }.count
            let added = pairs.filter { $0.0.state == .added }.count
            let reply = pairs.isEmpty
                ? "“\(single.title)” has no extracted action items."
                : "\(single.title) · \(suggested) suggested · \(added) added as task\(added == 1 ? "" : "s")."
            var artifacts = [artifact]
            let related = store.tasks(fromMeeting: single.id)
            if !related.isEmpty {
                artifacts.append(AgentArtifact(.taskList(TaskListArtifact(
                    title: "TASKS FROM THIS MEETING", tasks: related,
                    note: "Real tasks linked to “\(single.title)”."))))
            }
            return Turn(reply: reply, artifacts: artifacts, suggestions: meetingFollowUps(single))
        }

        let suggested = pairs.filter { $0.0.isSuggested }.count
        let added = pairs.filter { $0.0.state == .added }.count
        let reply = pairs.isEmpty
            ? "No action items across \(meetings.count) meeting\(meetings.count == 1 ? "" : "s")."
            : "\(pairs.count) action item\(pairs.count == 1 ? "" : "s") across \(meetings.count) meeting\(meetings.count == 1 ? "" : "s") · \(suggested) suggested · \(added) added."
        return Turn(reply: reply, artifacts: [artifact],
                    suggestions: ["Show my recent meetings", "What's on my todo?",
                                  "Summarize the first one"])
    }

    private func participants(_ selector: AgentMeetingSelector,
                              context: inout AgentContext) -> Turn {
        switch resolveMeeting(selector, context: context) {
        case .none:
            return Turn(reply: "I don't have a meeting to look at.",
                        suggestions: ["Show my recent meetings"])
        case .many(let meetings):
            context.record(meetings: meetings.map(\.id), last: nil)
            context.awaitQuery(.participants)
            return Turn(reply: "Which meeting?",
                        artifacts: [meetingListArtifact(meetings, title: "CHOOSE A MEETING")],
                        suggestions: meetings.prefix(3).map { "Who was in \($0.title)?" })
        case .one(let meeting):
            context.focus(meeting: meeting.id)
            guard !meeting.participants.isEmpty else {
                return Turn(reply: "No participants were identified for “\(meeting.title)”.",
                            suggestions: ["Show the transcript", "Summarize it"])
            }
            let artifact = AgentArtifactBuilder.participants(
                meeting, items: meeting.actionItems, tasks: store.tasks)
            return Turn(reply: "\(meeting.participants.count) participant\(meeting.participants.count == 1 ? "" : "s") · \(meeting.title).",
                        artifacts: [artifact],
                        suggestions: ["Summarize it", "What tasks came out of it?"])
        }
    }

    // MARK: Scheduled meetings

    private func scheduledList(context: inout AgentContext) -> Turn {
        let upcoming = mergedScheduledMeetings().upcoming(now: now())
        if let first = upcoming.first { context.focus(scheduledMeeting: first.id) }
        let artifact = AgentArtifactBuilder.scheduledList(upcoming, title: "UPCOMING")
        let reply = upcoming.isEmpty
            ? "No scheduled meetings. Ask me to schedule one, for example: “schedule a meeting about onboarding with Sarah tomorrow at 2pm”."
            : "\(upcoming.count) scheduled meeting\(upcoming.count == 1 ? "" : "s")."
        return Turn(reply: reply, artifacts: [artifact],
                    suggestions: upcoming.isEmpty
                        ? ["Schedule a meeting", "What's on my todo?"]
                        : ["Prepare me for the next one", "Schedule a meeting", "What's on my todo?"])
    }

    private func schedule(_ draft: ScheduledMeetingDraft) -> Turn {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return Turn(reply: "What should the meeting be called?",
                        suggestions: ["Schedule a meeting about onboarding with Sarah tomorrow at 2pm"])
        }
        guard draft.endsAt > draft.startsAt else {
            return Turn(reply: "The end time must be after the start time.")
        }
        guard draft.startsAt > now() else {
            return Turn(reply: "That time has already passed. Give me a future day and time.")
        }
        return Turn(reply: "Ready to schedule “\(title)” · \(CalendarFormat.line(draft)). Confirm it in PROPOSED OPERATIONS.",
                    scheduledDraft: draft,
                    suggestions: ["What's on my calendar?"])
    }

    private func scheduledBrief(_ selector: AgentScheduledSelector,
                                context: inout AgentContext) -> Turn {
        let all = mergedScheduledMeetings().scheduledSorted()
        let upcoming = all.upcoming(now: now())
        let chosen: ScheduledMeeting?
        switch selector {
        case .next:
            chosen = upcoming.first
        case .current:
            chosen = context.lastScheduledMeetingID.flatMap(store.scheduledMeeting) ?? upcoming.first
        case .query(let query):
            chosen = upcoming.first { $0.matches(query: query) }
                ?? all.first { $0.matches(query: query) }
        }
        guard let meeting = chosen else {
            return Turn(reply: "I couldn't find a scheduled meeting matching that.",
                        suggestions: ["What's on my calendar?", "Schedule a meeting"])
        }
        context.focus(scheduledMeeting: meeting.id)
        let brief = MeetingMemory.brief(
            for: meeting, meetings: store.meetings,
            scheduledMeetings: mergedScheduledMeetings(), tasks: store.tasks)
        let artifact = AgentArtifactBuilder.scheduledBrief(brief)
        var reply = "Brief · \(meeting.title) · \(CalendarFormat.line(meeting))."
        if !brief.relatedMeetings.isEmpty {
            reply += " \(brief.relatedMeetings.count) related conversation\(brief.relatedMeetings.count == 1 ? "" : "s")."
        }
        if !brief.openActions.isEmpty {
            reply += " \(brief.openActions.count) open item\(brief.openActions.count == 1 ? "" : "s")."
        }
        return Turn(reply: reply, artifacts: [artifact],
                    suggestions: ["Open my calendar", "Schedule a meeting",
                                  "What's on my todo?"])
    }

    /// Local rows and read-only system-calendar events, deduplicated by id.
    private func mergedScheduledMeetings() -> [ScheduledMeeting] {
        var seen = Set<UUID>()
        var out: [ScheduledMeeting] = []
        for meeting in store.scheduledMeetings + externalScheduledMeetings() {
            if seen.insert(meeting.id).inserted { out.append(meeting) }
        }
        return out
    }

    // MARK: Navigation

    private func openMeeting(_ selector: AgentMeetingSelector,
                             context: inout AgentContext) -> Turn {
        switch resolveMeeting(selector, context: context) {
        case .one(let meeting):
            context.focus(meeting: meeting.id)
            return Turn(reply: "Opening “\(meeting.title)”.",
                        navigation: .meeting(meeting.id, focus: nil),
                        suggestions: ["Summarize it"] + meetingFollowUps(meeting))
        case .many(let meetings):
            context.record(meetings: meetings.map(\.id), last: nil)
            context.awaitQuery(.openMeeting)
            return Turn(reply: "Which meeting?",
                        artifacts: [meetingListArtifact(meetings, title: "CHOOSE A MEETING")],
                        suggestions: meetings.prefix(3).map { "Open \($0.title)" })
        case .none:
            return Turn(reply: "I couldn't find that meeting.",
                        suggestions: ["Show my recent meetings"])
        }
    }

    private func openTask(_ selector: AgentTaskSelector, context: inout AgentContext) -> Turn {
        switch resolveTask(selector, context: context) {
        case .one(let task):
            context.focus(task: task.id)
            return Turn(reply: "Opening “\(task.title)”.",
                        navigation: .task(task.id),
                        suggestions: ["Complete it", "What's on my todo?"])
        case .many(let tasks):
            context.record(tasks: tasks.map(\.id))
            return Turn(reply: "Which task?",
                        artifacts: [AgentArtifact(.taskList(TaskListArtifact(
                            title: "CHOOSE A TASK", tasks: tasks)))],
                        suggestions: tasks.prefix(3).map { "Open \($0.title)" })
        case .none:
            return Turn(reply: "I couldn't find that task.",
                        suggestions: ["What's on my todo?", "Show overdue tasks"])
        }
    }

    // MARK: Writes

    private func propose(_ operation: AgentOperation) -> Turn {
        // The session knows the auto-apply policy; a hard-coded "confirm it" here
        // was wrong the moment safe writes started applying immediately.
        Turn(operations: [operation],
             suggestions: ["What's on my todo?", "Show my recent meetings"])
    }

    private func taskOperation(_ selector: AgentTaskSelector, context: inout AgentContext,
                               verb: String,
                               pending: AgentContext.PendingTaskAction? = nil,
                               make: (TaskItem) -> AgentOperation) -> Turn {
        switch resolveTask(selector, context: context) {
        case .one(let task):
            context.focus(task: task.id)
            return propose(make(task))
        case .many(let tasks):
            context.record(tasks: tasks.map(\.id))
            context.awaitTask(pending)
            return Turn(reply: "\(tasks.count) tasks match. Which one should I \(verb)?",
                        artifacts: [AgentArtifact(.taskList(TaskListArtifact(
                            title: "WHICH TASK?", tasks: tasks)))],
                        suggestions: tasks.prefix(3).map { "\(verb.capitalized) \($0.title)" })
        case .none:
            context.clearPending()
            return Turn(reply: "I couldn't find a task matching that. Nothing was changed.",
                        suggestions: ["What's on my todo?", "Show overdue tasks"])
        }
    }

    private func update(_ selector: AgentTaskSelector, context: inout AgentContext,
                        make: (TaskItem) -> AgentOperation) -> Turn {
        taskOperation(selector, context: &context, verb: "update", make: make)
    }

    // MARK: Keyword search

    // MARK: Reads — mail

    private var emailSuggestions: [String] {
        ["Summarize my unread emails",
         "Which emails need my attention?",
         "Find the latest conversation with…",
         "Search email for pricing"]
    }

    private func gmailUnavailable() -> Turn {
        Turn(reply: "Connect a Gmail account in Settings → Gmail first.",
             suggestions: ["Open my inbox", "What's on my todo?"])
    }

    private func accountsByID() -> [UUID: GmailAccount] {
        guard let gmail else { return [:] }
        return Dictionary(uniqueKeysWithValues: gmail.accounts.map { ($0.id, $0) })
    }

    private func emailListTurn(_ threads: [GmailThreadSummary], title: String,
                               reply: String, context: inout AgentContext,
                               reasons: [String: String]? = nil,
                               note: String? = nil) -> Turn {
        guard gmail != nil else { return gmailUnavailable() }
        let artifact = AgentArtifactBuilder.emails(
            threads, accounts: accountsByID(), title: title, reasons: reasons, note: note)
        context.record(emails: threads.map {
            AgentContext.EmailRef(accountID: $0.accountID, threadID: $0.id)
        }, topic: title)
        return Turn(reply: reply, artifacts: [artifact], suggestions: emailSuggestions)
    }

    private func emailUnread(context: inout AgentContext) -> Turn {
        guard let gmail else { return gmailUnavailable() }
        let summary = GmailAgentReader.unread(gmail)
        return emailListTurn(summary.threads, title: "UNREAD EMAIL",
                             reply: summary.reply, context: &context,
                             note: "Answered from the local cache. No message content was sent anywhere.")
    }

    private func emailAttention(context: inout AgentContext) -> Turn {
        guard let gmail else { return gmailUnavailable() }
        let items = GmailAgentReader.attention(source: gmail)
        guard !items.isEmpty else {
            return emailListTurn([], title: "NEEDS ATTENTION",
                                 reply: "Nothing in your inbox is asking for a decision right now.",
                                 context: &context)
        }
        let reasons = Dictionary(uniqueKeysWithValues: items.map { ($0.thread.id, $0.reason) })
        let reply = "\(items.count) conversation\(items.count == 1 ? "" : "s") need attention. "
            + "Ranked locally by unread, stars, questions and deadlines."
        return emailListTurn(items.map(\.thread), title: "NEEDS ATTENTION",
                             reply: reply, context: &context, reasons: reasons)
    }

    private func emailSummarize(_ selector: AgentEmailSelector,
                                context: inout AgentContext) -> Turn {
        switch resolveEmail(selector, context: &context) {
        case .none:
            return Turn(reply: "Open or search for a conversation first.",
                        suggestions: emailSuggestions)
        case .many(let threads):
            return emailListTurn(threads, title: "SUMMARIZE WHICH?",
                                 reply: "Which conversation should I summarize?",
                                 context: &context)
        case .one(let account, let thread):
            let insight = GmailInsight.insight(for: thread, accountID: account.id)
            let artifact = AgentArtifactBuilder.emailThread(
                thread, account: account, insight: insight.summary,
                commitments: insight.commitments,
                note: "Summarized locally from the cached messages.")
            return Turn(reply: "Summary · \(thread.summary.displaySubject).",
                        artifacts: [artifact],
                        suggestions: ["Reply to this email", "What did they promise?",
                                      "Which emails need my attention?"])
        }
    }

    private func emailConversation(_ person: String, context: inout AgentContext) -> Turn {
        guard let gmail else { return gmailUnavailable() }
        let threads = GmailAgentReader.conversation(person, source: gmail)
        let title = "WITH \(person.uppercased())"
        if threads.isEmpty {
            return emailListTurn([], title: title,
                                 reply: "I couldn't find an email conversation with \(person) in the local cache.",
                                 context: &context)
        }
        return emailListTurn(threads, title: title,
                             reply: "\(threads.count) conversation\(threads.count == 1 ? "" : "s") with \(person), newest first.",
                             context: &context)
    }

    private func emailCommitments(_ person: String?, context: inout AgentContext) -> Turn {
        guard let gmail else { return gmailUnavailable() }
        let items = GmailAgentReader.commitments(person: person, source: gmail)
        let title = person.map { "COMMITMENTS · \($0.uppercased())" } ?? "EMAIL COMMITMENTS"
        let artifact = AgentArtifactBuilder.emailCommitments(
            items, title: title,
            note: "Extracted locally from message text; every quote is verbatim.")
        let refs = items.reduce(into: [AgentContext.EmailRef]()) { result, item in
            let ref = AgentContext.EmailRef(accountID: item.accountID,
                                            threadID: item.threadID,
                                            messageID: item.messageID)
            if !result.contains(ref) { result.append(ref) }
        }
        context.record(emails: refs)
        let reply = items.isEmpty
            ? "I didn't find a promise or deadline in those emails."
            : "\(items.count) commitment\(items.count == 1 ? "" : "s") found in email."
        return Turn(reply: reply, artifacts: [artifact],
                    suggestions: ["Summarize my unread emails", "Which emails need my attention?"])
    }

    private func emailSearch(_ query: GmailQuery, context: inout AgentContext) -> Turn {
        guard let gmail else { return gmailUnavailable() }
        let threads = gmail.searchThreads(query, accountID: nil, limit: 20)
        var title = "EMAIL SEARCH"
        if let from = query.from { title = "FROM \(from.uppercased())" }
        else if let subject = query.subject { title = "SUBJECT · \(subject.uppercased())" }
        else if !query.text.isEmpty { title = "“\(query.text.uppercased())”" }
        let reply: String
        if threads.isEmpty {
            reply = "No email matches \(query.text.isEmpty ? "that filter" : "“\(query.text)”") in the local cache."
        } else {
            reply = "\(threads.count) conversation\(threads.count == 1 ? "" : "s") found locally."
        }
        return emailListTurn(threads, title: title, reply: reply, context: &context,
                             note: "Searched subject, sender, recipients and message text on this Mac.")
    }

    private enum EmailResolution {
        case one(GmailAccount, GmailThread)
        case many([GmailThreadSummary])
        case none
    }

    private func resolveEmail(_ selector: AgentEmailSelector,
                              context: inout AgentContext) -> EmailResolution {
        guard let gmail else { return .none }
        func load(_ ref: AgentContext.EmailRef) -> EmailResolution {
            guard let account = gmail.account(ref.accountID),
                  let thread = gmail.thread(accountID: ref.accountID, threadID: ref.threadID) else {
                return .none
            }
            return .one(account, thread)
        }
        switch selector {
        case .id(let accountID, let threadID):
            return load(AgentContext.EmailRef(accountID: accountID, threadID: threadID))
        case .current:
            guard let last = context.lastEmail else { return .none }
            return load(last)
        case .ordinal(let index):
            guard !context.emailRefs.isEmpty else { return .none }
            let resolved = index == -1 ? context.emailRefs.count - 1 : index - 1
            guard context.emailRefs.indices.contains(resolved) else { return .none }
            return load(context.emailRefs[resolved])
        case .query(let raw):
            let threads = GmailAgentReader.conversation(raw, source: gmail)
            guard !threads.isEmpty else { return .none }
            if threads.count == 1, let first = threads.first {
                return load(AgentContext.EmailRef(accountID: first.accountID,
                                                  threadID: first.id))
            }
            return .many(threads)
        }
    }

    private func emailOpen(_ selector: AgentEmailSelector,
                           context: inout AgentContext) -> Turn {
        guard gmail != nil else { return gmailUnavailable() }
        switch resolveEmail(selector, context: &context) {
        case .none:
            return Turn(reply: "I couldn't find that email in the local cache.",
                        suggestions: emailSuggestions)
        case .many(let threads):
            return emailListTurn(threads, title: "WHICH CONVERSATION?",
                                 reply: "Several conversations match. Pick one.",
                                 context: &context)
        case .one(let account, let thread):
            let ref = AgentContext.EmailRef(accountID: account.id, threadID: thread.id)
            context.focus(email: ref)
            let insight = GmailInsight.insight(for: thread, accountID: account.id)
            let artifact = AgentArtifactBuilder.emailThread(
                thread, account: account, insight: insight.summary,
                commitments: insight.commitments)
            return Turn(reply: "\(thread.summary.displaySubject) · \(thread.summary.messageCount) message\(thread.summary.messageCount == 1 ? "" : "s").",
                        artifacts: [artifact],
                        navigation: .mail(accountID: account.id, threadID: thread.id),
                        suggestions: ["Reply to this email", "Summarize this conversation",
                                      "What did they promise?"])
        }
    }

    private func emailDraftReply(_ selector: AgentEmailSelector, all: Bool,
                                 context: inout AgentContext) -> Turn {
        guard gmail != nil else { return gmailUnavailable() }
        switch resolveEmail(selector, context: &context) {
        case .none:
            return Turn(reply: "Open or search for the email you want to answer first.",
                        suggestions: emailSuggestions)
        case .many(let threads):
            return emailListTurn(threads, title: "REPLY TO WHICH?",
                                 reply: "Which conversation should the reply go to?",
                                 context: &context)
        case .one(let account, let thread):
            guard let message = thread.orderedMessages.last else {
                return Turn(reply: "That thread has no message to reply to.")
            }
            let draft = GmailCompose.reply(thread: thread, message: message,
                                           account: account, all: all)
            return proposeEmailDraft(draft, account: account, context: &context)
        }
    }

    private func emailCompose(to: String?, subject: String, body: String?,
                              context: inout AgentContext) -> Turn {
        guard let gmail else { return gmailUnavailable() }
        guard let account = context.lastEmail.flatMap({ gmail.account($0.accountID) })
                ?? gmail.accounts.first else {
            return gmailUnavailable()
        }
        var recipients: [GmailAddress] = []
        if let to, !to.isEmpty {
            if to.contains("@") {
                recipients = [GmailAddress(raw: to)]
            } else {
                recipients = GmailMeetingBridge.addresses(for: [to], source: gmail,
                                                          accountID: account.id)
                if recipients.isEmpty {
                    recipients = [GmailAddress(name: to, email: "")]
                }
            }
        }
        let draft = GmailCompose.new(account: account, to: recipients,
                                     subject: subject, body: body ?? "")
        return proposeEmailDraft(draft, account: account, context: &context)
    }

    private func emailFollowUp(_ selector: AgentMeetingSelector,
                               context: inout AgentContext) -> Turn {
        guard let gmail else { return gmailUnavailable() }
        switch resolveMeeting(selector, context: context) {
        case .none:
            return Turn(reply: "I couldn't find that meeting.",
                        suggestions: ["Show my recent meetings", "Open my inbox"])
        case .many(let meetings):
            return Turn(reply: "Which meeting should the follow-up cover?",
                        artifacts: [meetingListArtifact(meetings, title: "FOLLOW UP WITH WHICH MEETING?")])
        case .one(let meeting):
            let related = GmailMeetingBridge.relatedThreads(
                for: meeting, source: gmail, limit: 1).first
            guard let account = related.flatMap({ gmail.account($0.accountID) })
                    ?? gmail.accounts.first else { return gmailUnavailable() }
            let draft = GmailCompose.followUp(meeting: meeting, source: gmail, account: account)
            return proposeEmailDraft(draft, account: account, context: &context,
                                     note: "Built from the meeting summary, decisions and action items.")
        }
    }

    private func proposeEmailDraft(_ draft: GmailDraft, account: GmailAccount,
                                   context: inout AgentContext,
                                   note: String? = nil) -> Turn {
        let operation = AgentOperation.createDraft(draft, accountEmail: account.email)
        let artifact = AgentArtifactBuilder.emailDraft(
            draft, accountEmail: account.email,
            note: note ?? "Nothing is sent. EXECUTE saves this as a Gmail draft you can edit.")
        return Turn(reply: "Draft prepared. It is a proposal until you press EXECUTE; sending always needs a separate confirmation.",
                    artifacts: [artifact], operations: [operation],
                    suggestions: ["Open my drafts", "Summarize my unread emails"])
    }

    private enum EmailActionKind {
        case archive
        case trash
        case read(Bool)
        case label([String], add: Bool)
    }

    private func emailSuggestLabels(_ selector: AgentEmailSelector,
                                    context: inout AgentContext) -> Turn {
        guard let gmail else { return gmailUnavailable() }
        let threads: [GmailThreadSummary]
        switch resolveEmail(selector, context: &context) {
        case .none:
            return Turn(reply: "Open or search for a conversation first.",
                        suggestions: emailSuggestions)
        case .one(_, let thread):
            threads = [thread.summary]
        case .many(let found):
            threads = found
        }
        guard let first = threads.first else { return Turn(reply: "No email selected.") }
        let text = threads.map { $0.subject + " " + $0.snippet }
            .joined(separator: " ").lowercased()
        var suggestions: [String] = []
        for label in gmail.labels(accountID: first.accountID) where label.isUserLabel {
            if text.contains(label.name.lowercased()) { suggestions.append(label.name) }
        }
        let heuristics: [(String, [String])] = [
            ("Finance", ["invoice", "payment", "receipt", "billing", "pricing", "quote"]),
            ("Legal", ["contract", "agreement", "terms", "legal", "signature"]),
            ("Meetings", ["meeting", "sync", "agenda", "calendar"]),
            ("Newsletters", ["newsletter", "digest", "unsubscribe"]),
            ("Follow Up", ["?", "asap", "deadline", "follow up", "blocked"])
        ]
        for (name, needles) in heuristics
        where needles.contains(where: { text.contains($0) }) {
            if !suggestions.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                suggestions.append(name)
            }
        }
        suggestions = Array(suggestions.prefix(4))
        context.record(emails: threads.map {
            AgentContext.EmailRef(accountID: $0.accountID, threadID: $0.id)
        })
        let reply = suggestions.isEmpty
            ? "No strong label signal in \(first.displaySubject)."
            : "Suggested labels for \(first.displaySubject): \(suggestions.joined(separator: ", ")). Nothing was applied."
        return Turn(reply: reply, suggestions: emailSuggestions)
    }

    private func emailAction(_ selector: AgentEmailSelector?, action: EmailActionKind,
                             context: inout AgentContext) -> Turn {
        guard let gmail else { return gmailUnavailable() }
        let threads: [GmailThreadSummary]
        if let selector {
            switch resolveEmail(selector, context: &context) {
            case .none:
                return Turn(reply: "I couldn't find the email to change.")
            case .one(_, let thread):
                threads = [thread.summary]
            case .many(let found):
                threads = found
            }
        } else {
            threads = context.emailRefs.compactMap { ref in
                gmail.summary(accountID: ref.accountID, threadID: ref.threadID)
            }
        }
        guard !threads.isEmpty else {
            return Turn(reply: "Search or open an email first, then say what to do with it.",
                        suggestions: emailSuggestions)
        }

        var operations: [AgentOperation] = []
        for (accountID, group) in Dictionary(grouping: threads, by: \.accountID) {
            guard let account = gmail.account(accountID) else { continue }
            switch action {
            case .archive:
                if let operation = AgentOperation.archiveEmail(group, accountEmail: account.email) {
                    operations.append(operation)
                }
            case .trash:
                if let operation = AgentOperation.trashEmail(group, accountEmail: account.email) {
                    operations.append(operation)
                }
            case .read(let read):
                if let operation = AgentOperation.markEmailRead(group, read: read,
                                                                 accountEmail: account.email) {
                    operations.append(operation)
                }
            case .label(let names, let add):
                let available = gmail.labels(accountID: accountID)
                let ids = names.compactMap { name in
                    available.first {
                        $0.id.caseInsensitiveCompare(name) == .orderedSame
                            || $0.name.caseInsensitiveCompare(name) == .orderedSame
                    }?.id
                }
                if ids.isEmpty {
                    return Turn(reply: "No label named \(names.joined(separator: ", ")) exists in \(account.email).")
                }
                if let operation = AgentOperation.emailLabels(group, labels: ids,
                                                               add: add,
                                                               accountEmail: account.email) {
                    operations.append(operation)
                }
            }
        }
        guard !operations.isEmpty else {
            return Turn(reply: "I couldn't prepare that change.")
        }
        context.record(emails: threads.map {
            AgentContext.EmailRef(accountID: $0.accountID, threadID: $0.id)
        })
        return Turn(reply: "\(operations.count) email change\(operations.count == 1 ? "" : "s") ready for confirmation. Nothing has changed yet.",
                    operations: operations,
                    suggestions: ["Open my inbox", "Which emails need my attention?"])
    }

    private func keywordSearch(_ subject: String, context: inout AgentContext) -> Turn {
        let needle = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return helpTurn() }

        let tasks = matchingTasks(needle, limit: 10, includeDone: true)
        let meetings = matchingMeetings(needle)

        guard !tasks.isEmpty || !meetings.isEmpty else {
            return Turn(reply: "", fallback: true, fallbackQuery: subject)
        }

        var artifacts: [AgentArtifact] = []
        if !meetings.isEmpty {
            artifacts.append(meetingListArtifact(Array(meetings.prefix(6)),
                                                 title: "MEETINGS · “\(needle.uppercased())”"))
        }
        if !tasks.isEmpty {
            artifacts.append(AgentArtifact(.taskList(TaskListArtifact(
                title: "TASKS · “\(needle.uppercased())”", tasks: tasks))))
        }
        context.record(meetings: meetings.map(\.id), last: meetings.first?.id, topic: needle)
        context.record(tasks: tasks.map(\.id))
        if let first = meetings.first { context.focus(meeting: first.id) }

        var parts: [String] = []
        if !meetings.isEmpty {
            parts.append("\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")")
        }
        if !tasks.isEmpty {
            parts.append("\(tasks.count) task\(tasks.count == 1 ? "" : "s")")
        }
        return Turn(reply: "\(parts.joined(separator: " and ")) mention “\(needle)”.",
                    artifacts: artifacts,
                    suggestions: meetings.isEmpty
                        ? ["What's on my todo?", "Show my recent meetings"]
                        : ["Summarize the first one", "What tasks came out of it?",
                           "Play its recording"])
    }

    // MARK: Help

    private func helpTurn() -> Turn {
        Turn(reply: """
        I read your real board and meetings. Try:
        · what's on my todo — task cards with priority and due dates
        · show my recent meetings — open, summarize or play each one
        · summarize yesterday's meeting — decisions, action items and timestamps
        · what tasks came out of it — cross-referenced with real tasks
        · create a reminder to call Sarah tomorrow at 5pm — applied immediately
        """,
             suggestions: ["What's on my todo?", "Show my recent meetings",
                           "Find my last recording", "Summarize yesterday's meeting"])
    }

    /// Follow-ups that are actually available for this meeting. "Play its
    /// recording" is not offered when there is no local file and no server copy.
    private func meetingFollowUps(_ meeting: Meeting) -> [String] {
        var out = ["What tasks came out of it?"]
        if AgentArtifactBuilder.recording(meeting, remotePlayback: remotePlayback).artifactIsPlayable {
            out.append("Play its recording")
        }
        out.append("Show the transcript")
        return out
    }

    private func wantsPlayback(_ text: String) -> Bool {
        let t = AgentPlanner.normalize(text)
        return t.hasPrefix("play") || t.contains("play ") || t.hasPrefix("listen")
            || t.contains("play the") || t.contains("play my")
    }

    private func emptyMeetingReply(_ selector: AgentMeetingSelector, subject: String) -> String {
        switch selector {
        case .day(let date):
            return "No meetings on \(DateInput.shortLabel(date))."
        case .query(let query):
            return "I couldn't find a meeting about “\(query)”."
        default:
            return "No meeting to \(subject)."
        }
    }

    // MARK: Resolution

    private enum Resolution<Value> {
        case one(Value)
        case many([Value])
        case none
    }

    private func resolveMeeting(_ selector: AgentMeetingSelector,
                                context: AgentContext) -> Resolution<Meeting> {
        let all = store.meetings.chronological()
        switch selector {
        case .id(let id):
            if let meeting = store.meeting(id) { return .one(meeting) }
            return .none
        case .current:
            if let id = context.lastMeetingID, let meeting = store.meeting(id) { return .one(meeting) }
            // A list of meetings focuses the most recent one, so "summarize it"
            // after "show my recent meetings" has a real antecedent.
            if let id = context.meetingIDs.first, let meeting = store.meeting(id) {
                return .one(meeting)
            }
            if all.count == 1 { return .one(all[0]) }
            return .none
        case .latest:
            if let latest = all.first { return .one(latest) }
            return .none
        case .ordinal(let index):
            let listed = context.meetingIDs.compactMap { store.meeting($0) }
            let source = listed.isEmpty ? all : listed
            guard !source.isEmpty else { return .none }
            let position = index < 0 ? source.count - 1 : index - 1
            guard source.indices.contains(position) else { return .none }
            return .one(source[position])
        case .day(let date):
            let meetings = all.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: date) }
            return resolution(meetings)
        case .thisWeek:
            return resolution(all.filter { isInWindow($0.startedAt, .thisWeek) })
        case .lastWeek:
            return resolution(all.filter { isInWindow($0.startedAt, .lastWeek) })
        case .query(let query):
            return resolution(matchingMeetings(query))
        case .any:
            if let latest = all.first { return .one(latest) }
            return .none
        }
    }

    private func resolveMeetings(_ selector: AgentMeetingSelector,
                                 context: AgentContext) -> [Meeting] {
        switch resolveMeeting(selector, context: context) {
        case .one(let meeting): return [meeting]
        case .many(let meetings): return meetings
        case .none: return []
        }
    }

    private func resolution<Value>(_ values: [Value]) -> Resolution<Value> {
        if values.isEmpty { return .none }
        if values.count == 1 { return .one(values[0]) }
        return .many(values)
    }

    private func resolveTask(_ selector: AgentTaskSelector,
                             context: AgentContext) -> Resolution<TaskItem> {
        switch selector {
        case .current:
            if let id = context.lastTaskID, let task = store.task(id) { return .one(task) }
            return .none
        case .ordinal(let index):
            let listed = context.taskIDs.compactMap { store.task($0) }
            guard !listed.isEmpty else { return .none }
            let position = index < 0 ? listed.count - 1 : index - 1
            guard listed.indices.contains(position) else { return .none }
            return .one(listed[position])
        case .query(let raw):
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return .none }
            let open = store.tasks.filter { !$0.isArchived && !$0.isDone }
            let all = store.tasks.filter { !$0.isArchived }

            let exact = all.filter { $0.title.caseInsensitiveCompare(query) == .orderedSame }
            if exact.count == 1 { return .one(exact[0]) }
            if exact.count > 1 { return .many(exact) }

            // If more than one title contains the phrase, ask. Preferring a unique
            // prefix here silently picked "API authentication" for "the API task"
            // while another API task was also open.
            for pool in [open, all] {
                let contains = pool.filter {
                    $0.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
                if contains.count == 1 { return .one(contains[0]) }
                if contains.count > 1 { return .many(contains) }
            }
            return .none
        }
    }

    /// One SQLite read per meeting per turn.
    private func transcript(for meeting: Meeting) -> [TranscriptSegment] {
        if !meeting.transcript.isEmpty { return meeting.transcript }
        if let cached = transcriptCache[meeting.id] { return cached }
        let loaded = store.transcript(for: meeting.id)
        transcriptCache[meeting.id] = loaded
        return loaded
    }

    // MARK: Retrieval

    /// Exact phrase first, then independent keywords. Title and summary checks are
    /// cheap; transcripts are only paged in when neither matched, and then only for
    /// the recent window. That keeps a topic search from blocking the board for a
    /// whole library of hour-long meetings.
    private func matchingMeetings(_ query: String) -> [Meeting] {
        let all = store.meetings.chronological()
        let cheap = Array(all.prefix(60)).filter { $0.matches(query: query) }
        if !cheap.isEmpty { return cheap }

        var needles = [query] + AgentText.keywords(query)
        needles = needles.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return [] }

        var out: [Meeting] = []
        for meeting in all.prefix(20) {
            let segments = transcript(for: meeting)
            let hit = segments.contains { segment in
                needles.contains {
                    segment.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
            if hit {
                out.append(meeting)
                if out.count >= 6 { break }
            }
        }
        return out
    }

    private func matchingTasks(_ query: String, limit: Int,
                               includeDone: Bool = false) -> [TaskItem] {
        let exact = store.search(query)
        if !exact.isEmpty { return Array(exact.prefix(limit)) }
        let words = AgentText.keywords(query)
        guard !words.isEmpty else { return [] }
        var seen = Set<UUID>()
        var out: [TaskItem] = []
        for task in store.tasks where !task.isArchived {
            if !includeDone && task.isDone { continue }
            if words.contains(where: { task.matches(query: $0) }),
               seen.insert(task.id).inserted {
                out.append(task)
            }
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: Match helpers

    private func isInWindow(_ date: Date, _ window: AgentMeetingFilter.Window) -> Bool {
        let calendar = Calendar.current
        let now = self.now()
        switch window {
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
            return calendar.isDate(date, inSameDayAs: yesterday)
        case .thisWeek:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return date >= start && date <= now
        case .lastWeek:
            guard let thisStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
                  let lastStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisStart) else {
                return false
            }
            return date >= lastStart && date < thisStart
        }
    }

    // MARK: Public artifact helpers for in-card actions

    public func summaryArtifact(for meetingID: UUID) -> AgentArtifact? {
        guard let meeting = store.meeting(meetingID) else { return nil }
        let transcript = transcript(for: meeting)
        return AgentArtifactBuilder.summary(meeting, transcript: transcript,
                                             relatedTasks: store.tasks(fromMeeting: meeting.id))
    }

    public func recordingArtifact(for meetingID: UUID) -> AgentArtifact? {
        guard let meeting = store.meeting(meetingID) else { return nil }
        return AgentArtifactBuilder.recording(meeting, remotePlayback: remotePlayback)
    }

    public func transcriptArtifact(for meetingID: UUID, query: String? = nil) -> AgentArtifact? {
        guard let meeting = store.meeting(meetingID) else { return nil }
        let all = transcript(for: meeting)
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = needle.isEmpty ? all : all.filter {
            $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return AgentArtifact(.transcript(TranscriptArtifact(
            meeting: meeting, segments: Array(matched.prefix(80)), totalCount: all.count,
            query: needle.isEmpty ? nil : needle)))
    }

    public func actionItemsArtifact(for meetingID: UUID) -> AgentArtifact? {
        guard let meeting = store.meeting(meetingID) else { return nil }
        let pairs = meeting.actionItems.map { ($0, meeting) }
        return AgentArtifactBuilder.actionItems(meeting: meeting, items: pairs,
                                                tasks: store.tasks)
    }

    public func participantsArtifact(for meetingID: UUID) -> AgentArtifact? {
        guard let meeting = store.meeting(meetingID) else { return nil }
        return AgentArtifactBuilder.participants(meeting, items: meeting.actionItems,
                                                 tasks: store.tasks)
    }
}

// MARK: - Convenience

private extension AgentArtifact {
    var artifactIsPlayable: Bool {
        if case .recording(let recording) = payload { return recording.isPlayable }
        return false
    }

    var unavailableReason: String? {
        if case .recording(let recording) = payload { return recording.unavailableReason }
        return nil
    }
}
