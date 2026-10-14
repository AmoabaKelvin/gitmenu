import SwiftUI

struct Avatar: View {
    let url: String
    var size: CGFloat = 20
    var rounded: Bool = true

    var body: some View {
        AsyncImage(url: URL(string: url + (url.contains("?") ? "&" : "?") + "s=\(Int(size * 2))")) { phase in
            if let img = phase.image { img.resizable() } else { Color.primary.opacity(0.06) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: rounded ? size / 2 : size / 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: rounded ? size / 2 : size / 4, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// Hugeicon (stroke rounded, MIT) rendered as a template image so it takes the foreground color.
struct Icon: View {
    let name: String
    var size: CGFloat = 16

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let img = Self.image(name) {
            Image(nsImage: img).renderingMode(.template).resizable().frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    static func image(_ name: String) -> NSImage? {
        if let c = cache[name] { return c }
        guard let url = Bundle.main.url(forResource: "hugeicon-\(name)", withExtension: "svg"), let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        cache[name] = img
        return img
    }
}

enum Appearance {
    static func glyph(type: String, state: SubjectState) -> String {
        switch type {
        case "PullRequest":
            switch state {
            case .merged: return "git-merge"
            case .closed: return "git-pull-request-closed"
            case .draft: return "git-pull-request-draft"
            default: return "git-pull-request"
            }
        case "Issue": return state == .closed ? "issue-closed" : "issue-opened"
        case "Discussion": return "comment-discussion"
        case "Release": return "tag"
        case "Commit": return "git-commit"
        case "CheckSuite", "WorkflowRun": return "workflow"
        case "RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread": return "shield"
        case "RepositoryInvitation": return "mail"
        default: return "issue-opened"
        }
    }

    static func stateColor(_ s: SubjectState) -> Color {
        switch s {
        case .open: return Color(red: 0.13, green: 0.59, blue: 0.33)
        case .merged: return Color(red: 0.51, green: 0.33, blue: 0.82)
        case .closed: return Color(red: 0.80, green: 0.25, blue: 0.22)
        case .draft, .none: return .secondary
        }
    }

    static func relative(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        if s < 86400 * 7 { return "\(s / 86400)d" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

/// Review decision and check status for a pull request, as one quiet line.
struct StatusBadges: View {
    var isDraft = false
    let reviewDecision: String?
    let checksState: String?

    var body: some View {
        HStack(spacing: 6) {
            if isDraft { Text("Draft").foregroundStyle(.secondary) }
            if let r = reviewDecision {
                Text(r.replacingOccurrences(of: "_", with: " ").lowercased().capitalized)
                    .foregroundStyle(r == "APPROVED" ? Appearance.stateColor(.open) : r == "CHANGES_REQUESTED" ? Appearance.stateColor(.closed) : .secondary)
            }
            if let c = checksState {
                HStack(spacing: 4) {
                    Circle().fill(c == "SUCCESS" ? Appearance.stateColor(.open) : c == "FAILURE" || c == "ERROR" ? Appearance.stateColor(.closed) : .orange).frame(width: 6, height: 6)
                    Text("Checks " + c.lowercased()).foregroundStyle(.secondary)
                }
            }
            Text(" ")
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}

/// The actions every thread menu offers: the row's context menu, its "more" button and the detail toolbar.
struct ThreadActions: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    let thread: NotificationThread

    var body: some View {
        let repo = thread.repository.fullName
        Button("Open on GitHub") { model.open(thread) }
        Button("Mark as read") { model.markRead(thread) }.disabled(!thread.unread)
        Button("Mark as done") { model.markDone(thread) }
        if prefs.snoozed[thread.id] != nil {
            Button("Unsnooze") { model.unsnooze(thread) }
        } else {
            Menu("Snooze") {
                ForEach(Snooze.allCases, id: \.self) { s in
                    Button(s.title) { model.snooze(thread, s) }
                }
            }
        }
        Divider()
        if let u = model.webUrl(thread) {
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u.absoluteString, forType: .string)
            }
        }
        Button("Mute thread") { model.mute(thread) }
        Toggle("Silence banners from \(thread.repository.name)", isOn: Binding(
            get: { prefs.silencedRepos.contains(repo) },
            set: { on in if on { prefs.silencedRepos.insert(repo) } else { prefs.silencedRepos.remove(repo) } }))
        Divider()
        Button("Hide all \u{201C}\(Reason.phrase(thread.reason))\u{201D} notifications") { prefs.hiddenReasons.insert(thread.reason) }
        Button("Hide everything from \(thread.repository.name)") { prefs.hiddenRepos.insert(repo) }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
}
