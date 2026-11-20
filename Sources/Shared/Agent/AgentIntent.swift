import Foundation

// MARK: - Navigation

/// A destination that already exists in the app. The agent never builds a route of
/// its own; it names one and `AppModel` performs the same move a click would.
public enum AgentNavigation: Equatable, Sendable {
    case meeting(UUID, focus: MeetingFocus?)
    case task(UUID)
    case calendar(UUID?)
    case mail(accountID: UUID?, threadID: String?)
    case mailDraft(UUID)
    case recorder
    case board
}

/// The section a meeting should open on. Mirrors `MeetingDetailView`'s sections.
public enum MeetingFocus: String, Equatable, Sendable, CaseIterable {
    case summary, actionItems, decisions, questions, transcript

    public var label: String {
        switch self {
        case .summary: return "SUMMARY"
        case .actionItems: return "ACTION ITEMS"
        case .decisions: return "DECISIONS"
        case .questions: return "OPEN QUESTIONS"
        case .transcript: return "TRANSCRIPT"
        }
    }
}

// MARK: - Progress

/// Real work stages, reported as they happen. The console renders the label and a
/// skeleton; nothing here is a timer pretending to be progress.
public enum AgentStage: Equatable, Sendable {
    case thinking
    case searching(String)
    case retrieving(String)
    case processing(String)
    case responding
    case done

    public var label: String {
        switch self {
        case .thinking: return "THINKING"
        case .searching(let what): return "SEARCHING \(what.uppercased())"
        case .retrieving(let what): return "RETRIEVING \(what.uppercased())"
        case .processing(let what): return "PROCESSING \(what.uppercased())"
        case .responding: return "RESPONDING"
        case .done: return "DONE"
        }
    }
}

// MARK: - What to look for

public struct AgentTaskFilter: Equatable, Sendable {
    public enum Due: String, Equatable, Sendable { case today, overdue, week, none }

    public var query: String?
    public var status: TaskStatus?
    public var priority: Priority?
    public var due: Due?
    public var tag: String?
    public var includeDone: Bool
    public var limit: Int

    public init(query: String? = nil, status: TaskStatus? = nil, priority: Priority? = nil,
                due: Due? = nil, tag: String? = nil, includeDone: Bool = false,
                limit: Int = 20) {
        self.query = query
        self.status = status
        self.priority = priority
        self.due = due
        self.tag = tag
        self.includeDone = includeDone
        self.limit = limit
    }
}

public struct AgentMeetingFilter: Equatable, Sendable {
    public enum Window: Equatable, Sendable { case today, yesterday, thisWeek, lastWeek }

    public var query: String?
    public var window: Window?
    public var recordingOnly: Bool
    public var limit: Int

    public init(query: String? = nil, window: Window? = nil,
                recordingOnly: Bool = false, limit: Int = 8) {
        self.query = query
        self.window = window
        self.recordingOnly = recordingOnly
        self.limit = limit
    }
}

public enum AgentMeetingSelector: Equatable, Sendable {
    case id(UUID)
    case current
    case latest
    case ordinal(Int)          // 1-based, -1 for the last item
    case day(Date)
    case thisWeek
    case lastWeek
    case query(String)
    case any
}

public enum AgentTaskSelector: Equatable, Sendable {
    case current
    case ordinal(Int)
    case query(String)
}

public enum AgentScheduledSelector: Equatable, Sendable {
    case current
    case next
    case query(String)
}

public enum AgentEmailSelector: Equatable, Sendable {
    case current
    case ordinal(Int)
    case query(String)
    case id(accountID: UUID, threadID: String)
}

// MARK: - Intent

