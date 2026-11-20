import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer is a real rich-text editor, not a plain text box. The HTML it emits
/// is built by the same MIME writer that sends the message, so bold, links, inline
/// images and attachments survive the trip to Gmail.
struct MailComposerView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    let model: MailModel
    @State private var draft: GmailDraft
    @State private var toText: String
    @State private var ccText: String
    @State private var bccText: String
    @State private var subject: String
    @State private var bodyHTML: String
    @State private var bodyText: String
    @State private var editor = RichTextController()
    @State private var showCC = false
    @State private var showBCC = false
    @State private var confirmingSend = false
    @State private var status: String?
    @State private var isSending = false
    @State private var autosaveTask: Task<Void, Never>?

    init(model: MailModel, draft: GmailDraft) {
        self.model = model
        _draft = State(initialValue: draft)
        _toText = State(initialValue: draft.to.map(\.mailbox).joined(separator: ", "))
        _ccText = State(initialValue: draft.cc.map(\.mailbox).joined(separator: ", "))
        _bccText = State(initialValue: draft.bcc.map(\.mailbox).joined(separator: ", "))
        _subject = State(initialValue: draft.subject)
        _bodyHTML = State(initialValue: draft.bodyHTML ?? "")
        _bodyText = State(initialValue: draft.bodyText)
        _showCC = State(initialValue: !draft.cc.isEmpty)
        _showBCC = State(initialValue: !draft.bcc.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            fields
            Rule()
            formatBar
            editorPane
            if !draft.attachments.isEmpty {
                Rule()
                attachmentStrip
            }
            Rule()
            footer
        }
        .frame(width: 760, height: 680)
        .background(theme.paper)
        .environment(\.theme, app.theme)
        .preferredColorScheme(app.settings.colorScheme)
        .interactiveDismissDisabled(true)
        .confirmationDialog("Send this email?",
                            isPresented: $confirmingSend,
                            titleVisibility: .visible) {
            Button("Send", role: .destructive) { send() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From \(fromAccount?.email ?? "this account") to \(recipientSummary). "
                 + "This sends immediately. The agent cannot send mail; only this button can.")
        }
        .onDisappear {
            autosaveTask?.cancel()
            editor.detach()
        }
        .onChange(of: subject) { _, _ in scheduleAutosave() }
        .onChange(of: toText) { _, _ in scheduleAutosave() }
        .onChange(of: ccText) { _, _ in scheduleAutosave() }
        .onChange(of: bccText) { _, _ in scheduleAutosave() }
        .onChange(of: bodyText) { _, _ in scheduleAutosave() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(draft.gmailDraftID == nil ? "NEW MESSAGE" : "EDIT DRAFT")
                .font(Theme.mono(10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(theme.ink)
            if draft.gmailDraftID != nil {
                Text("GMAIL DRAFT")
                    .font(Theme.mono(8.5))
                    .foregroundStyle(theme.inkTertiary)
            }
            Spacer()
            if let status {
                Text(status.uppercased())
                    .font(Theme.mono(8.5))
                    .foregroundStyle(theme.inkSecondary)
            }
            Button("CLOSE") { close() }
            .buttonStyle(PanelButtonStyle(compact: true))
            Button("SAVE DRAFT") { save() }
                .buttonStyle(PanelButtonStyle(compact: true))
            Button(isSending ? "SENDING…" : "SEND") { confirmingSend = true }
                .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
                .disabled(isSending)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            fieldRow("FROM") {
                if app.gmailStore.accounts.count > 1 {
                    Picker("", selection: Binding(
                        get: { draft.accountID },
                        set: { draft.accountID = $0 })) {
                        ForEach(app.gmailStore.accounts) { account in
                            Text(account.email).tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                } else {
                    Text(fromAccount?.email ?? "No account")
                        .font(Theme.mono(11))
                        .foregroundStyle(theme.ink)
                }
            }
            fieldRow("TO") {
                TextField("", text: $toText,
                          prompt: Text("name@example.com, another@example.com")
                            .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(theme.ink)
                    .accessibilityLabel("To")
            }
            if showCC {
                fieldRow("CC") { addressField($ccText) }
            }
            if showBCC {
                fieldRow("BCC") { addressField($bccText) }
            }
            fieldRow("SUBJECT") {
                TextField("", text: $subject,
                          prompt: Text("Subject").font(Theme.mono(11))
                            .foregroundStyle(theme.inkTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.display(12))
                    .foregroundStyle(theme.ink)
                    .accessibilityLabel("Subject")
            }
            HStack(spacing: 10) {
                Spacer().frame(width: 72)
                Button(showCC ? "HIDE CC" : "ADD CC") {
                    showCC.toggle(); if !showCC { ccText = "" }
                }
                .buttonStyle(.plain)
                .font(Theme.mono(8.5))
                .foregroundStyle(theme.inkSecondary)
                Button(showBCC ? "HIDE BCC" : "ADD BCC") {
                    showBCC.toggle(); if !showBCC { bccText = "" }
                }
                .buttonStyle(.plain)
                .font(Theme.mono(8.5))
                .foregroundStyle(theme.inkSecondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        .padding(.vertical, 4)
    }

    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.mono(8.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 62, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func addressField(_ binding: Binding<String>) -> some View {
        TextField("", text: binding,
                  prompt: Text("name@example.com").font(Theme.mono(11))
                    .foregroundStyle(theme.inkTertiary))
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(theme.ink)
            .accessibilityLabel("Email recipients")
    }

    // MARK: Formatting

    private var formatBar: some View {
        HStack(spacing: 4) {
            formatButton("B", help: "Bold") { editor.toggleBold() }
            formatButton("I", help: "Italic") { editor.toggleItalic() }
            formatButton("U", help: "Underline") { editor.toggleUnderline() }
            Rule().frame(width: 1, height: 15)
            formatButton("LINK", help: "Insert link") { editor.insertLink() }
            formatButton("IMAGE", help: "Insert inline image") { chooseImage(inline: true) }
            formatButton("ATTACH", help: "Attach a file") { chooseImage(inline: false) }
            Spacer()
            Text("\(bodyText.count) CHARS")
                .font(Theme.mono(8.5))
                .foregroundStyle(theme.inkTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(theme.panelAlt)
    }

    private func formatButton(_ label: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.mono(9, weight: .semibold))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var editorPane: some View {
        MailRichTextEditor(controller: editor, html: $bodyHTML, text: $bodyText,
                           isDark: theme.isDark,
                           onInsertImage: { url in addAttachment(url: url, inline: true) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.panel)
            .padding(10)
    }

    // MARK: Attachments

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.isInline ? "photo" : "paperclip")
                            .font(.system(size: 9))
                        Text(attachment.filename)
                            .font(Theme.mono(9))
                            .lineLimit(1)
                        Button {
                            draft.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(theme.inkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.panelAlt,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("LOCAL DRAFT · Attachments stay on this Mac until you send")
                .font(Theme.mono(8.5))
                .foregroundStyle(theme.inkTertiary)
            Spacer()
            if let message = model.error {
                Text(message.uppercased())
                    .font(Theme.mono(8.5))
                    .foregroundStyle(theme.signal)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private var fromAccount: GmailAccount? {
        app.gmailStore.account(draft.accountID) ?? app.gmailStore.accounts.first
    }

    private var recipientSummary: String {
        let values = GmailAddress.parseList(toText) + GmailAddress.parseList(ccText)
            + GmailAddress.parseList(bccText)
        return values.isEmpty ? "no recipients" : values.map(\.mailbox).joined(separator: ", ")
    }

    private func syncDraft() {
        draft.accountID = fromAccount?.id ?? draft.accountID
        draft.to = GmailAddress.parseList(toText)
        draft.cc = GmailAddress.parseList(ccText)
        draft.bcc = GmailAddress.parseList(bccText)
        draft.subject = subject
        draft.bodyText = bodyText
        draft.bodyHTML = composerHTML()
        draft.updatedAt = Date()
    }

    private func composerHTML() -> String {
        var html = bodyHTML
        for attachment in draft.attachments where attachment.isInline {
            let cid = attachment.contentID ?? "\(attachment.id.uuidString)@meet.local"
            let alreadyReferenced = html.contains("cid:\(cid)")
                || html.contains(attachment.localPath)
            if !alreadyReferenced {
                html += "<p><img src=\"cid:\(cid)\" alt=\"\(htmlEscape(attachment.filename))\"></p>"
            }
        }
        return html
    }

    private func save() {
        syncDraft()
        guard !draft.isEmpty else {
            model.closeComposer(save: false)
            return
        }
        guard draft.attachments.allSatisfy({
            !$0.localPath.isEmpty && FileManager.default.fileExists(atPath: $0.localPath)
        }) else {
            model.saveDraftLocally(draft)
            status = "Attachments missing · saved locally"
            return
        }
        model.saveDraft(draft)
        status = "Draft saved"
    }

    /// Closing keeps whatever is being written as a local draft. There is no silent
    /// loss of a half-written message; Gmail only sees it if SAVE DRAFT is pressed.
    private func close() {
        autosaveTask?.cancel()
        syncDraft()
        if !draft.isEmpty {
            draft.status = draft.gmailDraftID == nil ? .local : .dirty
            model.saveDraftLocally(draft)
        }
        model.closeComposer(save: false)
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            syncDraft()
            if !draft.isEmpty {
                draft.status = draft.gmailDraftID == nil ? .local : .dirty
                model.saveDraftLocally(draft)
                status = draft.gmailDraftID == nil
                    ? "Local draft saved" : "Changes saved locally"
            }
        }
    }

    private func send() {
        syncDraft()
        let recipients = GmailAddress.parseList(toText) + GmailAddress.parseList(ccText)
            + GmailAddress.parseList(bccText)
        guard !recipients.isEmpty else {
            status = "Add a recipient first"
            return
        }
        guard recipients.allSatisfy({ $0.email.contains("@") }) else {
            status = "Check the recipient addresses"
            return
        }
        isSending = true
        autosaveTask?.cancel()
        Task {
            await model.sendDraft(draft)
            isSending = false
            if model.showingComposer { status = model.error ?? "Not sent" }
        }
    }

    private func chooseImage(inline: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if inline {
            panel.allowedContentTypes = [.image]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if inline {
            if addAttachment(url: url, inline: true) {
                editor.insertImage(url: url)
            }
        } else {
            _ = addAttachment(url: url, inline: false)
        }
    }

    @discardableResult
    private func addAttachment(url: URL, inline: Bool) -> Bool {
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        guard let attachment = model.addDraftAttachment(
            source: url, draftID: draft.id, mimeType: mime, inline: inline) else {
            return false
        }
        draft.attachments.append(attachment)
        return true
    }

    private func htmlEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Rich text editor

@MainActor
@Observable
final class RichTextController {
    weak var textView: NSTextView?

    func attach(_ view: NSTextView) { textView = view }
    func detach() { textView = nil }

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    func toggleUnderline() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        var hasUnderline = false
        storage.enumerateAttribute(.underlineStyle, in: range) { value, _, _ in
            if (value as? Int ?? 0) != 0 { hasUnderline = true }
        }
        if hasUnderline {
            storage.removeAttribute(.underlineStyle, range: range)
        } else {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                 range: range)
        }
        textView.didChangeText()
    }

    func insertLink() {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Link URL"
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: field.stringValue),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        textView.textStorage?.addAttribute(.link, value: url, range: range)
        textView.didChangeText()
    }

    func insertImage(url: URL) {
        guard let textView, let image = NSImage(contentsOf: url) else { return }
        let attachment = NSTextAttachment()
        attachment.image = image
        let value = NSMutableAttributedString(attachment: attachment)
        textView.textStorage?.insert(value, at: textView.selectedRange().location)
        textView.didChangeText()
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        var hasTrait = true
        storage.enumerateAttribute(.font, in: range) { value, _, stop in
            let font = value as? NSFont ?? NSFont.systemFont(ofSize: 13)
            if !NSFontManager.shared.traits(of: font).contains(trait) {
                hasTrait = false
                stop.pointee = true
            }
        }
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? NSFont.systemFont(ofSize: 13)
            let converted = hasTrait
                ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                : NSFontManager.shared.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
        textView.didChangeText()
    }
}

struct MailRichTextEditor: NSViewRepresentable {
    let controller: RichTextController
    @Binding var html: String
    @Binding var text: String
    var isDark = false
    var onInsertImage: ((URL) -> Void)?

    private var inkColor: NSColor {
        isDark ? NSColor(srgbRed: 0.906, green: 0.918, blue: 0.875, alpha: 1)
               : NSColor(srgbRed: 0.082, green: 0.090, blue: 0.059, alpha: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let textView = NSTextView()
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.usesFindBar = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = inkColor
        textView.insertionPointColor = inkColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 700, height: 360)
        textView.textContainer?.containerSize = NSSize(width: 700,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        controller.attach(textView)
        context.coordinator.textView = textView
        context.coordinator.load(html: html, plainText: text,
                                          inkColor: context.coordinator.parent.inkColor,
                                          into: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.textView = textView
        textView.textColor = inkColor
        textView.insertionPointColor = inkColor
        controller.attach(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MailRichTextEditor
        weak var textView: NSTextView?
        private var updating = false

        init(_ parent: MailRichTextEditor) {
            self.parent = parent
        }

        func load(html: String, plainText: String, inkColor: NSColor,
                  into textView: NSTextView) {
            updating = true
            defer { updating = false }
            if !html.isEmpty,
               let data = GmailMime.sanitizeHTML(html).data(using: .utf8),
               let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html,
                              .characterEncoding: String.Encoding.utf8.rawValue,
                              .baseURL: URL(fileURLWithPath: "/")],
                    documentAttributes: nil) {
                let mutable = NSMutableAttributedString(attributedString: attributed)
                let full = NSRange(location: 0, length: mutable.length)
                mutable.addAttribute(.foregroundColor, value: inkColor, range: full)
                mutable.enumerateAttribute(.font, in: full) { value, range, _ in
                    let traits = (value as? NSFont).map {
                        NSFontManager.shared.traits(of: $0)
                    } ?? []
                    var font = NSFont.systemFont(ofSize: 13)
                    if traits.contains(.boldFontMask) {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    }
                    if traits.contains(.italicFontMask) {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                    mutable.addAttribute(.font, value: font, range: range)
                }
                textView.textStorage?.setAttributedString(mutable)
                textView.setSelectedRange(NSRange(location: mutable.length, length: 0))
            } else if !plainText.isEmpty {
                textView.string = plainText
                textView.setSelectedRange(NSRange(location: (plainText as NSString).length,
                                                  length: 0))
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !updating, let textView = notification.object as? NSTextView else { return }
            let attributed = textView.attributedString()
            let plain = attributed.string
            // The editor shows theme colours; the message must not inherit the
            // app's dark-mode ink. Remove foreground colour before exporting HTML.
            let export = NSMutableAttributedString(attributedString: attributed)
            export.removeAttribute(.foregroundColor,
                                   range: NSRange(location: 0, length: export.length))
            let html = Self.html(from: export)
            DispatchQueue.main.async {
                if self.parent.text != plain { self.parent.text = plain }
                if self.parent.html != html { self.parent.html = html }
            }
        }

        private static func html(from attributed: NSAttributedString) -> String {
            guard let data = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                     .characterEncoding: String.Encoding.utf8.rawValue]),
                  let full = String(data: data, encoding: .utf8) else {
                return "<p>\(attributed.string)</p>"
            }
            guard let expression = try? NSRegularExpression(
                pattern: "<body[^>]*>(.*)</body>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = expression.firstMatch(
                    in: full, range: NSRange(location: 0, length: (full as NSString).length)),
                  let range = Range(match.range(at: 1), in: full) else {
                return full
            }
            return String(full[range])
        }
    }
}
