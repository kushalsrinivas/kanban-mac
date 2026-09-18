import SwiftUI

struct BoardView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

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
    }
}
