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

    /// A named suite keeps UI tests and screenshot runs out of the real preferences.
    private static func makeDefaults() -> UserDefaults {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["KANBAN_DEFAULTS_SUITE"],
           !suite.isEmpty, let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        #endif
        return .standard
    }

    private let defaults = AppSettings.makeDefaults()

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
    var staleTaskNudges: Bool { didSet { set(staleTaskNudges, "staleTaskNudges") } }
    var staleUrgentHours: Int { didSet { set(staleUrgentHours, "staleUrgentHours") } }
    var staleHighHours: Int { didSet { set(staleHighHours, "staleHighHours") } }
    var staleMediumHours: Int { didSet { set(staleMediumHours, "staleMediumHours") } }
    var staleLowHours: Int { didSet { set(staleLowHours, "staleLowHours") } }
    var staleQuietHoursEnabled: Bool { didSet { set(staleQuietHoursEnabled, "staleQuietHoursEnabled") } }
    var staleQuietStartHour: Int { didSet { set(staleQuietStartHour, "staleQuietStartHour") } }
    var staleQuietEndHour: Int { didSet { set(staleQuietEndHour, "staleQuietEndHour") } }
    var staleMaxPerDay: Int { didSet { set(staleMaxPerDay, "staleMaxPerDay") } }
    var staleCooldownHours: Int { didSet { set(staleCooldownHours, "staleCooldownHours") } }

    // Backend
    var serverURL: String { didSet { set(serverURL, "serverURL") } }
    var requestTimeout: Double { didSet { set(requestTimeout, "requestTimeout") } }
    var confirmDestructiveAgentActions: Bool { didSet { set(confirmDestructiveAgentActions, "confirmDestructive") } }
    /// Create/update/move/complete writes apply as soon as the agent resolves them.
    /// Archive and delete always remain proposals.
    var agentAutoApplyWrites: Bool { didSet { set(agentAutoApplyWrites, "agentAutoApplyWrites") } }

    // Local AI
    /// Gemini is called directly from the app for analysis and the agent.
    var geminiModel: String { didSet { set(geminiModel, "geminiModel") } }

    // Local transcription: whisper GGUF through transcribe.cpp, on this Mac.
    var transcriptionModelID: String { didSet { set(transcriptionModelID, "transcriptionModelID") } }
    /// Empty means the catalog's default quant for the selected model.
    var transcriptionQuant: String { didSet { set(transcriptionQuant, "transcriptionQuant") } }
    /// Comma or newline separated terms passed to the model as vocabulary.
    var transcriptionVocabulary: String { didSet { set(transcriptionVocabulary, "transcriptionVocabulary") } }

    // Gmail (client-side only). The client ID is public; the client secret, when a
    // Google desktop client provides one, stays in the Keychain.
    var gmailClientID: String { didSet { set(gmailClientID, "gmailClientID") } }
    var gmailSyncOnLaunch: Bool { didSet { set(gmailSyncOnLaunch, "gmailSyncOnLaunch") } }
    var gmailInitialSyncLimit: Int { didSet { set(gmailInitialSyncLimit, "gmailInitialSyncLimit") } }
    var gmailSemanticSearch: Bool { didSet { set(gmailSemanticSearch, "gmailSemanticSearch") } }

    /// Global ⌃⌥Space dictation: speak, get the transcript on the clipboard.
    var dictationEnabled: Bool { didSet { set(dictationEnabled, "dictationEnabled") } }

    var vocabularyList: [String] {
        transcriptionVocabulary
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Stored in the login Keychain, not in UserDefaults, and read on first use
    /// rather than in `init`.
    ///
    /// A keychain read can put a modal "allow access" dialog on screen: the item's ACL
    /// names the binary that created it, and a locally-signed build gets a new identity
    /// on every rebuild, so the system asks again. Doing that from `init` hangs the app
    /// before it has a window — and the test suite before it has a test.
    var apiKey: String {
        get {
            if loadedAPIKey == nil { loadedAPIKey = KeychainStore.get(.apiToken) ?? "" }
            return loadedAPIKey ?? ""
        }
        set { commitAPIKey(newValue) }
    }

    /// Set when the last keychain write failed, so Settings can say so instead of
    /// accepting the text and silently losing it on quit.
    private(set) var apiKeyWriteFailed = false

    /// Writes the key and reports whether it reached the keychain. The settings field
    /// calls this on end-editing/submit, not on every keystroke.
    @discardableResult
    func commitAPIKey(_ value: String) -> Bool {
        loadedAPIKey = value
        let stored = KeychainStore.set(value, for: .apiToken)
        apiKeyWriteFailed = !stored
        return stored
    }

    @ObservationIgnored private var loadedAPIKey: String?

    /// The Gemini key, in the same Keychain item store as the VPS token.
    var geminiAPIKey: String {
        get {
            if loadedGeminiKey == nil { loadedGeminiKey = KeychainStore.get(.geminiKey) ?? "" }
            return loadedGeminiKey ?? ""
        }
        set { commitGeminiAPIKey(newValue) }
    }

    private(set) var geminiKeyWriteFailed = false

    @discardableResult
    func commitGeminiAPIKey(_ value: String) -> Bool {
        loadedGeminiKey = value
        let stored = KeychainStore.set(value, for: .geminiKey)
        geminiKeyWriteFailed = !stored
        return stored
    }

    @ObservationIgnored private var loadedGeminiKey: String?

    /// The OAuth client secret, when the Google project supplies one. Never in
    /// UserDefaults and never in the source tree.
    var gmailClientSecret: String {
        get {
            if loadedGmailSecret == nil {
                loadedGmailSecret = GmailKeychain().loadClientSecret() ?? ""
            }
            return loadedGmailSecret ?? ""
        }
        set { commitGmailClientSecret(newValue) }
    }

    private(set) var gmailClientSecretWriteFailed = false

    @discardableResult
    func commitGmailClientSecret(_ value: String) -> Bool {
        loadedGmailSecret = value
        let store = GmailKeychain()
        if value.isEmpty {
            store.saveClientSecret("")
            gmailClientSecretWriteFailed = false
            return true
        }
        store.saveClientSecret(value)
        // A read-back distinguishes a silent Keychain failure from success.
        let stored = store.loadClientSecret() == value
        gmailClientSecretWriteFailed = !stored
        return stored
    }

    @ObservationIgnored private var loadedGmailSecret: String?

    /// The Google desktop client ID and optional secret, as one value.
    var gmailOAuthConfig: GmailOAuthConfig {
        GmailOAuthConfig(clientID: gmailClientID,
                         clientSecret: gmailClientSecret.isEmpty ? nil : gmailClientSecret)
    }

    var hasGmailClient: Bool {
        GmailOAuthConfig(clientID: gmailClientID).isValid
    }

    /// The pure policy the notification bridge evaluates. Settings only supplies
    /// values; the engine owns the threshold and quiet-hours rules.
    var staleTaskPolicy: StaleTaskPolicy {
        StaleTaskPolicy(
            enabled: staleTaskNudges,
            urgentHours: Double(max(1, staleUrgentHours)),
            highHours: Double(max(1, staleHighHours)),
            mediumHours: Double(max(1, staleMediumHours)),
            lowHours: Double(max(1, staleLowHours)),
            quietHoursEnabled: staleQuietHoursEnabled,
            quietStartHour: staleQuietStartHour,
            quietEndHour: staleQuietEndHour,
            cooldownHours: Double(max(1, staleCooldownHours)),
            maxPerDay: max(1, staleMaxPerDay))
    }

    /// True when meeting analysis and the local agent can run.
    var hasGeminiKey: Bool {
        !geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A recording can be processed when there is a speech model on this Mac,
    /// a Gemini key (analysis), or a VPS. Transcription itself never needs the
    /// network.
    var canProcessMeetings: Bool {
        hasLocalTranscriptionModel || hasGeminiKey || backendIsConfigured
    }

    /// A speech model is on this Mac, so transcription can run offline.
    var hasLocalTranscriptionModel: Bool { ModelStorage.hasAnyInstalledModel }

    /// The selected model was never explicitly chosen (the shipped default is
    /// still in effect).
    var transcriptionModelWasDefaulted: Bool {
        defaults.object(forKey: "transcriptionModelID") == nil
    }
    var captureMicrophone: Bool { didSet { set(captureMicrophone, "captureMicrophone") } }
    /// Off by default. Capturing the other side of a call needs ScreenCaptureKit,
    /// which means Screen Recording permission and a capture indicator in the menu
    /// bar. That is a lot to impose on someone who just wants to record a room, so
    /// it is opt-in.
    var captureSystemAudio: Bool { didSet { set(captureSystemAudio, "captureSystemAudio") } }
    /// On by default: a recording is the only copy of what was said, so it stays on
    /// this Mac after the VPS has finished with it. Turn it off to treat recordings
    /// as transport files and reclaim the space automatically.
    var keepRecordings: Bool { didSet { set(keepRecordings, "keepRecordings") } }
    /// On by default: stopping a recording saves it here and sends it to the VPS for
    /// transcription without another press. Turn it off and audio only ever leaves
    /// this Mac when PROCESS is pressed on a specific recording.
    var autoUpload: Bool { didSet { set(autoUpload, "autoUpload") } }

    private init() {
        let d = defaults
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
        staleTaskNudges = bool("staleTaskNudges", true)
        staleUrgentHours = int("staleUrgentHours", 4)
        staleHighHours = int("staleHighHours", 24)
        staleMediumHours = int("staleMediumHours", 72)
        staleLowHours = int("staleLowHours", 168)
        staleQuietHoursEnabled = bool("staleQuietHoursEnabled", true)
        staleQuietStartHour = int("staleQuietStartHour", 22)
        staleQuietEndHour = int("staleQuietEndHour", 8)
        staleMaxPerDay = int("staleMaxPerDay", 2)
        staleCooldownHours = int("staleCooldownHours", 12)
        serverURL = string("serverURL", "")
        requestTimeout = double("requestTimeout", 20)
        confirmDestructiveAgentActions = bool("confirmDestructive", true)
        agentAutoApplyWrites = bool("agentAutoApplyWrites", true)
        geminiModel = string("geminiModel", "gemini-2.5-flash")
        transcriptionModelID = string("transcriptionModelID", "whisper-small")
        transcriptionQuant = string("transcriptionQuant", "")
        transcriptionVocabulary = string("transcriptionVocabulary", "")
        gmailClientID = string("gmailClientID", "")
        gmailSyncOnLaunch = bool("gmailSyncOnLaunch", true)
        gmailInitialSyncLimit = int("gmailInitialSyncLimit", 500)
        gmailSemanticSearch = bool("gmailSemanticSearch", true)
        dictationEnabled = bool("dictationEnabled", true)
        captureMicrophone = bool("captureMicrophone", true)
        // System audio used to default on. Reset it once for anyone carrying the old
        // value, so nobody is stuck with a Screen Recording prompt they never wanted.
        if !d.bool(forKey: "didResetSystemAudioDefault") {
            d.set(false, forKey: "captureSystemAudio")
            d.set(true, forKey: "didResetSystemAudioDefault")
        }
        captureSystemAudio = bool("captureSystemAudio", false)
        keepRecordings = bool("keepRecordings", true)
        autoUpload = bool("autoUpload", true)
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
    /// without it the app is a purely local task manager. Plain HTTP is refused for
    /// anything but a loopback host — the bearer token would travel in the clear.
    var backendIsConfigured: Bool {
        ServerURLPolicy.isUsable(serverURL)
    }

    func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    #if DEBUG
    /// Unit tests and capture harnesses: credentials stay in memory, never in the
    /// login keychain, and no real server is configured.
    static func testing(geminiKey: String = "test-key") -> AppSettings {
        let settings = AppSettings()
        settings.serverURL = ""
        settings.loadedAPIKey = ""
        settings.loadedGeminiKey = geminiKey
        return settings
    }
    #endif
}
