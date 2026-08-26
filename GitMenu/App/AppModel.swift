import Foundation
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

enum AuthState: Equatable {
    case signedOut
    case deviceCode(code: String, url: String)
    case signedIn
}

enum Tab: String, CaseIterable, Identifiable {
    case inbox = "Inbox", forYou = "For you", assigned = "Assigned", reviews = "Reviews"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var threads: [NotificationThread] = []
    @Published private(set) var details: [String: ThreadDetails] = [:]
    @Published private(set) var auth: AuthState = .signedOut
    @Published private(set) var user: GitHubClient.User?
    @Published var status: String?
    @Published var lastSync: Date?
    @Published var tab: Tab = .inbox
    @Published private(set) var work = WorkLists()
    @Published var selected: NotificationThread?
    @Published var signInError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet { try? launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    static let oauthClientId = UserDefaults.standard.string(forKey: "oauthClientId") ?? ""

    let notifier = Notifier()
    private let store = Store()
    private var client: GitHubClient!
    private var token: String?
    private var poller: Poller?
    private var workPoller: WorkPoller?
    var onUnreadChange: ((Int, Int) -> Void)?

    var unreadCount: Int { threads.filter(\.unread).count }
    var urgentUnreadCount: Int { threads.filter { $0.unread && Reason.urgent.contains($0.reason) }.count }

    /// Inbox: unread first, then read history. For you: unread mentions, review requests and assignments.
    var visible: [NotificationThread] {
        switch tab {
        case .forYou:
            return threads.filter { $0.unread && Reason.urgent.contains($0.reason) }.sorted { $0.updatedAt > $1.updatedAt }
        default:
            return threads.sorted { ($0.unread ? 1 : 0, $0.updatedAt) > ($1.unread ? 1 : 0, $1.updatedAt) }
        }
    }

    func count(for t: Tab) -> Int {
        switch t {
        case .inbox: return unreadCount
        case .forYou: return urgentUnreadCount
        case .assigned: return work.assigned.count
        case .reviews: return work.reviews.count
        }
    }

    init() {
        token = Keychain.read("token")
        client = GitHubClient(token: { [weak self] in self?.token })
        notifier.setup()
        notifier.onOpen = { [weak self] id in self?.openById(id) }
        notifier.onDone = { [weak self] id in self?.markDoneById(id) }
        loadFromStore()
        let hasToken = token != nil
        logger.info("launch: token present=\(hasToken)")
        if hasToken { Task { await finishSignIn() } }
    }

    private func loadFromStore() {
        threads = Array(store.state.threads.values)
        details = store.state.details
        lastSync = store.state.lastSync
        onUnreadChange?(unreadCount, urgentUnreadCount)
    }

    // MARK: Auth

    func signIn(pat: String) async {
        signInError = nil
        token = pat.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write("token", value: token!)
        await finishSignIn()
    }

    func signInWithDevice() async {
        signInError = nil
        let flow = DeviceFlow(clientId: Self.oauthClientId, host: "github.com")
        do {
            let code = try await flow.start()
            auth = .deviceCode(code: code.userCode, url: code.verificationUri)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code.userCode, forType: .string)
            NSWorkspace.shared.open(URL(string: code.verificationUri)!)
            token = try await flow.waitForToken(code)
            Keychain.write("token", value: token!)
            await finishSignIn()
        } catch {
            auth = .signedOut
            signInError = error.localizedDescription
        }
    }

    private func finishSignIn() async {
        do {
            let u = try await client.currentUser()
            user = u
            auth = .signedIn
            let enricher = Enricher(client: client, userId: u.id)
            let p = Poller(client: client, store: store, enricher: enricher,
                           onDelta: { [weak self] d in self?.handle(d) },
                           onStatus: { [weak self] s in self?.status = s })
            poller = p
            p.start()
            let w = WorkPoller(client: client) { [weak self] lists in self?.work = lists }
            workPoller = w
            w.start()
        } catch {
            logger.error("sign in failed: \(error.localizedDescription)")
            if case GitHubError.unauthenticated = error { Keychain.delete("token"); token = nil }
            auth = .signedOut
            signInError = error.localizedDescription
        }
    }

