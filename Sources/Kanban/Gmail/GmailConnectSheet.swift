import AppKit
import SwiftUI

/// Guides the one manual step Google requires: creating a desktop OAuth client.
/// Nothing is hardcoded and the client secret, when supplied, goes to the Keychain.
struct GmailConnectSheet: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: MailModel

    @State private var clientID: String
    @State private var clientSecret: String
    @State private var loginHint = ""
    @State private var busy = false
    @State private var error: String?

    init(model: MailModel) {
        self.model = model
        _clientID = State(initialValue: model.settings.gmailClientID)
        _clientSecret = State(initialValue: model.settings.gmailClientSecret)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CONNECT GMAIL")
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(theme.ink)
                Spacer()
                Text("CLIENT-SIDE ONLY")
                    .font(Theme.mono(8))
                    .foregroundStyle(theme.inkTertiary)
            }

            Text("Meet talks to Gmail directly from this Mac. There is no Meet server in the "
                 + "mail path, and no email is sent to an AI service.")
                .font(Theme.display(11.5))
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                MicroLabel("one-time setup")
                bullet("Open Google Cloud Console and create or pick a project.")
                bullet("Enable the Gmail API.")
                bullet("Configure the OAuth consent screen (External is fine; add yourself as a test user).")
                bullet("Create Credentials → OAuth client ID → Desktop app.")
                bullet("Paste the client ID below. The client secret, if Google shows one, is optional and goes to the Keychain.")
            }

            HStack(spacing: 8) {
                Button("OPEN GOOGLE CLOUD CONSOLE") {
                    if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PanelButtonStyle(compact: true))
                Button("OPEN GMAIL API") {
                    if let url = URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PanelButtonStyle(compact: true))
            }

            VStack(alignment: .leading, spacing: 0) {
                field("CLIENT ID", text: $clientID,
                      placeholder: "1234567890-abc.apps.googleusercontent.com")
                Rule()
                field("CLIENT SECRET (OPTIONAL)", text: $clientSecret,
                      placeholder: "GOCSPX-…")
                Rule()
                field("ACCOUNT HINT (OPTIONAL)", text: $loginHint,
                      placeholder: "you@example.com")
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))

            if let error {
                Text(error.uppercased())
                    .font(Theme.mono(9))
                    .foregroundStyle(theme.signal)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text("Redirect: 127.0.0.1 loopback · PKCE · Gmail modify + send only")
                    .font(Theme.mono(8))
                    .foregroundStyle(theme.inkTertiary)
                Spacer()
                Button("CANCEL") { dismiss() }
                    .buttonStyle(PanelButtonStyle(compact: true))
                Button(busy ? "WAITING FOR GOOGLE…" : "CONNECT") {
                    connect()
                }
                .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
                .disabled(busy || clientID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 580, height: 560)
        .background(theme.paper)
        .environment(\.theme, app.theme)
        .preferredColorScheme(app.settings.colorScheme)
        .interactiveDismissDisabled(busy)
    }

    private func field(_ label: String, text: Binding<String>,
                       placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.mono(8.5, weight: .semibold))
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 150, alignment: .leading)
            TextField("", text: text,
                      prompt: Text(placeholder).font(Theme.mono(10))
                        .foregroundStyle(theme.inkTertiary))
                .textFieldStyle(.plain)
                .font(Theme.mono(10))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·")
                .font(Theme.mono(10))
            Text(text)
                .font(Theme.display(11))
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() {
        busy = true
        error = nil
        Task {
            await model.connect(clientID: clientID, clientSecret: clientSecret,
                                loginHint: loginHint.isEmpty ? nil : loginHint)
            busy = false
            if let message = model.error {
                error = message
            } else if !model.showingConnectSheet {
                dismiss()
            }
        }
    }
}