public enum AgentIntent: Equatable, Sendable {
    case help
    case taskList(AgentTaskFilter)
    case meetingList(AgentMeetingFilter)
    case summary(AgentMeetingSelector)
    case recording(AgentMeetingSelector)
    case transcript(AgentMeetingSelector, query: String?)
    case actionItems(AgentMeetingSelector?, window: AgentMeetingFilter.Window?)
    case participants(AgentMeetingSelector)
    case scheduledMeetingList
    case scheduleMeeting(ScheduledMeetingDraft)
    case scheduledBrief(AgentScheduledSelector)
    case openCalendar
    case calendarHelp(String)
    case openMeeting(AgentMeetingSelector)
    case openTask(AgentTaskSelector)
    case openRecorder
    case openMail
    case emailUnread
    case emailAttention
    case emailSummarize(AgentEmailSelector)
    case emailConversation(String)
    case emailCommitments(String?)
    case emailSearch(GmailQuery)
    case emailOpen(AgentEmailSelector)
    case emailDraftReply(AgentEmailSelector, all: Bool)
    case emailCompose(to: String?, subject: String, body: String?)
    case emailFollowUp(AgentMeetingSelector)
    case emailArchive(AgentEmailSelector?)
    case emailTrash(AgentEmailSelector?)
    case emailMarkRead(AgentEmailSelector?, read: Bool)
    case emailLabel(AgentEmailSelector?, labels: [String], add: Bool)
    case emailSuggestLabels(AgentEmailSelector)
    case createTask(title: String, notes: String?, due: String?,
                    priority: Priority?, status: TaskStatus?, tags: [String])
    case renameTask(AgentTaskSelector, title: String)
    case setDue(AgentTaskSelector, due: String)
    case setPriority(AgentTaskSelector, priority: Priority)
    case tagTask(AgentTaskSelector, tags: [String])
    case completeTask(AgentTaskSelector)
    case moveTask(AgentTaskSelector, TaskStatus)
    case archiveTask(AgentTaskSelector)
    case deleteTask(AgentTaskSelector)
    /// Natural-language prose the deterministic parser should not try to outguess.
    /// The model can turn it into several validated operations.
    case askModel(String)
    case keywordSearch(String)

    public var isEmailIntent: Bool {
        switch self {
        case .openMail, .emailUnread, .emailAttention, .emailSummarize,
             .emailConversation, .emailCommitments, .emailSearch, .emailOpen,
             .emailDraftReply, .emailCompose, .emailFollowUp, .emailArchive,
             .emailTrash, .emailMarkRead, .emailLabel, .emailSuggestLabels:
            return true
        default:
            return false
        }
    }

    /// True when the parser could not place the sentence at all. The session may
    /// then ask a model; if there is no model, the console shows its empty state.
    public var isFallback: Bool {
        if case .keywordSearch = self { return true }
        return false
    }
}

// MARK: - Planner

/// Deterministic natural-language routing for the things this app can actually do.
///
/// It is intentionally not a language model: the same sentence always produces the
/// same tool call, references resolve against the stored conversation, and a miss is
/// reported as a miss. A model is only consulted after this says "I don't know".
public enum AgentPlanner {

