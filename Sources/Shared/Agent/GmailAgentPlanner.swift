import Foundation

/// Natural-language routes into the local Gmail cache. Kept out of `AgentPlanner`
/// only because mail has enough vocabulary of its own; the planner still calls this
/// before its task and meeting rules.
enum GmailAgentPlanner {

    static func plan(_ raw: String, context: AgentContext, now: Date) -> AgentIntent? {
        let text = AgentPlanner.normalize(raw)
        guard !text.isEmpty else { return nil }
        if isTaskCreation(text) { return nil }

        if isOpenMail(text) { return .openMail }

        if mentionsEmail(text), has(text, ["today", "this morning", "today's emails",
                                           "todays emails"]) {
            var query = GmailQuery()
            query.newerThan = Calendar.current.startOfDay(for: now)
            return .emailSearch(query)
        }
        if mentionsEmail(text), has(text, ["yesterday", "yesterday's emails"]) {
            var query = GmailQuery()
            let start = Calendar.current.startOfDay(for: now)
            query.newerThan = Calendar.current.date(byAdding: .day, value: -1, to: start)
            query.olderThan = start
            return .emailSearch(query)
        }
        if isAttention(text) { return .emailAttention }
        if isUnreadSummary(text) { return .emailUnread }
        if context.lastFocus == .email,
           has(text, ["summarize", "summarise", "summary", "recap"]),
           let index = ordinal(in: text) {
            return .emailSummarize(.ordinal(index))
        }
        if context.lastFocus == .email, has(text, ["reply to the", "reply to that"]),
           let index = ordinal(in: text) {
            return .emailDraftReply(.ordinal(index), all: false)
        }
        if isEmailSummary(text, context: context) {
            return .emailSummarize(selector(text, context: context) ?? .current)
        }
        if isCommitments(text) {
            return .emailCommitments(person(in: text))
        }

        if isMeetingFollowUp(text) {
            return .emailFollowUp(meetingSelector(text))
        }

        if let compose = composeEmail(text) { return compose }
        if isDraftReply(text) {
            return .emailDraftReply(selector(text, context: context) ?? .current,
                                    all: text.contains("reply all"))
        }
        if isFollowUpWithPerson(text), let name = person(in: text) {
            return .emailDraftReply(.query(name), all: false)
        }

        if has(text, ["suggest label", "suggest labels", "suggest a label",
                      "what label", "which label", "label suggestion"]) {
            return .emailSuggestLabels(selector(text, context: context) ?? .current)
        }
        if let action = emailAction(text, context: context) { return action }

        if mentionsEmail(text) {
            let boxes: [(GmailMailbox, [String])] = [
                (.sent, ["sent emails", "sent mail", "in sent"]),
                (.drafts, ["drafts", "draft emails"]),
                (.spam, ["spam"]),
                (.trash, ["trash", "deleted emails"])
            ]
            for (box, phrases) in boxes where has(text, phrases) {
                var query = GmailQuery()
                query.mailbox = box
                return .emailSearch(query)
            }
        }
        if mentionsEmail(text), has(text, ["starred"]) {
            var query = GmailQuery()
            query.starred = true
            return .emailSearch(query)
        }
        if mentionsEmail(text),
           has(text, ["what emails", "which emails", "list my emails",
                      "show my emails", "my recent emails", "recent emails",
                      "my emails", "my inbox"]) {
            return .emailSearch(GmailQuery())
        }

        if let person = conversationPerson(text) {
            return .emailConversation(person)
        }

        if let query = emailSearch(text) { return .emailSearch(query) }

        if let ordinal = ordinal(in: text),
           has(text, ["open", "show", "go to", "jump to", "take me to"]),
           (mentionsEmail(text) || context.lastFocus == .email) {
            return .emailOpen(.ordinal(ordinal))
        }
        if mentionsEmail(text), has(text, ["open", "show", "go to", "jump to"]),
           (has(text, ["that", "this", "last", "it"]) || context.lastEmail != nil) {
            return .emailOpen(.current)
        }
        if context.lastFocus == .email,
           has(text, ["open it", "open that", "show it", "show that", "go back to it"]) {
            return .emailOpen(.current)
        }

        return nil
    }

