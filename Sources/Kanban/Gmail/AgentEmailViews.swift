import SwiftUI

// MARK: - Email list

struct EmailListCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let list: EmailListArtifact

    var body: some View {
        ArtifactShell(kind: .emailList, title: list.title,
                      trailing: list.cards.isEmpty ? nil : "\(list.cards.count)",
                      note: list.note) {
            if list.cards.isEmpty {
                EmptyArtifactRow(message: list.emptyMessage)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(list.cards) { card in
                        Button {
                            app.openMail(accountID: card.accountID, threadID: card.thread.id)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(card.thread.isUnread ? theme.ink : Color.clear)
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(card.thread.senderDisplay.uppercased())
                                            .font(Theme.mono(9, weight: .semibold))
                                            .foregroundStyle(theme.ink)
                                            .lineLimit(1)
                                        Spacer(minLength: 2)
                                        Text(card.thread.dateLabel)
                                            .font(Theme.mono(8))
                                            .foregroundStyle(theme.inkTertiary)
                                            .monospacedDigit()
                                    }
                                    Text(card.thread.displaySubject)
                                        .font(Theme.display(12, weight: .medium))
                                        .foregroundStyle(theme.ink)
                                        .lineLimit(1)
                                    Text(card.thread.snippet.replacingOccurrences(of: "\n", with: " "))
                                        .font(Theme.display(10.5))
                                        .foregroundStyle(theme.inkSecondary)
                                        .lineLimit(2)
                                    HStack(spacing: 7) {
                                        if let reason = card.reason, !reason.isEmpty {
                                            Text(reason.uppercased())
                                                .font(Theme.mono(7.5))
                                                .foregroundStyle(theme.signal)
                                        }
                                        Text(card.accountEmail.uppercased())
                                            .font(Theme.mono(7.5))
                                            .foregroundStyle(theme.inkTertiary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("OPEN")
                                            .font(Theme.mono(7.5, weight: .semibold))
                                            .foregroundStyle(theme.inkTertiary)
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if card.id != list.cards.last?.id { ArtifactDivider() }
                    }
                }
            }
        }
    }
}

// MARK: - Thread

struct EmailThreadArtifactCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let value: EmailThreadArtifact

    var body: some View {
        ArtifactShell(kind: .emailThread, title: value.thread.summary.displaySubject,
                      trailing: "\(value.thread.summary.messageCount) MSG",
                      note: value.note) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(value.accountEmail.uppercased())
                        .font(Theme.mono(8))
                        .foregroundStyle(theme.inkTertiary)
                    Text("·")
                    Text(value.thread.summary.participants.prefix(4)
                        .map(\.displayName).joined(separator: ", ").uppercased())
                        .font(Theme.mono(8))
                        .foregroundStyle(theme.inkTertiary)
                        .lineLimit(1)
                }

                if let insight = value.insight, !insight.isEmpty {
                    Text(insight)
                        .font(Theme.display(11.5))
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !value.thread.messages.isEmpty {
                    ForEach(value.thread.orderedMessages.suffix(3)) { message in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(message.from.displayName.uppercased())
                                    .font(Theme.mono(8.5, weight: .semibold))
                                    .foregroundStyle(theme.ink)
                                Spacer()
                                Text(GmailFormat.listDate(message.internalDate))
                                    .font(Theme.mono(7.5))
                                    .foregroundStyle(theme.inkTertiary)
                            }
                            Text(message.snippet)
                                .font(Theme.display(10.5))
                                .foregroundStyle(theme.inkSecondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }

                if !value.commitments.isEmpty {
                    MicroLabel("commitments")
                    ForEach(value.commitments.prefix(3)) { item in
                        HStack(alignment: .top, spacing: 5) {
                            Text("“")
                                .font(Theme.mono(9))
                                .foregroundStyle(theme.inkTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.quote)
                                    .font(Theme.display(10.5))
                                    .foregroundStyle(theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let due = item.dueText {
                                    Text(due.uppercased())
                                        .font(Theme.mono(7.5))
                                        .foregroundStyle(theme.signal)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    ArtifactAction(label: "OPEN IN MAIL", emphasised: true) {
                        app.openMail(accountID: value.accountID,
                                     threadID: value.thread.id)
                    }
                    ArtifactAction(label: "REPLY") {
                        app.mail.composeReply(to: value.thread,
                                              accountID: value.accountID,
                                              all: false)
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Commitments

struct EmailCommitmentsCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let value: EmailCommitmentsArtifact

    var body: some View {
        ArtifactShell(kind: .emailCommitments, title: value.title,
                      trailing: value.commitments.isEmpty ? nil : "\(value.commitments.count)",
                      note: value.note) {
            if value.commitments.isEmpty {
                EmptyArtifactRow(message: value.emptyMessage)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(value.commitments) { item in
                        Button {
                            app.openMail(accountID: item.accountID, threadID: item.threadID)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.quote)
                                    .font(Theme.display(11.5))
                                    .foregroundStyle(theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 6) {
                                    Text(item.sender.uppercased())
                                        .font(Theme.mono(8))
                                        .foregroundStyle(theme.inkSecondary)
                                    Text("·")
                                    Text(item.subject.uppercased())
                                        .font(Theme.mono(8))
                                        .foregroundStyle(theme.inkTertiary)
                                        .lineLimit(1)
                                    Spacer()
                                    if let due = item.dueText {
                                        Text(due.uppercased())
                                            .font(Theme.mono(7.5))
                                            .foregroundStyle(theme.signal)
                                    }
                                    Text(GmailFormat.listDate(item.date))
                                        .font(Theme.mono(7.5))
                                        .foregroundStyle(theme.inkTertiary)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if item.id != value.commitments.last?.id { ArtifactDivider() }
                    }
                }
            }
        }
    }
}

// MARK: - Draft

struct EmailDraftCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let value: EmailDraftArtifact

    var body: some View {
        ArtifactShell(kind: .emailDraft, title: value.draft.subject.isEmpty
                      ? "New email" : value.draft.subject,
                      trailing: "PROPOSED", note: value.note) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FROM \(value.accountEmail.uppercased())")
                    .font(Theme.mono(8))
                    .foregroundStyle(theme.inkTertiary)
                Text("TO \(value.draft.recipientLine.uppercased())")
                    .font(Theme.mono(8))
                    .foregroundStyle(theme.inkSecondary)
                Text(value.draft.bodyText.isEmpty ? "(empty body)" : value.draft.bodyText)
                    .font(Theme.display(11))
                    .foregroundStyle(theme.ink)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing is sent by the agent. EXECUTE saves this to Gmail Drafts; "
                     + "you review and press SEND in the composer.")
                    .font(Theme.mono(8))
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if app.gmailStore.draft(value.draft.id) != nil {
                    ArtifactAction(label: "OPEN DRAFT", emphasised: true) {
                        app.openMailDraft(value.draft.id)
                    }
                }
            }
        }
    }
}
