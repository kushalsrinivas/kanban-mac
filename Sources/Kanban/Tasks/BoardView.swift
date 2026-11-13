import SwiftUI

struct BoardView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    /// RootView marks this view focusable with `.focused($focus, equals: .board)`;
    /// this reads whether that focus is currently held.
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(app.visibleStatuses, id: \.self) { status in
                    ColumnView(status: status, tasks: app.tasks(in: status))
                }
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `.focused` only binds focus; the view must also be focusable for the
        // arrow/space/delete handlers to have a target.
        .focusable()
        .focusEffectDisabled()
        // Keyboard navigation is invisible without this: arrows, Return, space and
        // delete only act while the board holds focus.
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline)
                    .padding(.horizontal, Theme.Metric.gutter - 2)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
