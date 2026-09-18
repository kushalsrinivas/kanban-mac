import AppKit
import Foundation
import Observation
import SwiftUI

public enum AppearanceChoice: String, CaseIterable, Codable, Sendable {
    case system, light, dark
    var label: String { rawValue.uppercased() }
}

/// Everything configurable, backed by UserDefaults — except the API key, which lives
/// in the Keychain and is never written to defaults or to disk in plain text.
@Observable
@MainActor
final class AppSettings {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // Appearance
    var appearance: AppearanceChoice { didSet { set(appearance.rawValue, "appearance") } }
    var accent: AccentChoice { didSet { set(accent.rawValue, "accent") } }
    var showInDock: Bool { didSet { set(showInDock, "showInDock"); applyActivationPolicy() } }

    // Tasks
    var defaultPriority: Priority { didSet { set(defaultPriority.rawValue, "defaultPriority") } }
    var defaultStatus: TaskStatus { didSet { set(defaultStatus.rawValue, "defaultStatus") } }
    var showDoneColumn: Bool { didSet { set(showDoneColumn, "showDoneColumn") } }

    // Notifications
    var notificationsEnabled: Bool { didSet { set(notificationsEnabled, "notificationsEnabled") } }
    var notifyOnAgentAction: Bool { didSet { set(notifyOnAgentAction, "notifyOnAgentAction") } }
    var notifyOnMeetingProcessed: Bool { didSet { set(notifyOnMeetingProcessed, "notifyOnMeetingProcessed") } }

    // Backend
    var serverURL: String { didSet { set(serverURL, "serverURL") } }
    var requestTimeout: Double { didSet { set(requestTimeout, "requestTimeout") } }
    var confirmDestructiveAgentActions: Bool { didSet { set(confirmDestructiveAgentActions, "confirmDestructive") } }

    /// Stored in the login Keychain, not in UserDefaults.
    var apiKey: String {
        didSet { KeychainStore.set(apiKey, for: .apiToken) }
    }

    // Meetings
    var captureMicrophone: Bool { didSet { set(captureMicrophone, "captureMicrophone") } }
    var captureSystemAudio: Bool { didSet { set(captureSystemAudio, "captureSystemAudio") } }
    /// Off by default: recordings are transport artefacts, deleted once processed.
    var keepRecordings: Bool { didSet { set(keepRecordings, "keepRecordings") } }
    /// Manual means nothing uploads until the user presses PROCESS. There is no
    /// automatic mode, and this is deliberately not a toggle.
    let uploadPolicy = "MANUAL"

    private init() {
        let d = UserDefaults.standard
        func string(_ key: String, _ fallback: String) -> String { d.string(forKey: key) ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }

        appearance = AppearanceChoice(rawValue: string("appearance", "light")) ?? .light
        accent = AccentChoice(rawValue: string("accent", "mono")) ?? .mono
        showInDock = bool("showInDock", true)
        defaultPriority = Priority(rawValue: int("defaultPriority", Priority.medium.rawValue)) ?? .medium
        defaultStatus = TaskStatus(rawValue: string("defaultStatus", TaskStatus.inbox.rawValue)) ?? .inbox
        showDoneColumn = bool("showDoneColumn", true)
        notificationsEnabled = bool("notificationsEnabled", false)
        notifyOnAgentAction = bool("notifyOnAgentAction", false)
        notifyOnMeetingProcessed = bool("notifyOnMeetingProcessed", true)
        serverURL = string("serverURL", "")
        requestTimeout = double("requestTimeout", 20)
        confirmDestructiveAgentActions = bool("confirmDestructive", true)
        apiKey = KeychainStore.get(.apiToken) ?? ""
        captureMicrophone = bool("captureMicrophone", true)
        captureSystemAudio = bool("captureSystemAudio", true)
        keepRecordings = bool("keepRecordings", false)
    }

    private func set(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    // MARK: Derived

    func isDark(systemIsDark: Bool) -> Bool {
        switch appearance {
        case .system: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// True when a usable backend URL is set. Everything remote is gated on this;
    /// without it the app is a purely local task manager.
    var backendIsConfigured: Bool {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)) else { return false }
        return url.scheme?.hasPrefix("http") == true && url.host != nil
    }

    func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}