    // MARK: vocabulary

    private static func mentionsEmail(_ text: String) -> Bool {
        has(text, ["email", "emails", "inbox", "gmail", "mail", "thread", "threads"])
    }

    private static func isTaskCreation(_ text: String) -> Bool {
        guard has(text, ["task", "todo", "reminder"]) else { return false }
        return has(text, ["create", "add", "make", "remind", "note to self"])
    }

    private static func isOpenMail(_ text: String) -> Bool {
        guard has(text, ["open", "go to", "jump to", "take me to", "show"]) else { return false }
        // "Open the second email" names a thread; "open my inbox" opens the mailbox.
        guard !has(text, ["this email", "that email", "the email", "first email",
                          "second email", "third email", "last email", "latest email",
                          "email thread", "email from", "email about", "email where",
                          "emails with", "emails from", "emails about", "emails where",
                          "conversation with"]) else { return false }
        return has(text, ["mail", "inbox", "gmail", "email", "emails"])
    }

    private static func isAttention(_ text: String) -> Bool {
        let phrases = ["need my attention", "needs my attention", "needs attention",
                       "important emails", "important email", "triage my inbox",
                       "triage my email", "what should i reply", "what needs a reply",
                       "what needs attention"]
        return has(text, phrases) && (mentionsEmail(text) || text.contains("attention"))
    }

    private static func isUnreadSummary(_ text: String) -> Bool {
        guard mentionsEmail(text) || has(text, ["unread", "inbox"]) else { return false }
        return has(text, ["unread", "summarize my inbox", "summarise my inbox",
                          "summarize my email", "summarise my email", "inbox summary",
                          "what's in my inbox", "whats in my inbox", "catch me up"])
    }

    private static func isEmailSummary(_ text: String, context: AgentContext) -> Bool {
        guard has(text, ["summarize", "summarise", "summary", "recap", "overview",
                         "what is this about", "what's this about"]) else { return false }
        if mentionsEmail(text) { return true }
        guard !has(text, ["task", "todo", "meeting", "calendar", "board"]) else {
            return false
        }
        return context.lastFocus == .email
            && has(text, ["this", "that", "conversation", "thread", "it"])
    }

