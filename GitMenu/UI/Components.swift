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

struct Hairline: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
}
