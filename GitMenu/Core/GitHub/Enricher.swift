import Foundation

/// Resolves each thread to a web URL and, for issues/PRs/discussions, fetches state and latest activity in one GraphQL call.
struct Enricher {
    let client: GitHubClient
    let userId: Int

    func enrich(_ threads: [NotificationThread]) async -> [String: ThreadDetails] {
        var out: [String: ThreadDetails] = [:]
        var graphable: [NotificationThread] = []
        for t in threads {
            switch t.subject.type {
            case "PullRequest", "Issue", "Discussion" where t.subjectNumber != nil:
                graphable.append(t)
            default:
                out[t.id] = await fallback(t)
            }
        }
        for chunk in graphable.chunked(50) {
            let details = await enrichGraph(chunk)
            for t in chunk {
                out[t.id] = details[t.id] ?? ThreadDetails(htmlUrl: fallbackUrl(t), number: t.subjectNumber)
            }
        }
        return out
    }

    func referrerUrl(_ url: String, threadId: String) -> String {
        let raw = "018:NotificationThread\(threadId):\(userId)"
        let b64 = Data(raw.utf8).base64EncodedString()
        return url + (url.contains("?") ? "&" : "?") + "notification_referrer_id=NT_\(b64)"
    }

    private func fallbackUrl(_ t: NotificationThread) -> String {
        let repo = t.repository.htmlUrl
        switch t.subject.type {
        case "CheckSuite":
            if let attrs = CheckSuiteTitle.parse(t.subject.title) {
                var q = "workflow:\"\(attrs.workflow)\""
                if let s = attrs.status { q += " is:\(s)" }
                if let b = attrs.branch { q += " branch:\(b)" }
                let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
                return "\(repo)/actions?query=\(enc)"
            }
            return "\(repo)/actions"
        case "WorkflowRun": return "\(repo)/actions"
        case "RepositoryVulnerabilityAlert": return "\(repo)/security/dependabot"
        case "RepositoryInvitation": return "\(repo)/invitations"
        case "RepositoryDependabotAlertsThread": return "\(repo)/security/dependabot"
        case "Release": return "\(repo)/releases"
        case "Discussion": return t.subjectNumber.map { "\(repo)/discussions/\($0)" } ?? "\(repo)/discussions"
        case "PullRequest": return t.subjectNumber.map { "\(repo)/pull/\($0)" } ?? "\(repo)/pulls"
        case "Issue": return t.subjectNumber.map { "\(repo)/issues/\($0)" } ?? "\(repo)/issues"
        default: return repo
        }
    }

    private struct HtmlUrlOnly: Decodable { let htmlUrl: String; let body: String?; let name: String?; let sha: String? }

    private func fallback(_ t: NotificationThread) async -> ThreadDetails {
        var d = ThreadDetails(htmlUrl: fallbackUrl(t))
        if ["Release", "Commit"].contains(t.subject.type), let u = t.subject.url, let url = URL(string: u) {
            if let r: HtmlUrlOnly = try? await client.get(url) {
                d.htmlUrl = r.htmlUrl
                d.body = r.body
            }
        }
        return d
    }