    public static func plan(_ raw: String, context: AgentContext, now: Date = Date()) -> AgentIntent {
        let text = normalize(raw)
        guard !text.isEmpty else { return .help }

        if isHelp(text) { return .help }

        // A bare "the first one" answers the question the assistant just asked.
        if let index = bareOrdinal(text), let intent = pendingIntent(index, context: context) {
            return intent
        }

        // Scheduling is local and checked before the generic "meeting" rules:
        // "upcoming meetings" is a schedule, not a recorded meeting list.
        if isOpenCalendar(text) { return .openCalendar }
        if isScheduleMeeting(text) {
            switch ScheduledMeetingParser.parse(raw, now: now) {
            case .draft(let draft): return .scheduleMeeting(draft)
            case .missingDateTime:
                return .calendarHelp("Tell me the day and time, for example: schedule a meeting about onboarding with Sarah tomorrow at 2pm for 45 minutes.")
            case .inThePast:
                return .calendarHelp("That time has already passed. Give me a future day and time.")
            }
        }
        if isScheduledBrief(text) {
            return .scheduledBrief(scheduledSelector(text, context: context))
        }
        if isScheduledList(text) { return .scheduledMeetingList }

        // Mail is answered from the local Gmail cache. These phrases are checked
        // before "summary"/"follow-up"/"delete" so an email request is never
        // mistaken for a meeting or task action.
        if let email = GmailAgentPlanner.plan(raw, context: context, now: now) {
            return email
        }

        if isActionItems(text) {
            return .actionItems(meetingReference(text, context: context, allowNone: true),
                                window: window(in: text))
        }
        if isSummary(text) {
            return .summary(meetingReference(text, context: context, defaultToLatest: true) ?? .latest)
        }
        if isTranscript(text) {
            return .transcript(meetingReference(text, context: context, defaultToLatest: true) ?? .latest,
                               query: transcriptQuery(text))
        }
        if isParticipants(text) {
            return .participants(meetingReference(text, context: context, defaultToLatest: true) ?? .latest)
        }
        if isRecording(text) {
            return .recording(meetingReference(text, context: context, defaultToLatest: true) ?? .latest)
        }
        if isOpenRecorder(text) { return .openRecorder }
        if isOpenTask(text) { return .openTask(taskReference(text, context: context)) }
        if isOpenMeeting(text) {
            return .openMeeting(meetingReference(text, context: context, defaultToLatest: true) ?? .latest)
        }
        // Long imperative prose is an LLM-shaped request, not a regex-shaped one:
        // "add these todos … one is X secondly Y then Z". Let the model decompose it
        // into multiple validated create_task actions; short commands stay local.
        if isComplexWriteRequest(text) { return .askModel(raw) }
        if let intent = writeIntent(raw, context: context, now: now) { return intent }

        if isMeetingList(text) {
            return .meetingList(meetingFilter(text, context: context))
        }
        if isTaskList(text) {
            return .taskList(taskFilter(text, context: context))
        }

        return .keywordSearch(searchSubject(text) ?? raw.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Normalisation

    static func normalize(_ raw: String) -> String {
        var text = raw.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "\n", with: " ")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func has(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { phrase in
            // Multi-word phrases are matched literally. Single words must stand
            // alone: "board" must not fire inside "onboarding".
            if phrase.contains(" ") || phrase.contains(":") || phrase.contains("-") {
                return text.contains(phrase)
            }
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            return text.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil
        }
    }

    private static func matches(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern,
                                                        options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    // MARK: Intent detection

    private static func bareOrdinal(_ text: String) -> Int? {
        let pattern = "^(?:the\\s+)?(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|last|latest|\\d+(?:st|nd|rd|th)?)(?:\\s+(?:one|meeting|task|recording|item))?$"
        guard matches(pattern, text) != nil else { return nil }
        if let value = Int(text), value > 0 { return value }
        if text == "last" || text == "latest" { return -1 }
        return ordinal(in: text)
    }

    private static func pendingIntent(_ index: Int, context: AgentContext) -> AgentIntent? {
        if let query = context.pendingQuery {
            switch query {
            case .summary: return .summary(.ordinal(index))
            case .transcript: return .transcript(.ordinal(index), query: nil)
            case .recording: return .recording(.ordinal(index))
            case .actionItems: return .actionItems(.ordinal(index), window: nil)
            case .participants: return .participants(.ordinal(index))
            case .openMeeting: return .openMeeting(.ordinal(index))
            }
        }
        if let action = context.pendingTaskAction {
            switch action {
            case .complete: return .completeTask(.ordinal(index))
            case .archive: return .archiveTask(.ordinal(index))
            case .delete: return .deleteTask(.ordinal(index))
            case .move(let status): return .moveTask(.ordinal(index), status)
            }
        }
        if context.lastFocus == .email {
            if index == -1, let last = context.emailRefs.last {
                return .emailOpen(.id(accountID: last.accountID, threadID: last.threadID))
            }
            if index > 0, index <= context.emailRefs.count {
                return .emailOpen(.ordinal(index))
            }
        }
        return nil
    }

    private static func isOpenCalendar(_ text: String) -> Bool {
        guard has(text, ["open", "go to", "jump to", "show me the calendar", "take me to"]) else {
            return false
        }
        return has(text, ["calendar", "schedule"])
    }

    private static func isScheduleMeeting(_ text: String) -> Bool {
        guard matches(#"^(?:schedule|book|set up|add|create|put)\b.*\b(meeting|call|sync|1:1)\b"#, text) != nil else {
            return false
        }
        return !has(text, ["task", "todo", "remind", "reminder"])
    }

    private static func isScheduledBrief(_ text: String) -> Bool {
        if has(text, ["prepare me", "prep me", "brief me", "brief for", "pre-meeting",
                      "pre meeting", "prep for"]) { return true }
        return has(text, ["what should i know about", "what do i need to know"])
            && has(text, ["meeting", "calendar", "next"])
    }

    private static func isScheduledList(_ text: String) -> Bool {
        if has(text, ["calendar", "scheduled meeting", "scheduled meetings", "upcoming meeting",
                      "upcoming meetings", "my schedule", "my agenda", "next meeting"]) {
            return true
        }
        return false
    }

    private static func scheduledSelector(_ text: String, context: AgentContext)
        -> AgentScheduledSelector {
        if has(text, ["next", "upcoming"]) { return .next }
        if hasPronoun(text) { return .current }
        if let quoted = quotedPhrase(text) { return .query(quoted) }
        if let groups = matches(#"(?:called|named|about|for|on)\s+(.+)$"#, text) {
            let subject = cleanScheduledSubject(cleanSubject(groups[1]))
            if !subject.isEmpty { return .query(subject) }
        }
        return .current
    }

    private static func isHelp(_ text: String) -> Bool {
        let exact: Set<String> = ["hi", "hello", "hey", "help", "?", "commands", "what can you do"]
        if exact.contains(text) { return true }
        return has(text, ["what can you do", "how do i use", "what can i ask", "show commands"])
    }

    private static func isActionItems(_ text: String) -> Bool {
        has(text, ["action item", "action items", "follow-up", "follow up", "follow-ups",
                   "tasks came out", "task came out", "tasks from the meeting",
                   "tasks from that meeting", "tasks from it", "what came out of",
                   "what did we agree to do", "what do we need to do", "takeaways"])
    }

    private static func isSummary(_ text: String) -> Bool {
        if has(text, ["summarize", "summarise", "summary", "recap", "overview of",
                      "what happened", "what did we discuss", "what did we talk about",
                      "what did we decide", "what was decided", "decisions from",
                      "key points", "minutes of"]) { return true }
        // "What was the meeting about?" is a summary request, not a transcript one.
        return matches("\\bwhat\\b.*\\bmeeting\\b.*\\babout\\b", text) != nil
    }

    private static func isTranscript(_ text: String) -> Bool {
        has(text, ["transcript", "what was said", "show the words", "timestamps",
                   "find in the transcript", "search the transcript", "quote"])
    }

    private static func isParticipants(_ text: String) -> Bool {
        has(text, ["participant", "participants", "attendee", "attendees", "who was in",
                   "who attended", "who joined", "people in the meeting", "who was there"])
    }

    private static func isRecording(_ text: String) -> Bool {
        has(text, ["recording", "recordings", "play ", "listen", "audio", "playback"])
            && !has(text, ["recording settings", "record a meeting", "start recording",
                           "start a recording", "new recording"])
    }

    private static func isOpenRecorder(_ text: String) -> Bool {
        has(text, ["record a meeting", "start recording", "start a recording",
                   "new recording", "open the recorder", "open recorder", "record something"])
    }

    private static func isOpenMeeting(_ text: String) -> Bool {
        guard has(text, ["open", "go to", "jump to", "take me to", "navigate to"]) else { return false }
        guard !has(text, ["task", "todo"]) else { return false }
        return has(text, ["meeting", "one", "it", "that", "this"]) || ordinal(in: text) != nil
    }

    private static func isOpenTask(_ text: String) -> Bool {
        guard has(text, ["open", "go to", "jump to", "take me to", "navigate to"]) else { return false }
        return has(text, ["task", "todo", "item"])
    }

    private static func isMeetingList(_ text: String) -> Bool {
        let words = ["meeting", "meetings", "call", "calls", "standup", "stand-up", "sync",
                     "1:1", "one-on-one", "conference", "recordings"]
        guard has(text, words) else { return false }
        // "the meeting on Tuesday" alone is a question about one meeting.
        if isSummary(text) || isTranscript(text) || isParticipants(text) { return false }
        return true
    }

    private static func isTaskList(_ text: String) -> Bool {
        if has(text, ["task", "tasks", "todo", "to do", "todos", "board", "backlog",
                      "overdue", "in progress", "inbox", "active column"]) { return true }
        return has(text, ["what should i do", "what do i need", "what's open", "whats open",
                          "what's next", "whats next", "due today", "due this week",
                          "what did i finish", "what did i complete", "finished today",
                          "completed today"])
    }

    // MARK: Write commands

    /// A multi-clause instruction deserves the model. The threshold keeps ordinary
    /// one-line commands deterministic while a brain dump goes to Gemini.
    private static func isComplexWriteRequest(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0 == " " }).count
        guard words >= 16 else { return false }
        let openers = ["add ", "create ", "make ", "remind ", "note to self",
                       "put ", "plan ", "i need to", "i have to", "we need to",
                       "i want to"]
        return openers.contains { text.hasPrefix($0) }
    }

    private static func writeIntent(_ raw: String, context: AgentContext,
                                     now: Date) -> AgentIntent? {
        let text = normalize(raw)
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))


