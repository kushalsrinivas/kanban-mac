import AppKit
import SwiftUI

/// The mail workspace: accounts and mailboxes on the left, conversations in the
/// middle, the thread on the right. It follows the same industrial control-panel
/// language as the board and the meeting panes.
struct MailView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @State private var searchField = ""

    var body: some View {
        @Bindable var model = app.mail
        Group {
            if model.isStorageBlocked {
                GmailSecurityGate(model: model)
            } else {
                HStack(spacing: 0) {
                    MailSidebar(model: model)
                        .frame(width: 196)
                    Rectangle().fill(theme.lineStrong).frame(width: Theme.Metric.hairline)
                    VStack(spacing: 0) {
                        MailToolbar(model: model, searchField: $searchField)
                        Rectangle().fill(theme.line).frame(height: Theme.Metric.hairline)
                        MailThreadList(model: model)
                        MailStatusBar(model: model)
                    }
                    .frame(width: 350)
                    Rectangle().fill(theme.lineStrong).frame(width: Theme.Metric.hairline)
                    MailDetailPane(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(theme.paper)
        .sheet(isPresented: $model.showingComposer) {
            if let draft = model.composerDraft {
                MailComposerView(model: model, draft: draft)
                    .environment(app)
            }
        }
        .sheet(isPresented: $model.showingConnectSheet) {
            GmailConnectSheet(model: model)
                .environment(app)
        }
        .confirmationDialog(
            "Disconnect \(model.deletingAccount?.email ?? "this account")?",
            isPresented: Binding(
                get: { model.deletingAccount != nil },
                set: { if !$0 { model.deletingAccount = nil } }),
            titleVisibility: .visible) {
            Button("Disconnect & Delete Local Data", role: .destructive) {
                if let account = model.deletingAccount {
                    Task { await model.disconnect(account) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The refresh token is revoked and removed from the Keychain. Cached messages, "
                 + "drafts and downloaded attachments for this account are deleted from this Mac. "
                 + "The mail stays in Gmail.")
        }
        .onAppear {
            if model.threads.isEmpty, !app.gmailStore.accounts.isEmpty {
                model.reload(reset: true)
            }
        }
        .task { await model.syncIfStale() }
    }
}

// MARK: - Storage security gate

private struct GmailSecurityGate: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let model: MailModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18, weight: .medium))
                Text("MAIL LOCKED")
                    .font(Theme.mono(12, weight: .semibold))
                    .tracking(1.2)
            }
            .foregroundStyle(theme.signal)

            Text(model.storageMessage ?? "FileVault is required before the local mail cache can be opened.")
                .font(Theme.display(13))
                .foregroundStyle(theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                stat("FILEVAULT", value: fileVaultLabel)
                stat("ACCOUNTS", value: "\(app.gmailStore.accounts.count)")
                stat("DRAFTS", value: model.encryptionReady ? "AES-GCM" : "NO KEY")
            }
            .padding(.top, 2)

            HStack(spacing: 8) {
                Button("RECHECK") {
                    model.refreshStorageSecurity()
                    Task { await model.syncIfStale() }
                }
                .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
                Button("OPEN SYSTEM SETTINGS") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PanelButtonStyle(compact: true))
            }

            Text("Drafts and downloaded attachments are encrypted with an AES-GCM key stored in the login Keychain. The SQLite message cache is only opened while FileVault is on, so nothing is shown or synced on an unencrypted disk.")
                .font(Theme.mono(8.5))
                .foregroundStyle(theme.inkTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var fileVaultLabel: String {
        switch model.fileVaultState {
        case .on: return "ON"
        case .off: return "OFF"
        case .unknown: return "UNKNOWN"
        }
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(Theme.mono(7.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(theme.inkTertiary)
            Text(value)
                .font(Theme.mono(10, weight: .medium))
                .foregroundStyle(theme.ink)
        }
        .frame(minWidth: 80)
    }
}

// MARK: - Sidebar

private struct MailSidebar: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let model: MailModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                accounts
                Rule()
                mailboxes
                if !userLabels.isEmpty {
                    Rule()
                    labels
                }
                Spacer(minLength: 12)
            }
            .padding(.top, 8)
        }
        .background(theme.panelAlt)
        .scrollIndicators(.never)
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                MicroLabel("accounts")
                Spacer()
                Button { model.showingConnectSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Connect a Gmail account")
                .accessibilityLabel("Connect a Gmail account")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 3)

            accountRow(id: nil, title: "ALL ACCOUNTS",
                       count: app.gmailStore.accounts.count > 1 ? model.counts.inboxUnread : nil)
            ForEach(app.gmailStore.accounts) { account in
                accountRow(id: account.id, title: account.email.uppercased(),
                           count: app.gmailStore.counts(accountID: account.id).inboxUnread,
                           account: account)
            }
            if app.gmailStore.accounts.isEmpty {
                Button {
                    model.showingConnectSheet = true
                } label: {
                    Text("CONNECT GMAIL")
                        .font(Theme.mono(9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
        }
        .padding(.bottom, 8)
    }

    private func accountRow(id: UUID?, title: String, count: Int?,
                            account: GmailAccount? = nil) -> some View {
        let active = model.accountID == id
        return Button {
            model.setAccount(id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(account?.syncError == nil ? theme.inkTertiary : theme.signal)
                    .frame(width: 4, height: 4)
                Text(title)
                    .font(Theme.mono(8.5, weight: active ? .semibold : .regular))
                    .tracking(0.4)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(Theme.mono(8.5))
                        .monospacedDigit()
                        .foregroundStyle(active ? theme.paper.opacity(0.7) : theme.inkTertiary)
                }
            }
            .foregroundStyle(active ? theme.paper : theme.inkSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(active ? theme.ink : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .contextMenu {
            if let account {
                Button("Disconnect…") { model.deletingAccount = account }
            }
        }
    }

    private var mailboxes: some View {
        VStack(alignment: .leading, spacing: 2) {
            MicroLabel("mailboxes")
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 3)
            ForEach(GmailMailbox.allCases.filter { $0 != .all }) { box in
                mailboxRow(box)
            }
        }
        .padding(.bottom, 6)
    }

    private func mailboxRow(_ box: GmailMailbox) -> some View {
        let active = model.mailbox == box && model.labelID == nil && model.searchText.isEmpty
        let counts = model.counts
        let count: Int? = {
            switch box {
            case .inbox: return counts.inboxTotal
            case .starred: return counts.starred
            case .drafts:
                let local = app.gmailStore.drafts(accountID: model.accountID)
                    .filter { $0.status != .sent }.count
                return max(counts.drafts, local)
            case .spam: return counts.spam
            case .trash: return counts.trash
            case .archive: return counts.archive
            default: return nil
            }
        }()
        return Button { model.setMailbox(box) } label: {
            HStack(spacing: 7) {
                Image(systemName: box.icon)
                    .font(.system(size: 10))
                    .frame(width: 14)
                Text(box.label)
                    .font(Theme.mono(9, weight: active ? .semibold : .regular))
                    .tracking(0.5)
                Spacer(minLength: 2)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(Theme.mono(8.5))
                        .monospacedDigit()
                        .foregroundStyle(active ? theme.paper.opacity(0.7) : theme.inkTertiary)
                }
            }
            .foregroundStyle(active ? theme.paper : theme.inkSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(active ? theme.ink : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(box.label)
    }

    private var userLabels: [GmailLabel] {
        model.labels.filter { $0.isUserLabel && !$0.isCategory }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            MicroLabel("labels")
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 3)
            ForEach(Array(userLabels.enumerated()), id: \.offset) { _, label in
                let active = model.labelID == label.id
                Button { model.setLabel(label.id) } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(label.colorBackground.flatMap { Color(hexString: $0) }
                                  ?? theme.lineStrong)
                            .frame(width: 5, height: 5)
                        Text(label.name.uppercased())
                            .font(Theme.mono(8.5, weight: active ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if label.unreadCount > 0 {
                            Text("\(label.unreadCount)")
                                .font(Theme.mono(8))
                                .monospacedDigit()
                                .foregroundStyle(theme.inkTertiary)
                        }
                    }
                    .foregroundStyle(active ? theme.paper : theme.inkSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(active ? theme.ink : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Toolbar

private struct MailToolbar: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let model: MailModel
    @Binding var searchField: String

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(model.selectedLabelName?.uppercased()
                     ?? (model.searchText.isEmpty ? model.mailbox.label : "SEARCH"))
                    .font(Theme.mono(10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(theme.ink)
                Spacer()
                if model.isSyncing {
                    ProgressView().controlSize(.small)
                }
                Button { Task { await model.syncNow() } } label: {
                    Text("SYNC")
                        .font(Theme.mono(8.5, weight: .semibold))
                }
                .buttonStyle(PanelButtonStyle(compact: true))
                .disabled(app.gmailStore.accounts.isEmpty || model.isSyncing)
                Button { model.composeNew() } label: {
                    Text("COMPOSE")
                        .font(Theme.mono(8.5, weight: .semibold))
                }
                .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
                .disabled(app.gmailStore.accounts.isEmpty)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.inkTertiary)
                TextField("", text: $searchField,
                          prompt: Text("search mail  ·  from:  is:unread  label:")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(theme.inkTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(10))
                    .accessibilityLabel("Search mail")
                    .onSubmit { model.search(searchField) }
                if !searchField.isEmpty {
                    Button {
                        searchField = ""
                        model.search("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.inkTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.panelAlt,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }
}

// MARK: - List

private struct MailThreadList: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let model: MailModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.mailbox == .drafts && !model.drafts.isEmpty {
                    ForEach(model.drafts.filter { $0.status != .sent }) { draft in
                        DraftRow(draft: draft, model: model)
                        Rectangle().fill(theme.line).frame(height: Theme.Metric.hairline)
                    }
                }
                if model.threads.isEmpty && !(model.mailbox == .drafts && !model.drafts.isEmpty) {
                    emptyState
                }
                ForEach(model.threads) { thread in
                    MailThreadRow(thread: thread, model: model)
                    Rectangle().fill(theme.line).frame(height: Theme.Metric.hairline)
                }
                if model.hasMore {
                    Button { model.loadMore() } label: {
                        Text("LOAD MORE")
                            .font(Theme.mono(9, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(theme.inkSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.never)
        .background(theme.panel)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel("mail")
            Text(app.gmailStore.accounts.isEmpty
                 ? "Connect a Gmail account to read, search and draft mail on this Mac."
                 : "No conversations here.")
                .font(Theme.display(12.5))
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if app.gmailStore.accounts.isEmpty {
                Button("CONNECT GMAIL") { model.showingConnectSheet = true }
                    .buttonStyle(PanelButtonStyle(compact: true))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MailThreadRow: View {
    @Environment(\.theme) private var theme
    let thread: GmailThreadSummary
    let model: MailModel

    private var selected: Bool { model.selectedThreadID == thread.id }

    var body: some View {
        Button { model.select(thread: thread) } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(thread.isUnread ? theme.ink : Color.clear)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(thread.senderDisplay.uppercased())
                            .font(Theme.mono(9.5, weight: thread.isUnread ? .semibold : .regular))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(thread.dateLabel)
                            .font(Theme.mono(8.5))
                            .foregroundStyle(theme.inkTertiary)
                            .monospacedDigit()
                    }
                    Text(thread.displaySubject)
                        .font(Theme.display(12, weight: thread.isUnread ? .medium : .regular))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(thread.snippet.replacingOccurrences(of: "\n", with: " "))
                        .font(Theme.display(11))
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if thread.starred {
                            Image(systemName: "star.fill").font(.system(size: 8))
                                .foregroundStyle(theme.inkSecondary)
                        }
                        if thread.hasAttachments {
                            Image(systemName: "paperclip").font(.system(size: 8))
                                .foregroundStyle(theme.inkTertiary)
                        }
                        if thread.messageCount > 1 {
                            Text("\(thread.messageCount)")
                                .font(Theme.mono(8))
                                .foregroundStyle(theme.inkTertiary)
                        }
                        if thread.isDraft {
                            Text("DRAFT")
                                .font(Theme.mono(7.5, weight: .semibold))
                                .foregroundStyle(theme.signal)
                        }
                        Spacer()
                        if let email = model.accountEmails[thread.accountID] {
                            Text(email.uppercased())
                                .font(Theme.mono(7.5))
                                .foregroundStyle(theme.inkTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.selectionFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(thread.starred ? "Unstar" : "Star") { model.toggleStar(thread) }
            Button(thread.isUnread ? "Mark Read" : "Mark Unread") {
                model.markRead(thread, read: thread.isUnread)
            }
            Button("Archive") { model.archive(thread) }
            if model.mailbox != .spam {
                Button("Move to Spam") { model.markSpam(thread) }
            }
            Button("Move to Trash") { model.trash(thread) }
            if model.mailbox == .trash || model.mailbox == .archive
                || model.mailbox == .spam {
                Button("Move to Inbox") { model.moveToInbox(thread) }
            }
            if !model.store.labels(accountID: thread.accountID)
                .filter(\.isUserLabel).isEmpty {
                Menu("Labels") {
                    ForEach(Array(model.store.labels(accountID: thread.accountID)
                        .filter(\.isUserLabel).enumerated()), id: \.offset) { _, label in
                        let applied = thread.labelIDs.contains(label.id)
                        Button(applied ? "Remove \(label.name)" : "Add \(label.name)") {
                            model.applyLabel(label, to: thread, add: !applied)
                        }
                    }
                }
            }
        }
    }
}

private struct DraftRow: View {
    @Environment(\.theme) private var theme
    let draft: GmailDraft
    let model: MailModel

    var body: some View {
        Button { Task { await model.editDraft(draft) } } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.signal)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("DRAFT")
                            .font(Theme.mono(8.5, weight: .semibold))
                            .foregroundStyle(theme.signal)
                        Spacer()
                        Text(GmailFormat.listDate(draft.updatedAt))
                            .font(Theme.mono(8))
                            .foregroundStyle(theme.inkTertiary)
                    }
                    Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                        .font(Theme.display(12, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(draft.recipientLine)
                        .font(Theme.display(11))
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(1)
                    if draft.status == .queued || draft.status == .failed
                        || draft.status == .dirty {
                        Text(draft.status == .failed ? "SEND FAILED"
                             : draft.status == .dirty ? "EDITED LOCALLY" : "QUEUED")
                            .font(Theme.mono(7.5))
                            .foregroundStyle(draft.status == .failed
                                             ? theme.signal : theme.inkTertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { Task { await model.editDraft(draft) } }
            Button("Delete Draft", role: .destructive) {
                Task { await model.deleteDraft(draft) }
            }
        }
    }
}

// MARK: - Status

private struct MailStatusBar: View {
    @Environment(\.theme) private var theme
    let model: MailModel

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(model.isSyncing ? .on : .off)
            Text(model.syncLabel)
                .font(Theme.mono(8.5))
                .foregroundStyle(theme.inkTertiary)
            if let message = model.statusMessage {
                Text("·")
                Text(message.uppercased())
                    .font(Theme.mono(8.5))
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let error = model.error ?? model.sync.lastError ?? model.store.lastError {
                Text(error.uppercased())
                    .font(Theme.mono(8))
                    .foregroundStyle(theme.signal)
                    .lineLimit(1)
                    .help(error)
            }
            Text("\(model.threads.count + model.drafts.count) "
                 + (model.mailbox == .drafts ? "DRAFTS" : "THREADS"))
                .font(Theme.mono(8))
                .foregroundStyle(theme.inkTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.panelAlt)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: Theme.Metric.hairline)
        }
    }
}

// MARK: - Detail

private struct MailDetailPane: View {
    @Environment(\.theme) private var theme
    let model: MailModel

    var body: some View {
        if let thread = model.thread {
            MailThreadView(thread: thread, model: model)
        } else if model.isLoadingThread {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("LOADING CONVERSATION")
                    .font(Theme.mono(9))
                    .foregroundStyle(theme.inkTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                MicroLabel("conversation")
                Text(model.threads.isEmpty ? "Select a conversation." : "Pick a conversation from the list.")
                    .font(Theme.display(14))
                    .foregroundStyle(theme.inkSecondary)
                Text("Mail is cached on this Mac. Search, reading and drafts work offline; "
                     + "sending and Gmail changes are queued when the connection returns.")
                    .font(Theme.display(11.5))
                    .foregroundStyle(theme.inkTertiary)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

private struct MailThreadView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let thread: GmailThread
    let model: MailModel
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.lineStrong).frame(height: Theme.Metric.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(thread.orderedMessages) { message in
                        MailMessageCard(message: message,
                                        account: app.gmailStore.account(thread.accountID),
                                        expanded: expanded.contains(message.id),
                                        onToggle: { toggle(message.id) },
                                        model: model)
                    }
                    relatedMeetings
                    Rectangle().fill(theme.line).frame(height: Theme.Metric.hairline)
                    actionBar
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
        .background(theme.paper)
        .onAppear { if expanded.isEmpty { expanded = Set(thread.messages.map(\.id)) } }
        .onChange(of: thread.id) { _, _ in
            expanded = Set(thread.messages.map(\.id))
        }
        .onChange(of: thread.summary.messageCount) { _, _ in
            expanded = Set(thread.messages.map(\.id))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(thread.summary.displaySubject.uppercased())
                    .font(Theme.display(17, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                Spacer()
                Button {
                    model.toggleStar(thread.summary)
                } label: {
                    Image(systemName: thread.summary.starred ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(thread.summary.starred ? theme.ink : theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .help(thread.summary.starred ? "Unstar" : "Star")
            }
            HStack(spacing: 6) {
                Text("\(thread.summary.messageCount) MESSAGE\(thread.summary.messageCount == 1 ? "" : "S")")
                Text("·")
                Text(thread.summary.participants.prefix(3).map(\.displayName).joined(separator: ", ").uppercased())
                    .lineLimit(1)
                if let account = app.gmailStore.account(thread.accountID) {
                    Text("·")
                    Text(account.email.uppercased())
                        .lineLimit(1)
                }
            }
            .font(Theme.mono(8.5))
            .foregroundStyle(theme.inkTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Button("REPLY") { model.composeReply(all: false) }
                    .buttonStyle(PanelButtonStyle(compact: true))
                Button("REPLY ALL") { model.composeReply(all: true) }
                    .buttonStyle(PanelButtonStyle(compact: true))
                Button("FORWARD") { Task { await model.composeForward() } }
                    .buttonStyle(PanelButtonStyle(compact: true))
                Spacer(minLength: 12)
                Button("ARCHIVE") { model.archive(thread.summary) }
                    .buttonStyle(PanelButtonStyle(compact: true))
                Button("TRASH") { model.trash(thread.summary) }
                    .buttonStyle(PanelButtonStyle(compact: true))
            }
        }
        .padding(.top, 2)
    }

    private var relatedMeetings: some View {
        let participants = thread.summary.participants.flatMap { [$0.name, $0.email] }
        let matches = app.store.meetings.filter { meeting in
            meeting.participants.contains { name in
                participants.contains { value in
                    !value.isEmpty && name.localizedCaseInsensitiveContains(value)
                }
            }
        }.prefix(3)
        return Group {
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    MicroLabel("related meetings")
                    ForEach(Array(matches)) { meeting in
                        Button {
                            app.openMeeting(meeting.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform").font(.system(size: 9))
                                Text(meeting.title)
                                    .font(Theme.mono(9.5))
                                    .lineLimit(1)
                                Text(DateInput.shortLabel(meeting.startedAt))
                                    .font(Theme.mono(8))
                                    .foregroundStyle(theme.inkTertiary)
                                Spacer()
                                Text("OPEN").font(Theme.mono(8, weight: .semibold))
                            }
                            .foregroundStyle(theme.inkSecondary)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

private struct MailMessageCard: View {
    @Environment(\.theme) private var theme
    let message: GmailMessage
    let account: GmailAccount?
    let expanded: Bool
    let onToggle: () -> Void
    let model: MailModel
    @State private var inlineImages: [String: Data] = [:]
    @State private var height: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 8) {
                    Text(initials)
                        .font(Theme.mono(9, weight: .semibold))
                        .foregroundStyle(theme.paper)
                        .frame(width: 24, height: 24)
                        .background(theme.ink, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(theme.inkTertiary)
                            Text(message.from.displayName.uppercased())
                                .font(Theme.mono(9.5, weight: .semibold))
                                .foregroundStyle(theme.ink)
                            Text("<\(message.from.email)>")
                                .font(Theme.mono(8))
                                .foregroundStyle(theme.inkTertiary)
                                .lineLimit(1)
                            Spacer()
                            Text(GmailFormat.fullDate(message.internalDate).uppercased())
                                .font(Theme.mono(8))
                                .foregroundStyle(theme.inkTertiary)
                        }
                        Text("TO \(message.recipientSummary.uppercased())")
                            .font(Theme.mono(7.5))
                            .foregroundStyle(theme.inkTertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if let html = message.bodyHTML, !html.isEmpty {
                    MailHTMLView(html: html, plainText: message.bodyText,
                                 isDark: theme.isDark, inlineImages: inlineImages,
                                 height: $height)
                        .frame(height: min(max(height, 40), 560))
                        .frame(maxWidth: .infinity)
                } else {
                    Text(message.bodyText.isEmpty ? message.snippet : message.bodyText)
                        .font(Theme.display(12.5))
                        .foregroundStyle(theme.ink)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !visibleAttachments.isEmpty {
                    FlowAttachments(attachments: visibleAttachments, model: model)
                }
            } else {
                Text(message.snippet)
                    .font(Theme.display(11.5))
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(theme.panel,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
        .task(id: message.id) {
            guard !message.attachments.filter({ $0.isInline && $0.isImage }).isEmpty else { return }
            inlineImages = await model.inlineImages(for: message)
        }
    }

    private var initials: String {
        let parts = message.from.displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init)
        return letters.isEmpty
            ? String(message.from.email.prefix(2)).uppercased()
            : letters.joined().uppercased()
    }

    private var visibleAttachments: [GmailAttachment] {
        message.attachments.filter { !$0.isInline || $0.contentID == nil }
    }
}

private struct FlowAttachments: View {
    @Environment(\.theme) private var theme
    let attachments: [GmailAttachment]
    let model: MailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(attachments) { attachment in
                Button { Task { await model.download(attachment) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: attachment.isImage ? "photo" : "paperclip")
                            .font(.system(size: 9))
                        Text(attachment.filename)
                            .font(Theme.mono(9))
                            .lineLimit(1)
                        Text(attachment.sizeLabel.uppercased())
                            .font(Theme.mono(7.5))
                            .foregroundStyle(theme.inkTertiary)
                        Spacer()
                        Text("SAVE")
                            .font(Theme.mono(7.5, weight: .semibold))
                    }
                    .foregroundStyle(theme.inkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.panelAlt,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Download \(attachment.filename)")
            }
        }
    }
}

// MARK: - Hex colors from Gmail labels

private extension Color {
    init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(hex: number)
    }
}
