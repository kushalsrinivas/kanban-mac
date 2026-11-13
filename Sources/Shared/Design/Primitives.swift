import SwiftUI

// MARK: - Micro label

/// The uppercase 9.5pt monospace label that titles every block in the reference.
public struct MicroLabel: View {
    @Environment(\.theme) private var theme
    private let text: String
    private let color: Color?

    public init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        // textCase, not .uppercased(): VoiceOver reads "task", not "T-A-S-K".
        Text(text)
            .textCase(.uppercase)
            .font(Theme.microLabel)
            .tracking(0.9)
            .foregroundStyle(color ?? theme.inkTertiary)
    }
}

// MARK: - Rules

public struct Rule: View {
    @Environment(\.theme) private var theme
    private let strong: Bool

    public init(strong: Bool = false) { self.strong = strong }

    public var body: some View {
        Rectangle()
            .fill(strong ? theme.lineStrong : theme.line)
            .frame(height: Theme.Metric.hairline)
    }
}

public struct VRule: View {
    @Environment(\.theme) private var theme
    public init() {}
    public var body: some View {
        Rectangle().fill(theme.line).frame(width: Theme.Metric.hairline)
    }
}

// MARK: - Panel

/// Large rounded container with a 1px border and no shadow — the core structural element.
public struct Panel<Content: View>: View {
    @Environment(\.theme) private var theme
    private let radius: CGFloat
    private let padding: CGFloat
    private let filled: Bool
    private let content: Content

    public init(radius: CGFloat = Theme.Radius.panel, padding: CGFloat = 14, filled: Bool = true,
                @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.padding = padding
        self.filled = filled
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(filled ? theme.panel : Color.clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline)
            )
    }
}

// MARK: - Labelled block

/// LABEL over a large value — the "WATER / 67°C" pattern from the reference.
public struct ValueBlock: View {
    @Environment(\.theme) private var theme
    private let label: String
    private let value: String
    private let size: CGFloat
    private let tint: Color?

    public init(_ label: String, _ value: String, size: CGFloat = 22, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            MicroLabel(label)
            Text(value)
                .font(Theme.mono(size, weight: .light))
                .foregroundStyle(tint ?? theme.ink)
                .monospacedDigit()
        }
    }
}

// MARK: - Pill / segmented control

public struct PillToggle: View {
    @Environment(\.theme) private var theme
    private let isOn: Bool
    private let onLabel: String
    private let offLabel: String
    private let action: () -> Void

    public init(isOn: Bool, onLabel: String = "ON", offLabel: String = "OFF", action: @escaping () -> Void) {
        self.isOn = isOn
        self.onLabel = onLabel
        self.offLabel = offLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isOn {
                    Text(onLabel).font(Theme.mono(9.5, weight: .medium)).foregroundStyle(theme.paper)
                    Circle().fill(theme.paper).frame(width: 12, height: 12)
                } else {
                    Circle().fill(theme.panel).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(theme.line, lineWidth: 1))
                    Text(offLabel).font(Theme.mono(9.5, weight: .medium)).foregroundStyle(theme.inkTertiary)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(width: 52, alignment: isOn ? .leading : .trailing)
            .background(isOn ? theme.ink : theme.panelAlt, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
        }
        .buttonStyle(.plain)
    }
}

/// Compact horizontal choice control: `LOW MED HIGH URG` with the active item inked.
public struct SegmentPicker<T: Hashable>: View {
    @Environment(\.theme) private var theme
    private let options: [(value: T, label: String)]
    @Binding private var selection: T

    public init(selection: Binding<T>, options: [(value: T, label: String)]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let active = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(Theme.mono(10, weight: active ? .semibold : .regular))
                        .tracking(0.6)
                        .foregroundStyle(active ? theme.paper : theme.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(active ? theme.ink : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline)
        )
    }
}

// MARK: - Buttons

public struct PanelButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    private let prominent: Bool
    private let compact: Bool

    public init(prominent: Bool = false, compact: Bool = false) {
        self.prominent = prominent
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(compact ? 10 : 10.5, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(prominent ? theme.paper : theme.ink)
            .padding(.horizontal, compact ? 8 : 11)
            .padding(.vertical, compact ? 4 : 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(prominent ? theme.ink : theme.panel)
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : theme.lineStrong,
                                  lineWidth: Theme.Metric.hairline)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Text-only action, used inside dense lists ("+ADD" in the reference).
public struct BareButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    private let emphasised: Bool

    public init(emphasised: Bool = false) { self.emphasised = emphasised }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(10, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(emphasised ? theme.ink : theme.inkSecondary)
            .padding(.vertical, 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

// MARK: - Status dot

public struct StatusDot: View {
    public enum State { case on, idle, off, alert }
    @Environment(\.theme) private var theme
    private let state: State

    public init(_ state: State) { self.state = state }

    public var body: some View {
        Group {
            switch state {
            case .on: Circle().fill(theme.ink)
            case .idle: Circle().fill(theme.inkTertiary)
            case .alert: Circle().fill(theme.signal)
            case .off: Circle().strokeBorder(theme.lineStrong, lineWidth: 1)
            }
        }
        .frame(width: 6, height: 6)
    }
}

// MARK: - Priority mark

/// Priority as a filled-bar glyph rather than a colour chip — keeps the board monochrome.
public struct PriorityMark: View {
    @Environment(\.theme) private var theme
    private let priority: Priority

    public init(_ priority: Priority) { self.priority = priority }

    public var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                Rectangle()
                    .fill(i < filledBars ? (priority == .urgent ? theme.signal : theme.ink) : theme.line)
                    .frame(width: 2.5, height: 7)
            }
        }
        .accessibilityLabel("Priority \(priority.longLabel)")
    }

    private var filledBars: Int {
        switch priority {
        case .low: return 1
        case .medium: return 2
        case .high, .urgent: return 3
        }
    }
}
