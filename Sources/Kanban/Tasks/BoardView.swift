import SwiftUI

struct BoardView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    /// RootView marks this view focusable with `.focused($focus, equals: .board)`;
    /// this reads whether that focus is currently held.
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        GeometryReader { geo in
            let count = max(1, app.visibleStatuses.count)
            let gap: CGFloat = 10
            let available = geo.size.width - Theme.Metric.gutter * 2 - gap * CGFloat(count - 1)
            // Fill the window instead of leaving a dead strip on wide screens;
            // stop at a readable card width and scroll below the minimum.
            let width = min(340, max(Theme.Metric.columnWidth, available / CGFloat(count)))

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(app.visibleStatuses, id: \.self) { status in
                            ColumnView(status: status, tasks: app.tasks(in: status), width: width)
                                .id(status)
                        }
                    }
                    .padding(.horizontal, Theme.Metric.gutter)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.automatic)
                .onAppear { revealSelection(proxy) }
                .onChange(of: app.selection) { _, _ in revealSelection(proxy) }
                .onChange(of: app.focusedStatus) { _, status in
                    proxy.scrollTo(status, anchor: .center)
                }
                .onChange(of: app.inspector) { _, _ in
                    // Opening the inspector shrinks the board; keep the selected
                    // card visible rather than letting it disappear behind the panel.
                    revealSelection(proxy)
                }
            }
        }
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

    private func revealSelection(_ proxy: ScrollViewProxy) {
        guard let id = app.selection else { return }
        proxy.scrollTo(id, anchor: .center)
    }
}
