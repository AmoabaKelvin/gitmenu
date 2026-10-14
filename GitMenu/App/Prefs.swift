import AppKit

struct HotKeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt
    var label: String

    static let standard = HotKeyCombo(keyCode: 5, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, label: "G")

    var display: String {
        let m = NSEvent.ModifierFlags(rawValue: modifiers)
        return (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + label
    }
}

/// Settings and small pieces of local state (snoozes, collapsed groups), kept in UserDefaults.
@MainActor
final class Prefs: ObservableObject {
    private static let d = UserDefaults.standard

    @Published var showCount: Bool { didSet { Self.d.set(showCount, forKey: "showCount") } }
    @Published var groupByRepo: Bool { didSet { Self.d.set(groupByRepo, forKey: "groupByRepo") } }
    @Published var pollInterval: Double { didSet { Self.d.set(pollInterval, forKey: "pollInterval") } }
    @Published var bannersEnabled: Bool { didSet { Self.d.set(bannersEnabled, forKey: "bannersEnabled") } }
    @Published var playSound: Bool { didSet { Self.d.set(playSound, forKey: "playSound") } }
    @Published var autoUpdateCheck: Bool { didSet { Self.d.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }
    /// Reasons and repositories that never raise a banner. They still show in the inbox.
    @Published var silencedReasons: Set<String> { didSet { Self.d.set(Array(silencedReasons), forKey: "silencedReasons") } }
    @Published var silencedRepos: Set<String> { didSet { Self.d.set(Array(silencedRepos), forKey: "silencedRepos") } }
    /// Reasons and repositories left out of GitMenu entirely: inbox, counts and banners.
    @Published var hiddenReasons: Set<String> { didSet { Self.d.set(Array(hiddenReasons), forKey: "hiddenReasons") } }
    @Published var hiddenRepos: Set<String> { didSet { Self.d.set(Array(hiddenRepos), forKey: "hiddenRepos") } }
    @Published var collapsedRepos: Set<String> { didSet { Self.d.set(Array(collapsedRepos), forKey: "collapsedRepos") } }
    /// nil means the user cleared the shortcut.
    @Published var hotKey: HotKeyCombo? { didSet { Self.d.set(hotKey.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: "hotKey") } }
    /// Thread id to wake time. Snoozing is local: GitHub has no API for it.
    @Published var snoozed: [String: Date] { didSet { Self.d.set(snoozed.mapValues(\.timeIntervalSince1970), forKey: "snoozed") } }
    /// Threads back from a snooze, shown as unread until acted on.
    @Published var resurfaced: Set<String> { didSet { Self.d.set(Array(resurfaced), forKey: "resurfaced") } }

    init() {
        let d = Self.d
        func bool(_ k: String, _ fallback: Bool) -> Bool { d.object(forKey: k) as? Bool ?? fallback }
        func set(_ k: String) -> Set<String> { Set(d.stringArray(forKey: k) ?? []) }
        showCount = bool("showCount", true)
        groupByRepo = bool("groupByRepo", false)
        pollInterval = d.object(forKey: "pollInterval") as? Double ?? 5
        bannersEnabled = bool("bannersEnabled", true)
        playSound = bool("playSound", true)
        autoUpdateCheck = bool("autoUpdateCheck", true)
        silencedReasons = set("silencedReasons")
        silencedRepos = set("silencedRepos")
        hiddenReasons = set("hiddenReasons")
        hiddenRepos = set("hiddenRepos")
        collapsedRepos = set("collapsedRepos")
        resurfaced = set("resurfaced")
        snoozed = ((d.dictionary(forKey: "snoozed") as? [String: Double]) ?? [:]).mapValues(Date.init(timeIntervalSince1970:))
        if let data = d.data(forKey: "hotKey") {
            hotKey = try? JSONDecoder().decode(HotKeyCombo.self, from: data)
        } else {
            hotKey = .standard
        }
    }
}

enum Snooze: CaseIterable {
    case hour, laterToday, tomorrow, nextWeek

    var title: String {
        switch self {
        case .hour: return "For an hour"
        case .laterToday: return "For three hours"
        case .tomorrow: return "Until tomorrow, 9:00"
        case .nextWeek: return "Until Monday, 9:00"
        }
    }

    var date: Date {
        let cal = Calendar.current
        let now = Date()
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        switch self {
        case .hour: return now.addingTimeInterval(3600)
        case .laterToday: return now.addingTimeInterval(3 * 3600)
        case .tomorrow: return tomorrow.addingTimeInterval(9 * 3600)
        case .nextWeek:
            return cal.nextDate(after: tomorrow.addingTimeInterval(-1), matching: DateComponents(hour: 9, weekday: 2), matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(7 * 86400)
        }
    }
}
