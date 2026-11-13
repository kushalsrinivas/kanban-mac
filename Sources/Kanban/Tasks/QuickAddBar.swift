import SwiftUI

/// One-line task creation, always visible. ⌘N focuses it; Return files the task and
/// leaves the field ready for the next one. No sheet, no modal, no navigation.
struct QuickAddBar: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @FocusState.Binding var focus: FocusTarget?

    var body: some View {
        @Bindable var app = app

        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.inkSecondary)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))

            TextField("", text: $app.quickAddText,
                      prompt: Text("new task   !high  #tag  @friday  >todo")
                        .font(Theme.mono(11.5)).foregroundStyle(theme.inkTertiary))
                .textFieldStyle(.plain)
                .font(Theme.display(13.5))
                .foregroundStyle(theme.ink)
                .focused($focus, equals: .quickAdd)
                .onSubmit(submit)
                .accessibilityLabel("New task")

            if !app.quickAddText.isEmpty {
                Text(QuickParse.hint(for: app.quickAddText,
                                     defaultPriority: app.settings.defaultPriority,
                                     defaultStatus: app.focusedStatus))
                    .font(Theme.mono(9.5))
                    .tracking(0.6)
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)

                Button(action: submit) { Text("ADD ⏎") }
                    .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
            } else {
                MicroLabel("⌘N")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(focus == .quickAdd ? theme.ink : theme.lineStrong,
                          lineWidth: Theme.Metric.hairline))
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { focus = .quickAdd }
    }

    private func submit() {
        let text = app.quickAddText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            focus = .board
            return
        }
        if app.quickAdd(text, into: app.focusedStatus) != nil {
            app.quickAddText = ""
            app.flash("TASK FILED")
        }
    }
}