        if let groups = matches("^(?:create|add|make)\\s+(?:a\\s+|an\\s+|the\\s+)?(?:new\\s+)?(?:task|todo|item)(?:\\s*[:\\-]\\s*|\\s+)(.+)$", original),
           let intent = createTask(groups[1], now: now) {
            return intent
        }
        if let groups = matches("^(?:create|add)\\s+(.+?)\\s+(?:as|to)\\s+(?:a\\s+)?(?:task|todo)$", original),
           let intent = createTask(groups[1], now: now) {
            return intent
        }
        if let groups = matches("^remind me to\\s+(.+)$", original),
           let intent = createTask(groups[1], now: now) {
            return intent
        }
        if let groups = matches("^(?:create|add|set)\\s+(?:a\\s+|an\\s+)?reminder(?:\\s+to|\\s*[:\\-]\\s*|\\s+)(.+)$", original),
           let intent = createTask(groups[1], now: now) {
            return intent
        }
        if let groups = matches("^remind me about\\s+(.+)$", original),
           let intent = createTask(groups[1], now: now) {
            return intent
        }
        if let groups = matches("^note to self[:\\s]+(.+)$", original),
           let intent = createTask(groups[1], now: now) {
            return intent
        }

        if let groups = matches("^(?:move|put|shift)\\s+(?:the\\s+)?(.+?)\\s+(?:to|into|in)\\s+(inbox|todo|to\\s?do|in[\\s-]?progress|progress|active|doing|done|completed)$", text),
           let status = TaskStatus.parse(groups[2].replacingOccurrences(of: "-", with: " ")) {
            return .moveTask(taskReference(groups[1], context: context), status)
        }

