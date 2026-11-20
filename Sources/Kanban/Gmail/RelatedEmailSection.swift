import SwiftUI

/// Mail that belongs beside a meeting. Used by the meeting result page and by the
/// Meet / calendar detail, so both surfaces speak the same language.
struct RelatedEmailSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    var meeting: Meeting?
    var scheduled: ScheduledMeeting?
    var limit: Int = 5

    private var threads: [GmailThreadSummary] {
        if let meeting {
            return app.mail.relatedThreads(for: meeting, limit: limit)
        }
        if let scheduled {
            return app.mail.relatedThreads(for: scheduled, limit: limit)
        }
        return []
    }

    private var hasAccounts: Bool {
        !app.gmailStore.accounts.isEmpty && !app.mail.isStorageBlocked
    }

    var body: some View {
        if hasAccounts && (meeting != nil || !threads.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    MicroLabel("related email")
                    Spacer()
                    if meeting != nil {
                        Button("DRAFT FOLLOW-UP") {
                            if let meeting { app.mail.composeFollowUp(for: meeting) }
                        }
                        .buttonStyle(PanelButtonStyle(compact: true))
                    } else if scheduled != nil {
                        Button("DRAFT AGENDA EMAIL") {
                            if let scheduled { app.mail.composeFollowUp(for: scheduled) }
                        }
                        .buttonStyle(PanelButtonStyle(compact: true))
                    }
                }
                if threads.isEmpty {
                    Text("No related email in the local cache yet.")
                        .font(Theme.mono(9))
                        .foregroundStyle(theme.inkTertiary)
                }
                ForEach(threads) { thread in
                    Button {
                        app.openMail(accountID: thread.accountID, threadID: thread.id)
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(thread.isUnread ? theme.ink : Color.clear)
                                .frame(width: 5, height: 5)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack {
                                    Text(thread.senderDisplay.uppercased())
                                        .font(Theme.mono(8.5, weight: .semibold))
                                        .foregroundStyle(theme.ink)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(thread.dateLabel)
                                        .font(Theme.mono(7.5))
                                        .foregroundStyle(theme.inkTertiary)
                                }
                                Text(thread.displaySubject)
                                    .font(Theme.display(11))
                                    .foregroundStyle(theme.inkSecondary)
                                    .lineLimit(1)
                                Text(thread.snippet.replacingOccurrences(of: "\n", with: " "))
                                    .font(Theme.display(10))
                                    .foregroundStyle(theme.inkTertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in Mail")
                }
            }
            .padding(.top, 4)
        }
    }
}