    private func enrichGraph(_ threads: [NotificationThread]) async -> [String: ThreadDetails] {
        var parts: [String] = []
        for (i, t) in threads.enumerated() {
            let field: String
            let frag: String
            switch t.subject.type {
            case "PullRequest": field = "pullRequest"; frag = "...PR"
            case "Issue": field = "issue"; frag = "...IS"
            default: field = "discussion"; frag = "...DS"
            }
            parts.append("n\(i): repository(owner: \"\(t.repository.owner.login)\", name: \"\(t.repository.name)\") { \(field)(number: \(t.subjectNumber!)) { \(frag) } }")
        }
        let types = Set(threads.map(\.subject.type))
        var frags = ["fragment Actor on Actor { login avatarUrl }"]
        if types.contains("PullRequest") {
            frags.append("""
            fragment Timeline on PullRequestTimelineItems {
              __typename
              ... on IssueComment { id author { ...Actor } body url createdAt }
              ... on PullRequestReview { id author { ...Actor } body url createdAt state }
              ... on ReviewRequestedEvent { id actor { ...Actor } createdAt requestedReviewer { ... on User { login } ... on Team { name } } }
              ... on AssignedEvent { id actor { ...Actor } createdAt assignee { ... on User { login } } }
              ... on MergedEvent { id actor { ...Actor } createdAt }
              ... on ClosedEvent { id actor { ...Actor } createdAt }
              ... on ReopenedEvent { id actor { ...Actor } createdAt }
              ... on ReadyForReviewEvent { id actor { ...Actor } createdAt }
            }
            """)
        }
        if types.contains("Issue") {
            frags.append("""
            fragment IssueTimeline on IssueTimelineItems {
              __typename
              ... on IssueComment { id author { ...Actor } body url createdAt }
              ... on AssignedEvent { id actor { ...Actor } createdAt assignee { ... on User { login } } }
              ... on ClosedEvent { id actor { ...Actor } createdAt }
              ... on ReopenedEvent { id actor { ...Actor } createdAt }
            }
            """)
        }
        if types.contains("PullRequest") {
            frags.append("""
            fragment PR on PullRequest {
              number url state isDraft author { ...Actor } bodyText reviewDecision
              labels(first: 6) { nodes { name color } }
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
              timelineItems(last: 12, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, REVIEW_REQUESTED_EVENT, ASSIGNED_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT]) { nodes { ...Timeline } }
            }
            """)
        }
        if types.contains("Issue") {
            frags.append("""
            fragment IS on Issue {
              number url state author { ...Actor } bodyText
              labels(first: 6) { nodes { name color } }
              timelineItems(last: 12, itemTypes: [ISSUE_COMMENT, ASSIGNED_EVENT, CLOSED_EVENT, REOPENED_EVENT]) { nodes { ...IssueTimeline } }
            }
            """)
        }
        if types.contains("Discussion") {
            frags.append("""
            fragment DS on Discussion {
              number url author { ...Actor } bodyText
              comments(last: 8) { nodes { id author { ...Actor } body url createdAt } }
            }
            """)
        }
        let query = "query { \(parts.joined(separator: "\n")) }\n" + frags.joined(separator: "\n")
        let json: [String: Any]
        do { json = try await client.graphql(query) } catch { logger.error("graphql failed: \(error.localizedDescription)"); return [:] }
        if let errs = json["errors"] as? [[String: Any]], !errs.isEmpty {
            logger.error("graphql errors: \(errs.prefix(3).compactMap { $0["message"] as? String }.joined(separator: " | "))")
        }
        guard let data = json["data"] as? [String: Any] else { return [:] }
        var out: [String: ThreadDetails] = [:]
        let iso = ISO8601DateFormatter()
        for (i, t) in threads.enumerated() {
            guard let repo = data["n\(i)"] as? [String: Any],
                  let node = (repo["pullRequest"] ?? repo["issue"] ?? repo["discussion"]) as? [String: Any],
                  let url = node["url"] as? String else { continue }
            var d = ThreadDetails(htmlUrl: url, number: node["number"] as? Int)
            if let a = node["author"] as? [String: Any], let l = a["login"] as? String {
                d.author = .init(login: l, avatarUrl: a["avatarUrl"] as? String ?? "")
            }
            d.body = node["bodyText"] as? String
            let state = (node["state"] as? String ?? "").lowercased()
            if node["isDraft"] as? Bool == true { d.state = .draft }
            else if state == "merged" { d.state = .merged }
            else if state == "closed" { d.state = .closed }
            else if state == "open" { d.state = .open }
            d.reviewDecision = node["reviewDecision"] as? String
            if let commits = (node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]],
               let roll = (commits.first?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any] {
                d.checksState = roll["state"] as? String
            }
            if let labels = (node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] {
                d.labels = labels.compactMap { l in (l["name"] as? String).map { .init(name: $0, color: l["color"] as? String ?? "999999") } }
            }
            var acts: [ThreadDetails.Activity] = []
            func actor(_ n: [String: Any]?) -> ThreadDetails.Actor? {
                guard let n, let l = n["login"] as? String else { return nil }
                return .init(login: l, avatarUrl: n["avatarUrl"] as? String ?? "")
            }
            let items = ((((node["timelineItems"] ?? node["comments"]) as? [String: Any])?["nodes"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
            for n in items {
                guard let id = n["id"] as? String, let c = n["createdAt"] as? String, let date = iso.date(from: c) else { continue }
                let typename = n["__typename"] as? String ?? "IssueComment"
                let who = actor(n["author"] as? [String: Any]) ?? actor(n["actor"] as? [String: Any])
                var kind = "comment"
                var body = n["body"] as? String ?? ""
                switch typename {
                case "PullRequestReview":
                    kind = "review:\((n["state"] as? String ?? "").lowercased())"
                case "ReviewRequestedEvent":
                    kind = "review_requested"
                    let r = n["requestedReviewer"] as? [String: Any]
                    body = (r?["login"] as? String) ?? (r?["name"] as? String) ?? ""
                case "AssignedEvent":
                    kind = "assigned"
                    body = ((n["assignee"] as? [String: Any])?["login"] as? String) ?? ""
                case "MergedEvent": kind = "merged"
                case "ClosedEvent": kind = "closed"
                case "ReopenedEvent": kind = "reopened"
                case "ReadyForReviewEvent": kind = "ready_for_review"
                default: break
                }
                if kind.hasPrefix("review:") && kind != "review:approved" && kind != "review:changes_requested" && body.isEmpty { continue }
                acts.append(.init(id: id, kind: kind, author: who, body: body, htmlUrl: n["url"] as? String, createdAt: date))
            }
            d.activities = acts.sorted { $0.createdAt < $1.createdAt }
            out[t.id] = d
        }
        return out
    }
}

enum CheckSuiteTitle {
    struct Attributes { let workflow: String; let status: String?; let branch: String? }

    static func parse(_ title: String) -> Attributes? {
        let pattern = #"^(?<workflow>.*?) workflow run(?:, Attempt #\d+)? (?<status>\w+) for (?<branch>.*?) branch$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { return nil }
        func g(_ n: String) -> String? { Range(m.range(withName: n), in: title).map { String(title[$0]) } }
        guard let w = g("workflow") else { return nil }
        let status = g("status").map { s -> String in
            switch s { case "succeeded": return "success"; case "failed": return "failure"; default: return s }
        }
        return Attributes(workflow: w, status: status, branch: g("branch"))
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