        if let groups = matches("^(?:complete|finish|mark)\\b\\s+(?:the\\s+)?(.+?)(?:\\s+as\\s+(?:done|complete|completed))?(?:\\s+(?:done|complete|completed))?$", text) {
            return .completeTask(taskReference(groups[1], context: context))
        }

        if let groups = matches("^(?:archive|hide)\\s+(?:the\\s+)?(.+)$", text) {
            return .archiveTask(taskReference(groups[1], context: context))
        }
        if let groups = matches("^(?:delete|remove|destroy)\\s+(?:the\\s+)?(.+)$", text) {
            return .deleteTask(taskReference(groups[1], context: context))
        }

        if let groups = matches("^rename\\s+(?:the\\s+)?(.+?)\\s+to\\s+(.+)$", original) {
            return .renameTask(taskReference(groups[1], context: context), title: groups[2])
        }
        if let groups = matches("^set\\s+(?:the\\s+)?(?:due(?:\\s+date)?|deadline)\\s+(?:of|for)\\s+(.+?)\\s+to\\s+(.+)$", text) {
            return .setDue(taskReference(groups[1], context: context), due: groups[2])
        }
        if let groups = matches("^set\\s+(?:the\\s+)?priority\\s+(?:of|for)\\s+(.+?)\\s+to\\s+(.+)$", text),
           let priority = Priority.parse(groups[2]) {
            return .setPriority(taskReference(groups[1], context: context), priority: priority)
        }
        if let groups = matches("^make\\s+(.+?)\\s+(?:a\\s+)?(low|medium|med|high|urgent)\\s+priority$", text),
           let priority = Priority.parse(groups[2]) {
            return .setPriority(taskReference(groups[1], context: context), priority: priority)
        }
        if let groups = matches("^(?:tag|label)\\s+(.+?)\\s+with\\s+(.+)$", text) {
            return .tagTask(taskReference(groups[1], context: context), tags: tags(groups[2]))
        }
        if let groups = matches("^add\\s+(?:the\\s+)?tags?\\s+(.+?)\\s+to\\s+(.+)$", text) {
            return .tagTask(taskReference(groups[2], context: context), tags: tags(groups[1]))
        }
        return nil
    }

    private static func createTask(_ body: String, now: Date) -> AgentIntent? {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("to ") { text = String(text.dropFirst(3)) }
        let parsed = QuickParse.parse(text, now: now)
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // "create a task from the meeting" is a request to extract action items, not
        // to create a task literally named "from the meeting".
        let references = ["from the meeting", "from that meeting", "from it", "for the meeting",
                          "from my meeting", "for my meeting"]
        guard !title.isEmpty, !references.contains(title.lowercased()) else { return nil }
        return .createTask(title: title,
                           notes: nil,
                           due: parsed.due.map { DateInput.iso($0) },
                           priority: parsed.priority,
                           status: parsed.status,
                           tags: parsed.tags)
    }

    private static func tags(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ", "))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#. ")) }
            .filter { !$0.isEmpty }
    }

    // MARK: Filters

    private static func taskFilter(_ text: String, context: AgentContext) -> AgentTaskFilter {
        var filter = AgentTaskFilter()
        if has(text, ["overdue", "late", "past due"]) { filter.due = .overdue }
        else if has(text, ["due today", "today's task", "today task", "finish today",
                           "do today", "what should i do today", "what do i need to do today"]) {
            filter.due = .today
        } else if has(text, ["this week", "due this week", "next 7 days", "coming week"]) {
            filter.due = .week
        } else if has(text, ["no due", "without a due", "unscheduled", "no deadline"]) {
            filter.due = AgentTaskFilter.Due.none
        }

        if has(text, ["in progress", "in-progress", "active", "doing", "wip"]) {
            filter.status = .inProgress
        } else if has(text, ["inbox"]) {
            filter.status = .inbox
        } else if has(text, ["done", "completed", "finished", "what did i finish"]) {
            filter.status = .done
            filter.includeDone = true
        } else if has(text, ["todo column", "on my todo", "my todo", "to do list",
                             "next up", "backlog", "todo"]) {
            filter.status = .todo
        }

        if has(text, ["urgent"]) { filter.priority = .urgent }
        else if has(text, ["high priority", "high-priority"]) { filter.priority = .high }
        else if has(text, ["low priority", "low-priority"]) { filter.priority = .low }

        if let groups = matches("tagged\\s+#?(\\w+)", text) ?? matches("#(\\w+)", text) {
            filter.tag = groups[1]
        } else if let groups = matches("(?:task|tasks|todo|todos)\\s+(?:about|matching|containing|named|called)\\s+(.+)$", text) {
            filter.query = cleanSubject(groups[1])
        } else if let groups = matches("^(?:find|search|look for)\\s+(?:the\\s+)?(.+?)\\s+(?:tasks?|todos?)$", text) {
            filter.query = cleanSubject(groups[1])
        } else if let groups = matches("^(?:find|search(?: for)?|look for)\\s+(?:a\\s+|the\\s+|my\\s+)?(?:tasks?|todos?)\\s+(?:about|for|with|matching)?\\s*(.+)$", text) {
            filter.query = cleanSubject(groups[1])
        } else if let quoted = quotedPhrase(text) {
            filter.query = quoted
        } else if let subject = searchSubject(text) {
            filter.query = cleanSubject(subject)
        }

        if filter.status == nil, filter.due == nil, filter.priority == nil,
           filter.tag == nil, filter.query == nil {
            filter.includeDone = false
        }
        if has(text, ["all tasks", "everything", "full board"]) { filter.includeDone = true }
        filter.limit = has(text, ["all ", "everything"]) ? 60 : 20
        _ = context
        return filter
    }

    private static func meetingFilter(_ text: String, context: AgentContext) -> AgentMeetingFilter {
        var filter = AgentMeetingFilter()
        filter.window = window(in: text)
        filter.recordingOnly = has(text, ["recording", "recordings", "audio", "played"])
        filter.limit = has(text, ["all ", "everything"]) ? 40 : 8
        if let groups = matches("(?:meetings?|calls?)\\s+(?:about|for|with|matching|containing|called|named)\\s+(.+)$", text) {
            filter.query = cleanSubject(groups[1])
        } else if let groups = matches("^(?:find|search|look for)\\s+(?:a\\s+|the\\s+|my\\s+)?(?:meetings?|calls?)\\s+(?:about|for|with|matching)?\\s*(.+)$", text) {
            filter.query = cleanSubject(groups[1])
        } else if let quoted = quotedPhrase(text) {
            filter.query = quoted
        }
        _ = context
        return filter
    }

    private static func window(in text: String) -> AgentMeetingFilter.Window? {
        if has(text, ["yesterday"]) { return .yesterday }
        if has(text, ["today", "this morning", "this afternoon"]) { return .today }
        if has(text, ["last week"]) { return .lastWeek }
        if has(text, ["this week", "past week", "week's meetings", "weeks meetings"]) { return .thisWeek }
        return nil
    }

    // MARK: References

    private static func meetingReference(_ text: String, context: AgentContext,
                                         defaultToLatest: Bool = false,
                                         allowNone: Bool = false) -> AgentMeetingSelector? {
        _ = context
        // Relative windows win over pronouns: "this week's meetings" is a range, not
        // "this meeting".
        if has(text, ["yesterday"]) {
            return .day(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        }
        if has(text, ["today", "this morning", "this afternoon"]) { return .day(Date()) }
        if has(text, ["last week"]) { return .lastWeek }
        if has(text, ["this week", "past week"]) { return .thisWeek }
        if hasPronoun(text) { return .current }
        if let index = ordinal(in: text) { return .ordinal(index) }
        if has(text, ["latest", "last meeting", "most recent", "newest", "recent meeting"]) {
            return .latest
        }
        if let subject = meetingSubject(text) { return .query(subject) }
        if allowNone && !has(text, ["meeting", "call", "standup", "sync"]) { return nil }
        return defaultToLatest ? .latest : .any
    }

    private static func taskReference(_ text: String, context: AgentContext) -> AgentTaskSelector {
        _ = context
        if hasPronoun(text) { return .current }
        if let index = ordinal(in: text) { return .ordinal(index) }
        if let quoted = quotedPhrase(text) { return .query(quoted) }
        if let groups = matches("(?:called|named)\\s+(.+)$", text) {
            return .query(cleanTaskSubject(groups[1]))
        }
        return .query(cleanTaskSubject(text))
    }

    private static func hasPronoun(_ text: String) -> Bool {
        let words = Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted))
        return !words.isDisjoint(with: ["it", "its", "that", "this", "same", "them"])
    }

    /// 1-based index, or -1 for "the last one".
    static func ordinal(in text: String) -> Int? {
        if let groups = matches("\\b(?:the\\s+)?(\\d+)(?:st|nd|rd|th)?\\s+(?:one|meeting|task|todo|item)\\b", text),
           let value = Int(groups[1]), value > 0 {
            return value
        }
        if let groups = matches("\\b(?:the\\s+)?(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\\b", text) {
            let words = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
                         "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10]
            return words[groups[1].lowercased()]
        }
        if matches("\\b(?:the\\s+)?(last|latest|final)\\s+(?:one|meeting|task|item)\\b", text) != nil {
            return -1
        }
        // A bare "the second one" with punctuation stripped still lands above; a
        // bare ordinal like "second" is useful in short follow-ups.
        if let groups = matches("^(?:the\\s+)?(first|second|third|fourth|fifth)$", text) {
            let words = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5]
            return words[groups[1].lowercased()]
        }
        return nil
    }

    private static func meetingSubject(_ text: String) -> String? {
        if let quoted = quotedPhrase(text) { return quoted }
        for pattern in [
            "(?:meeting|calls?)\\s+(?:about|on|for|covering|discussing)\\s+(.+)$",
            "(?:who was in|who attended|who joined)\\s+(?:the\\s+)?(.+)$",
            "(?:summarize|summarise|summary of|recap of|transcript of|recording of|open)\\s+(?:the\\s+)?(?:meeting\\s+)?(?:called|named|about|on)?\\s*(.+)$",
            "(?:about|regarding)\\s+(.+)$"
        ] {
            if let groups = matches(pattern, text) {
                let subject = cleanSubject(groups[1])
                if !subject.isEmpty { return subject }
            }
        }
        return nil
    }

    private static func transcriptQuery(_ text: String) -> String? {
        if let quoted = quotedPhrase(text) { return quoted }
        for pattern in [
            "transcript\\s+(?:for|about|mentioning|containing|with)\\s+(.+)$",
            "(?:find|search|look for)\\s+(.+?)\\s+in\\s+the\\s+transcript$",
            "where\\s+(?:did\\s+)?(?:we|they|he|she|i)\\s+(?:say|mention|discuss)\\s+(.+)$"
        ] {
            if let groups = matches(pattern, text) {
                let subject = cleanSubject(groups[1])
                if !subject.isEmpty { return subject }
            }
        }
        return nil
    }

    private static func searchSubject(_ text: String) -> String? {
        if let quoted = quotedPhrase(text) { return quoted }
        for pattern in [
            "^(?:find|search(?: for)?|look for|anything about|do i have|what do we know about|tell me about)\\s+(.+)$",
            "^(?:what|who|when|where|why|how)\\s+(?:did|do|does|was|were|is|are)\\s+(?:we|i|they)\\s+(?:decide|discuss|say|agree)\\s+(?:about|on)?\\s*(.+)$"
        ] {
            if let groups = matches(pattern, text) {
                let subject = cleanSubject(groups[1])
                if !subject.isEmpty { return subject }
            }
        }
        return nil
    }

    private static func quotedPhrase(_ text: String) -> String? {
        guard let groups = matches("[\"'](.+?)[\"']", text) else { return nil }
        let value = groups[1].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func cleanSubject(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let leading = ["the meeting ", "meeting ", "the call ", "call "]
        var changed = true
        while changed {
            changed = false
            for filler in leading where text.lowercased().hasPrefix(filler) {
                text = String(text.dropFirst(filler.count))
                changed = true
            }
        }
        let trailing = [" meeting", " call"]
        changed = true
        while changed {
            changed = false
            for filler in trailing where text.lowercased().hasSuffix(filler) {
                text = String(text.dropLast(filler.count))
                changed = true
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func cleanScheduledSubject(_ raw: String) -> String {
        var text = raw
        for filler in ["the ", "my ", "a ", "an "] where text.lowercased().hasPrefix(filler) {
            text = String(text.dropFirst(filler.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func cleanTaskSubject(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let leading = ["the ", "my ", "a ", "an ", "please ", "task ", "todo ", "item "]
        var changed = true
        while changed {
            changed = false
            for filler in leading where text.lowercased().hasPrefix(filler) {
                text = String(text.dropFirst(filler.count))
                changed = true
            }
        }
        let trailing = [" task", " todo", " item", " please"]
        changed = true
        while changed {
            changed = false
            for filler in trailing where text.lowercased().hasSuffix(filler) {
                text = String(text.dropLast(filler.count))
                changed = true
            }
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? raw : cleaned
    }
}
