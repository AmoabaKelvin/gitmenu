import Foundation

struct NotificationThread: Codable, Identifiable, Hashable {
    let id: String
    let unread: Bool
    let reason: String
    let updatedAt: Date
    let lastReadAt: Date?
    let subject: Subject
    let repository: Repository
    let url: String
    let subscriptionUrl: String

    struct Subject: Codable, Hashable {
        let title: String
        let url: String?
        let latestCommentUrl: String?
        let type: String
    }

    struct Repository: Codable, Hashable {
        let id: Int
        let name: String
        let fullName: String
        let htmlUrl: String
        let `private`: Bool
        let owner: Owner
        struct Owner: Codable, Hashable {
            let login: String
            let avatarUrl: String
        }
    }

    var subjectNumber: Int? {
        guard ["Issue", "PullRequest", "Discussion"].contains(subject.type),
              let u = subject.url, let last = u.split(separator: "/").last else { return nil }
        return Int(last)
    }
}

enum SubjectState: String, Codable {
    case open, closed, merged, draft, none
}

struct ThreadDetails: Codable, Hashable {
    var htmlUrl: String
    var state: SubjectState = .none
    var number: Int? = nil
    var author: Actor? = nil
    var activities: [Activity] = []
    var reviewDecision: String? = nil
    var checksState: String? = nil
    var labels: [Label] = []
    var body: String? = nil

    struct Actor: Codable, Hashable {
        let login: String
        let avatarUrl: String
    }
    struct Activity: Codable, Hashable, Identifiable {
        let id: String
        let kind: String
        let author: Actor?
        let body: String
        let htmlUrl: String?
        let createdAt: Date
    }
    struct Label: Codable, Hashable {
        let name: String
        let color: String
    }

    var latestActivity: Activity? { activities.last }

    func newActivities(since lastRead: Date?) -> [Activity] {
        guard let lastRead else { return activities }
        return activities.filter { $0.createdAt > lastRead }
    }
}

enum Reason {
    static func phrase(_ reason: String) -> String {
        switch reason {
        case "review_requested": return "Review requested"
        case "mention": return "Mentioned you"
        case "team_mention": return "Mentioned your team"
        case "assign": return "Assigned to you"
        case "author": return "You authored"
        case "comment": return "You commented"
        case "state_change": return "State changed"
        case "subscribed": return "Watching"
        case "manual": return "Subscribed"
        case "ci_activity": return "Workflow run"
        case "security_alert": return "Security alert"
        case "approval_requested": return "Approval requested"
        case "invitation": return "Invitation"
        default: return reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static let urgent: Set<String> = ["review_requested", "mention", "team_mention", "assign", "approval_requested", "security_alert"]
}
