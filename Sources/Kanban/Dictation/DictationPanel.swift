import AppKit
import SwiftUI

/// What the floating panel is showing.
@MainActor
@Observable
final class DictationPanelModel {
    enum State: Equatable {
        case listening
        case transcribing
        case copied
        case failed(String)
    }

    var state: State = .listening
    var level: Float = 0
}

/// The small floating card Handy shows while dictating: 330×68, borderless,
/// non-activating, above normal windows on every Space.
@MainActor
final class DictationPanel {

    let model = DictationPanelModel()
    private var panel: NSPanel?

    func show(_ state: DictationPanelModel.State, level: Float, theme: Theme) {
        let panel = makePanel()
        model.state = state
        model.level = level
        (panel.contentView as? NSHostingView<AnyView>)?.rootView = AnyView(
            DictationPanelView(model: model).environment(\.theme, theme))
        position(panel)
        panel.orderFrontRegardless()
    }

    func update(level: Float) {
        model.level = level
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 68),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: AnyView(
            DictationPanelView(model: model)
                .environment(\.theme, Theme.resolved(dark: false, accent: .mono))))
        self.panel = panel
        return panel
    }

    /// Top centre of whichever screen holds the pointer, as Handy places it.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 14))
    }
}

struct DictationPanelView: View {
    @Environment(\.theme) private var theme
    let model: DictationPanelModel

    private var title: String {
        switch model.state {
        case .listening: return "LISTENING"
        case .transcribing: return "TRANSCRIBING"
        case .copied: return "COPIED"
        case .failed: return "DICTATION FAILED"
        }
    }

    private var subtitle: String {
        switch model.state {
        case .listening: return "SPEAK · STOPS ON SILENCE · ⌃⌥SPACE"
        case .transcribing: return "ON THIS MAC"
        case .copied: return "READY TO PASTE"
        case .failed(let message): return message.uppercased()
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            indicator
                .frame(width: 26, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(theme.ink)
                Text(subtitle)
                    .font(Theme.mono(8.5))
                    .tracking(0.5)
                    .foregroundStyle(theme.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 330, height: 68)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.lineStrong, lineWidth: 1)))
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.state {
        case .listening:
            LevelBars(level: model.level, color: theme.signal)
        case .transcribing:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(theme.inkSecondary)
        case .copied:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink)
        case .failed:
            StatusDot(.alert)
        }
    }
}

/// Four bars that follow the microphone, not a decorative animation.
private struct LevelBars: View {
    let level: Float
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: height(index))
            }
        }
        .frame(width: 20, height: 22, alignment: .center)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func height(_ index: Int) -> CGFloat {
        let weights: [CGFloat] = [0.5, 1.0, 0.75, 0.35]
        return 4 + CGFloat(min(max(level, 0), 1)) * 16 * weights[index]
    }
}