    func signOut() {
        poller?.stop()
        poller = nil
        workPoller?.stop()
        workPoller = nil
        work = WorkLists()
        if Snapshot.dir == nil {
            Keychain.delete("token")
            token = nil
            store.wipe()
        }
        threads = []
        details = [:]
        user = nil
        selected = nil
        auth = .signedOut
        onUnreadChange?(0, 0)
    }

    // MARK: Sync

    func refresh() { Task { await poller?.syncNow(reason: "manual", force: true); await workPoller?.refresh() } }
    func popoverOpened() { Task { await poller?.syncNow(reason: "popover"); await workPoller?.refresh() } }

    func open(_ item: WorkItem) {
        if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
    }

    private func handle(_ d: SyncDelta) {
        loadFromStore()
        if let s = selected, let fresh = store.state.threads[s.id] { selected = fresh }
        guard !d.isFirstSync else { return }
        let fresh = (d.added + d.updated).filter { $0.unread && $0.updatedAt > d.previousNewest }
        if fresh.count > 20 { logger.info("suppressing \(fresh.count) notifications from a bulk change"); return }
        for t in fresh { notifier.post(thread: t, details: details[t.id]) }
    }

    // MARK: Actions

    func webUrl(_ t: NotificationThread) -> URL? {
        guard let u = user else { return nil }
        let base = details[t.id]?.activities.last(where: { $0.htmlUrl != nil && abs($0.createdAt.timeIntervalSince(t.updatedAt)) < 120 })?.htmlUrl
            ?? details[t.id]?.htmlUrl ?? t.repository.htmlUrl
        return URL(string: Enricher(client: client, userId: u.id).referrerUrl(base, threadId: t.id))
    }

    func open(_ t: NotificationThread) {
        if let url = webUrl(t) { NSWorkspace.shared.open(url) }
        markRead(t)
    }

    func markRead(_ t: NotificationThread) {
        guard t.unread else { return }
        setLocal(t.id) { s in
            if let old = s.threads[t.id] { s.threads[t.id] = old.with(unread: false) }
        }
        notifier.clear(threadId: t.id)
        Task { try? await client.markRead(threadId: t.id); await poller?.syncNow(reason: "after mark read") }
    }

    func markDone(_ t: NotificationThread) {
        setLocal(t.id) { s in s.threads[t.id] = nil; s.details[t.id] = nil }
        if selected?.id == t.id { selected = nil }
        notifier.clear(threadId: t.id)
        Task { try? await client.markDone(threadId: t.id); await poller?.syncNow(reason: "after done") }
    }

    func mute(_ t: NotificationThread) {
        markDone(t)
        Task { try? await client.mute(threadId: t.id) }
    }

    func markAllVisibleRead() {
        let ids = visible.filter(\.unread).map(\.id)
        setLocal(nil) { s in for id in ids { if let o = s.threads[id] { s.threads[id] = o.with(unread: false) } } }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        Task {
            if tab == .forYou {
                for id in ids { try? await client.markRead(threadId: id) }
            } else {
                try? await client.markAllRead()
            }
            await poller?.syncNow(reason: "after mark all", force: true)
        }
    }

    private func setLocal(_ id: String?, _ f: (inout StoreState) -> Void) {
        poller?.applyLocal(f)
        loadFromStore()
    }

    private func openById(_ id: String) {
        if let t = store.state.threads[id] { open(t) }
    }

    private func markDoneById(_ id: String) {
        if let t = store.state.threads[id] { markDone(t) }
    }
}

extension NotificationThread {
    func with(unread: Bool) -> NotificationThread {
        NotificationThread(id: id, unread: unread, reason: reason, updatedAt: updatedAt, lastReadAt: lastReadAt,
                           subject: subject, repository: repository, url: url, subscriptionUrl: subscriptionUrl)
    }
}