    private static func isCommitments(_ text: String) -> Bool {
        let patterns = ["promise", "promised", "commitment", "commitments", "committed",
                        "follow through", "what did they say they'd do",
                        "what did they say they would do", "what did he promise",
                        "what did she promise", "what did the client promise"]
        if has(text, patterns) {
            return mentionsEmail(text) || has(text, ["client", "they", "he", "she", "customer"])
                || match(#"what did\s+.+?\s+promise"#, text) != nil
        }
        return match(#"what did\s+.+?\s+promise"#, text) != nil
    }

    private static func isMeetingFollowUp(_ text: String) -> Bool {
        guard has(text, ["follow-up", "follow up", "recap", "thank you note", "thanks email"])
        else { return false }
        guard has(text, ["meeting", "call", "sync", "conversation"]) else { return false }
        return has(text, ["draft", "write", "compose", "prepare", "send", "create"])
    }

    private static func isDraftReply(_ text: String) -> Bool {
        let phrases = ["draft a reply", "draft reply", "write a reply", "compose a reply",
                       "reply to this", "reply to that", "reply to the email",
                       "reply to this email", "reply to that email", "reply to it",
                       "draft a response", "draft an answer", "answer this email",
                       "respond to this email"]
        return has(text, phrases)
    }

    private static func isFollowUpWithPerson(_ text: String) -> Bool {
        has(text, ["follow up with", "follow-up with", "reply to"])
            && mentionsEmail(text)
    }

    private static func composeEmail(_ text: String) -> AgentIntent? {
        // "draft an email to Priya about pricing"
        if let groups = match(#"^(?:draft|write|compose|prepare|create)\s+(?:an?\s+)?email\s+to\s+(.+?)(?:\s+about\s+(.+))?$"#,
                              text) {
            let recipient = cleanName(groups[1])
            let subject = groups.count > 2 ? subjectCase(cleanSubject(groups[2])) : ""
            return .emailCompose(to: recipient.isEmpty ? nil : recipient,
                                 subject: subject, body: nil)
        }
        // "email Priya about pricing" (not "email about pricing")
        if let groups = match(#"^email\s+([^@\s]+(?:@[^\s]+)?)\s+about\s+(.+)$"#, text) {
            return .emailCompose(to: cleanName(groups[1]),
                                 subject: subjectCase(cleanSubject(groups[2])), body: nil)
        }
        // "draft an email about the proposal" (no recipient yet)
        if let groups = match(#"^(?:draft|write|compose|prepare|create)\s+(?:an?\s+)?email\s+about\s+(.+)$"#,
                              text) {
            return .emailCompose(to: nil, subject: subjectCase(cleanSubject(groups[1])), body: nil)
        }
        return nil
    }

    // MARK: actions

    private static func emailAction(_ text: String, context: AgentContext) -> AgentIntent? {
        let explicitMail = mentionsEmail(text)
        if !explicitMail && has(text, ["task", "todo", "meeting", "calendar", "board"]) {
            return nil
        }
        let hasMailContext = explicitMail || context.lastFocus == .email
        guard hasMailContext else { return nil }

        if has(text, ["archive"]) {
            return .emailArchive(selector(text, context: context, pluralNil: true))
        }
        if has(text, ["trash", "delete", "remove"]) {
            return .emailTrash(selector(text, context: context, pluralNil: true))
        }
        if has(text, ["mark", "flagged as"]) && has(text, ["read", "unread"]) {
            return .emailMarkRead(selector(text, context: context, pluralNil: true),
                                  read: !has(text, ["unread"]))
        }
        if has(text, ["label", "tag"]) {
            let labels = labels(in: text)
            if !labels.isEmpty {
                return .emailLabel(selector(text, context: context, pluralNil: true),
                                   labels: labels, add: !has(text, ["remove", "untag"]))
            }
        }
        return nil
    }

    // MARK: people and subjects

    private static func conversationPerson(_ text: String) -> String? {
        let patterns = [
            #"(?:latest|last|recent)\s+(?:email|emails|conversation|thread)\s+(?:with|from)\s+(.+)$"#,
            #"(?:emails?|conversation|thread)\s+(?:with|from)\s+(.+)$"#,
            #"(?:find|show|get)\s+(?:the\s+)?(?:latest|last|recent)?\s*(?:emails?|conversation|thread)\s+(?:with|from)\s+(.+)$"#,
            #"what(?:'s| is) the latest (?:with|from)\s+(.+)$"#
        ]
        for pattern in patterns {
            if let groups = match(pattern, text) {
                let value = cleanName(groups[1])
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func person(in text: String) -> String? {
        if let groups = match(#"(?:with|from|to)\s+(.+?)(?:\?|$)"#, text) {
            let value = cleanName(groups[1])
            if !value.isEmpty, !["the client", "this client", "them", "they", "him", "her"]
                .contains(value.lowercased()) {
                return value
            }
        }
        if let groups = match(#"what did\s+(.+?)\s+promise"#, text) {
            let value = cleanName(groups[1])
            if !["this client", "the client", "client", "they", "he", "she",
                 "the customer", "customer"].contains(value.lowercased()) {
                return value
            }
        }
        return nil
    }

    private static func meetingSelector(_ text: String) -> AgentMeetingSelector {
        if has(text, ["this meeting", "this call", "this one", "it"]) { return .current }
        if has(text, ["last meeting", "latest meeting", "the meeting", "that meeting"]) {
            return .latest
        }
        if let groups = match(#"(?:after|from|about)\s+(?:the\s+)?(.+?)(?:\s+meeting|\s+call)?$"#, text) {
            let value = cleanSubject(groups[1])
            if !value.isEmpty, !["this", "that", "last", "latest"].contains(value.lowercased()) {
                return .query(value)
            }
        }
        return .latest
    }

    private static func emailSearch(_ text: String) -> GmailQuery? {
        let patterns = [
            #"(?:find|search|look for)\s+(?:the\s+)?email\s+(?:where|in which|that)\s+(?:we|i|they|he|she)?\s*(?:discussed|mentioned|talked about|about|said|wrote)\s+(.+)$"#,
            #"(?:find|search|look for)\s+(?:an?\s+)?email\s+about\s+(.+)$"#,
            #"(?:search|look through)\s+(?:my\s+)?emails?\s+for\s+(.+)$"#,
            #"(?:which|what)\s+emails?\s+(?:mentioned|discussed|talked about|contain)\s+(.+)$"#,
            #"emails?\s+about\s+(.+)$"#,
            #"find\s+(?:the\s+)?email\s+from\s+(.+)$"#
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let groups = match(pattern, text) else { continue }
            if index == patterns.count - 1 {
                var query = GmailQuery()
                query.from = cleanName(groups[1])
                return query.from?.isEmpty == false ? query : nil
            }
            let value = cleanSubject(groups[1])
            guard !value.isEmpty else { continue }
            var query = GmailQuery.parse(value)
            if query.text.isEmpty && query.from == nil && query.to == nil { query.text = value }
            return query
        }
        return nil
    }

    private static func labels(in text: String) -> [String] {
        let patterns = [
            #"(?:label|tag)\s+(?:this|these|the|that)?\s*(?:emails?|threads?)?\s*(?:as|with)\s+(.+)$"#,
            #"(?:add|apply)\s+(?:the\s+)?(?:label|tag)\s+(.+?)(?:\s+to\s+(?:this|these|the|that)\s+(?:emails?|threads?))?$"#
        ]
        for pattern in patterns {
            if let groups = match(pattern, text) {
                let values = groups[1]
                    .replacingOccurrences(of: " and ", with: ",")
                    .components(separatedBy: CharacterSet(charactersIn: ",#"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !values.isEmpty { return values }
            }
        }
        return []
    }

    private static func selector(_ text: String, context: AgentContext,
                                 pluralNil: Bool = false) -> AgentEmailSelector? {
        if let index = ordinal(in: text) {
            return .ordinal(index)
        }
        if has(text, ["these", "them", "all of them", "these emails", "these threads"]) {
            return nil
        }
        if has(text, ["this", "that", "it", "the last", "the latest"]) {
            return .current
        }
        _ = context
        return pluralNil ? nil : .current
    }

    // MARK: helpers

    private static func has(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { phrase in
            if phrase.contains(" ") || phrase.contains("-") || phrase.contains("'") {
                return text.contains(phrase)
            }
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            return text.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil
        }
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let found = expression.firstMatch(in: text, range: range) else { return nil }
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func ordinal(in text: String) -> Int? {
        if let groups = match(#"\b(?:the\s+)?(\d+)(?:st|nd|rd|th)?\s+(?:one|email|thread|message|conversation)\b"#, text),
           let value = Int(groups[1]), value > 0 { return value }
        let words = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
                     "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10]
        if let groups = match(#"\b(?:the\s+)?(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\b"#, text) {
            return words[groups[1].lowercased()]
        }
        if has(text, ["last one", "latest one"]) { return -1 }
        return nil
    }

    private static func cleanName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for filler in ["the ", "this ", "that ", "my ", "a ", "an "] where text.lowercased().hasPrefix(filler) {
            text = String(text.dropFirst(filler.count))
        }
        for filler in [" email", " emails", " thread", " conversation", " please",
                       " by"] where text.lowercased().hasSuffix(filler) {
            text = String(text.dropLast(filler.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func subjectCase(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return String(first).uppercased() + String(raw.dropFirst())
    }

    private static func cleanSubject(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let leading = ["the ", "my ", "a ", "an ", "about ", "regarding "]
        var changed = true
        while changed {
            changed = false
            for filler in leading where text.lowercased().hasPrefix(filler) {
                text = String(text.dropFirst(filler.count))
                changed = true
            }
        }
        let trailing = [" email", " emails", " thread", " conversation", " please"]
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
}
