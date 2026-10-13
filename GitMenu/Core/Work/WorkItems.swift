import Foundation

/// Live state, not events: what is assigned to you and what is waiting for your review right now.
struct WorkItem: Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let url: String
    let repo: String
    let repoName: String
    let isPullRequest: Bool
    let isDraft: Bool
    let reviewDecision: String?
    let checksState: String?
    let author: ThreadDetails.Actor?
    let updatedAt: Date
    let viaTeam: Bool

    var state: SubjectState { isDraft ? .draft : .open }
    var subjectType: String { isPullRequest ? "PullRequest" : "Issue" }
}

struct WorkLists {
    var assigned: [WorkItem] = []
    var reviews: [WorkItem] = []
    /// False until the first answer from GitHub, so an empty list is not shown as "nothing assigned".
    var loaded = false
    var error: String?
}

@MainActor
final class WorkPoller {
    private let client: GitHubClient
    private let onUpdate: (WorkLists) -> Void
    private var timer: Timer?
    private var running = false
    private var last = WorkLists()

    init(client: GitHubClient, onUpdate: @escaping (WorkLists) -> Void) {
        self.client = client
        self.onUpdate = onUpdate
    }

    func start() {
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await refresh() }
    }

    func stop() { timer?.invalidate() }

    func refresh() async {
        if running { return }
        running = true
        defer { running = false }
        let query = """
        query {
          reviews: search(query: "is:pr is:open review-requested:@me", type: ISSUE, first: 50) { nodes { ...PR } }
          direct: search(query: "is:pr is:open user-review-requested:@me", type: ISSUE, first: 50) { nodes { ... on PullRequest { id } } }
          assigned: search(query: "is:open assignee:@me", type: ISSUE, first: 50) { nodes { ...PR ...IS } }
        }
        fragment Actor on Actor { login avatarUrl }
        fragment PR on PullRequest {
          id number title url updatedAt isDraft reviewDecision author { ...Actor }
          repository { nameWithOwner name }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        }
        fragment IS on Issue { id number title url updatedAt author { ...Actor } repository { nameWithOwner name } }
        """
        let json: [String: Any]
        do { json = try await client.graphql(query) } catch { return fail(error.localizedDescription) }
        // GraphQL reports scope and SSO problems here, often next to partial data.
        let problem = (json["errors"] as? [[String: Any]])?.first?["message"] as? String
        guard let data = json["data"] as? [String: Any] else { return fail(problem ?? "GitHub returned no data.") }
        if let problem { logger.error("work poll partial: \(problem)") }
        let iso = ISO8601DateFormatter()
        // Items GitHub refuses to show this token come back as null entries; casting the whole array would drop the list.
        func nodes(_ key: String) -> [[String: Any]] {
            (((data[key] as? [String: Any])?["nodes"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        }
        let directIds = Set(nodes("direct").compactMap { $0["id"] as? String })
        func parse(_ n: [String: Any], team: Bool) -> WorkItem? {
            guard let id = n["id"] as? String, let number = n["number"] as? Int, let title = n["title"] as? String,
                  let url = n["url"] as? String, let repo = n["repository"] as? [String: Any],
                  let full = repo["nameWithOwner"] as? String, let u = n["updatedAt"] as? String, let date = iso.date(from: u) else { return nil }
            let a = (n["author"] as? [String: Any]).flatMap { a in (a["login"] as? String).map { ThreadDetails.Actor(login: $0, avatarUrl: a["avatarUrl"] as? String ?? "") } }
            let commitNodes = (n["commits"] as? [String: Any]).flatMap { $0["nodes"] as? [[String: Any]] }
            let commit = commitNodes?.first.flatMap { $0["commit"] as? [String: Any] }
            let roll = commit.flatMap { $0["statusCheckRollup"] as? [String: Any] }
            return WorkItem(id: id, number: number, title: title, url: url, repo: full, repoName: (repo["name"] as? String) ?? full,
                            isPullRequest: n["isDraft"] != nil, isDraft: (n["isDraft"] as? Bool) ?? false,
                            reviewDecision: n["reviewDecision"] as? String, checksState: roll?["state"] as? String,
                            author: a, updatedAt: date, viaTeam: team)
        }
        var lists = WorkLists(loaded: true, error: problem)
        for n in nodes("reviews") {
            if let item = parse(n, team: !directIds.contains(n["id"] as? String ?? "")) { lists.reviews.append(item) }
        }
        for n in nodes("assigned") {
            if let item = parse(n, team: false) { lists.assigned.append(item) }
        }
        lists.reviews.sort { $0.updatedAt > $1.updatedAt }
        lists.assigned.sort { $0.updatedAt > $1.updatedAt }
        last = lists
        onUpdate(lists)
    }

    /// Keeps the last good lists on screen and says why they are not fresh.
    private func fail(_ reason: String) {
        logger.error("work poll failed: \(reason)")
        last.error = reason
        onUpdate(last)
    }
}
