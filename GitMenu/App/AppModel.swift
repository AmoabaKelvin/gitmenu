import Foundation
import AppKit
import Combine
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

struct RepoGroup: Identifiable {
    let name: String
    let avatarUrl: String
    let threads: [NotificationThread]
    var id: String { name }
    var unread: Int { threads.filter(\.unread).count }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var threads: [NotificationThread] = []
    @Published private(set) var details: [String: ThreadDetails] = [:]
    @Published private(set) var auth: AuthState = .signedOut
    @Published private(set) var user: GitHubClient.User?
    @Published private(set) var issue: SyncIssue? { didSet { onMenuBarChange?() } }
    @Published var lastSync: Date?
    @Published var tab: Tab = .inbox { didSet { cursor = nil; showSnoozed = false } }
    @Published var query = ""
    @Published var searching = false
    /// Row the keyboard is on: a thread id, or a work item id on the Assigned and Reviews tabs.
    @Published var cursor: String?
    @Published var showSnoozed = false
    @Published private(set) var snoozedThreads: [NotificationThread] = []
    @Published private(set) var work = WorkLists()
    @Published var selected: NotificationThread?
    /// Assigned or review item open in the detail view.
    @Published private(set) var selectedWork: WorkItem?
    @Published private(set) var workDetails: [String: ThreadDetails] = [:]
    @Published var signInError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet { try? launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    static let oauthClientId = UserDefaults.standard.string(forKey: "oauthClientId") ?? ""

    let notifier = Notifier()
    let prefs = Prefs()
    let updater = Updater()
    private let store = Store()
    private var client: GitHubClient!
    private var token: String?
    private var poller: Poller?
    private var workPoller: WorkPoller?
    private var prefsSink: AnyCancellable?
    private var updaterSink: AnyCancellable?
    private var autoUpdateCheck = false
    /// Hidden until GitHub confirms the delete, so a poll in between cannot bring them back.
    private var pendingDone: Set<String> = []
    var onMenuBarChange: (() -> Void)?
    var onPrefsChange: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    var unreadCount: Int { threads.filter(\.unread).count }
    var urgentUnreadCount: Int { threads.filter { $0.unread && Reason.urgent.contains($0.reason) }.count }

    /// Inbox: unread first, then read history. For you: unread mentions, review requests and assignments.
    var visible: [NotificationThread] {
        if showSnoozed {
            return snoozedThreads.filter(matches).sorted { (prefs.snoozed[$0.id] ?? .distantFuture) < (prefs.snoozed[$1.id] ?? .distantFuture) }
        }
        switch tab {
        case .forYou:
            return threads.filter { $0.unread && Reason.urgent.contains($0.reason) && matches($0) }.sorted { $0.updatedAt > $1.updatedAt }
        default:
            return threads.filter(matches).sorted { ($0.unread ? 1 : 0, $0.updatedAt) > ($1.unread ? 1 : 0, $1.updatedAt) }
        }
    }

    var grouped: Bool { prefs.groupByRepo && (tab == .inbox || tab == .forYou) && !showSnoozed }

    /// Repositories in the order their first thread appears in `visible`.
    var groups: [RepoGroup] {
        var order: [String] = []
        var byRepo: [String: [NotificationThread]] = [:]
        for t in visible {
            if byRepo[t.repository.fullName] == nil { order.append(t.repository.fullName) }
            byRepo[t.repository.fullName, default: []].append(t)
        }
        return order.map { RepoGroup(name: $0, avatarUrl: byRepo[$0]![0].repository.owner.avatarUrl, threads: byRepo[$0]!) }
    }

    private var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    func visibleWork(_ items: [WorkItem]) -> [WorkItem] {
        let q = needle
        guard !q.isEmpty else { return items }
        return items.filter { i in
            [i.title, i.repo, i.author?.login ?? "", "#\(i.number)"].contains { $0.lowercased().contains(q) }
        }
    }

    private func matches(_ t: NotificationThread) -> Bool {
        let q = needle
        guard !q.isEmpty else { return true }
        let d = details[t.id]
        let number = (d?.number ?? t.subjectNumber).map { "#\($0)" } ?? ""
        return [t.subject.title, t.repository.fullName, Reason.phrase(t.reason), d?.author?.login ?? "", d?.latestActivity?.author?.login ?? "", number]
            .contains { $0.lowercased().contains(q) }
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
        prefsSink = prefs.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.prefsChanged() }
        updaterSink = updater.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        syncUpdateSchedule()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.wakeSnoozed() } }
        RunLoop.main.add(t, forMode: .common)
    }

    private func prefsChanged() {
        poller?.setInterval(prefs.pollInterval)
        syncUpdateSchedule()
        loadFromStore()
        onPrefsChange?()
    }

    private func syncUpdateSchedule() {
        guard prefs.autoUpdateCheck != autoUpdateCheck, Snapshot.dir == nil else { return }
        autoUpdateCheck = prefs.autoUpdateCheck
        updater.schedule(enabled: autoUpdateCheck)
    }

    private func wanted(_ t: NotificationThread) -> Bool {
        !prefs.hiddenReasons.contains(t.reason) && !prefs.hiddenRepos.contains(t.repository.fullName)
    }

    private func loadFromStore() {
        let all = store.state.threads.values.filter { !pendingDone.contains($0.id) && wanted($0) }
        threads = all.filter { prefs.snoozed[$0.id] == nil }.map { prefs.resurfaced.contains($0.id) ? $0.with(unread: true) : $0 }
        snoozedThreads = all.filter { prefs.snoozed[$0.id] != nil }
        details = store.state.details
        lastSync = store.state.lastSync
        if showSnoozed && snoozedThreads.isEmpty { showSnoozed = false }
        onMenuBarChange?()
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
            let p = Poller(client: client, store: store, enricher: enricher, interval: prefs.pollInterval,
                           onDelta: { [weak self] d in self?.handle(d) },
                           onStatus: { [weak self] s in self?.issue = s })
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
        snoozedThreads = []
        user = nil
        selected = nil
        selectedWork = nil
        workDetails = [:]
        issue = nil
        query = ""
        searching = false
        auth = .signedOut
        onMenuBarChange?()
    }

    // MARK: Sync

    func refresh() { Task { await poller?.syncNow(reason: "manual", force: true); await workPoller?.refresh() } }
    func popoverOpened() {
        cursor = nil
        wakeSnoozed()
        Task { await poller?.syncNow(reason: "popover"); await workPoller?.refresh() }
    }

    func open(_ item: WorkItem) {
        if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
    }

    func workThread(_ item: WorkItem) -> NotificationThread {
        item.thread(reason: tab == .reviews ? "review_requested" : "assign")
    }

    /// Opens the item in the panel and loads its timeline; a cached copy stays up while it refreshes.
    func show(_ item: WorkItem) {
        selectedWork = item
        guard let u = user else { return }
        let t = workThread(item)
        Task {
            let d = await Enricher(client: client, userId: u.id).enrich([t])
            if let details = d[t.id] { workDetails[item.id] = details }
        }
    }

    func closeDetail() {
        selected = nil
        selectedWork = nil
    }

    private func handle(_ d: SyncDelta) {
        pruneSnoozes()
        loadFromStore()
        if let s = selected, let fresh = store.state.threads[s.id] { selected = fresh }
        guard !d.isFirstSync, prefs.bannersEnabled else { return }
        let fresh = (d.added + d.updated).filter { t in
            t.unread && t.updatedAt > d.previousNewest && prefs.snoozed[t.id] == nil && wanted(t)
                && !prefs.silencedReasons.contains(t.reason) && !prefs.silencedRepos.contains(t.repository.fullName)
        }
        if fresh.count > 20 { logger.info("suppressing \(fresh.count) notifications from a bulk change"); return }
        for t in fresh { notifier.post(thread: t, details: details[t.id], sound: prefs.playSound) }
    }

    // MARK: Snooze

    func snooze(_ t: NotificationThread, _ s: Snooze) {
        advanceCursor(past: [t.id])
        if selected?.id == t.id { selected = nil }
        notifier.clear(threadId: t.id)
        if prefs.resurfaced.contains(t.id) { prefs.resurfaced.remove(t.id) }
        prefs.snoozed[t.id] = s.date
        withAnimation(.easeOut(duration: 0.2)) { loadFromStore() }
    }

    func unsnooze(_ t: NotificationThread) {
        prefs.snoozed[t.id] = nil
        withAnimation(.easeOut(duration: 0.2)) { loadFromStore() }
    }

    /// Brings back threads whose snooze ran out: unread again, with a banner.
    private func wakeSnoozed() {
        let due = prefs.snoozed.filter { $0.value <= Date() }.keys
        guard !due.isEmpty else { return }
        for id in due {
            prefs.snoozed[id] = nil
            guard let t = store.state.threads[id] else { continue }
            prefs.resurfaced.insert(id)
            if prefs.bannersEnabled { notifier.post(thread: t, details: details[id], sound: prefs.playSound, note: "Back from snooze") }
        }
        loadFromStore()
    }

    /// Forgets snoozes for threads that were marked done somewhere else.
    private func pruneSnoozes() {
        guard store.state.fullSyncDone else { return }
        let known = store.state.threads
        let gone = prefs.snoozed.keys.filter { known[$0] == nil }
        for id in gone { prefs.snoozed[id] = nil }
        let stale = prefs.resurfaced.filter { known[$0] == nil }
        if !stale.isEmpty { prefs.resurfaced.subtract(stale) }
    }

    // MARK: Keyboard

    /// Ids of the rows on screen, top to bottom.
    private var navIds: [String] {
        switch tab {
        case .assigned: return visibleWork(work.assigned).map(\.id)
        case .reviews: return visibleWork(work.reviews).map(\.id)
        default:
            guard grouped else { return visible.map(\.id) }
            return groups.filter { !prefs.collapsedRepos.contains($0.id) }.flatMap { $0.threads.map(\.id) }
        }
    }

    private var cursorThread: NotificationThread? {
        guard tab == .inbox || tab == .forYou, let c = cursor else { return nil }
        return visible.first { $0.id == c }
    }

    private func moveCursor(_ delta: Int) {
        let ids = navIds
        guard !ids.isEmpty else { cursor = nil; return }
        guard let c = cursor, let i = ids.firstIndex(of: c) else { cursor = delta > 0 ? ids.first : ids.last; return }
        cursor = ids[min(max(i + delta, 0), ids.count - 1)]
    }

    /// Keeps the cursor on a neighbour when the rows under it are about to go away.
    private func advanceCursor(past removed: [String]) {
        guard let c = cursor, removed.contains(c) else { return }
        let ids = navIds
        guard let i = ids.firstIndex(of: c) else { cursor = nil; return }
        cursor = ids[(i + 1)...].first { !removed.contains($0) } ?? ids[..<i].last { !removed.contains($0) }
    }

    private func activateCursor() {
        if cursor == nil { moveCursor(1) }
        guard let c = cursor else { return }
        switch tab {
        case .assigned: work.assigned.first { $0.id == c }.map(show)
        case .reviews: work.reviews.first { $0.id == c }.map(show)
        default: selected = cursorThread
        }
    }

    func startSearch() {
        closeDetail()
        searching = true
    }

    func endSearch() {
        query = ""
        searching = false
    }

    /// Returns true when the key was used. `typing` is true while the search field has focus.
    func handleKey(_ e: NSEvent, typing: Bool) -> Bool {
        guard auth == .signedIn else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        let key = e.charactersIgnoringModifiers ?? ""
        if mods == .command {
            switch key {
            case "f": startSearch()
            case "r": refresh()
            default: return false
            }
            return true
        }
        guard mods.isEmpty else { return false }

        if let item = selectedWork {
            switch (e.keyCode, key) {
            case (53, _): selectedWork = nil
            case (36, _), (_, "o"): open(item)
            default: return false
            }
            return true
        }

        if let t = selected {
            switch (e.keyCode, key) {
            case (53, _): selected = nil
            case (36, _), (_, "o"): open(t)
            case (_, "e"): markDone(t)
            case (_, "M"): mute(t)
            case (_, "s"): snooze(t, .laterToday)
            case (_, "S"): snooze(t, .tomorrow)
            default: return false
            }
            return true
        }

        switch e.keyCode {
        case 53:
            if searching || !query.isEmpty { endSearch() } else if showSnoozed { showSnoozed = false } else { return false }
            return true
        case 125: moveCursor(1); return true
        case 126: moveCursor(-1); return true
        case 36: activateCursor(); return true
        default: break
        }
        if typing { return false }

        switch key {
        case "j": moveCursor(1)
        case "k": moveCursor(-1)
        case "/": startSearch()
        case "g": prefs.groupByRepo.toggle()
        case "1", "2", "3", "4": tab = Tab.allCases[Int(key)! - 1]
        default:
            guard let t = cursorThread else { return false }
            switch key {
            case "o": open(t)
            case "e": markDone(t)
            case "r": markRead(t)
            case "M": mute(t)
            case "s": snooze(t, .laterToday)
            case "S": snooze(t, .tomorrow)
            default: return false
            }
        }
        return true
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
        if prefs.resurfaced.contains(t.id) { prefs.resurfaced.remove(t.id); loadFromStore() }
        notifier.clear(threadId: t.id)
        Task { try? await client.markRead(threadId: t.id); await poller?.syncNow(reason: "after mark read") }
    }

    func markDone(_ t: NotificationThread) { markDone([t]) }

    func markDone(_ ts: [NotificationThread]) {
        let ids = ts.map(\.id)
        advanceCursor(past: ids)
        if let s = selected, ids.contains(s.id) { selected = nil }
        pendingDone.formUnion(ids)
        withAnimation(.easeOut(duration: 0.2)) {
            setLocal(nil) { s in for id in ids { s.threads[id] = nil; s.details[id] = nil } }
        }
        for id in ids {
            notifier.clear(threadId: id)
            if prefs.snoozed[id] != nil { prefs.snoozed[id] = nil }
            if prefs.resurfaced.contains(id) { prefs.resurfaced.remove(id) }
        }
        Task {
            for id in ids { try? await client.markDone(threadId: id) }
            pendingDone.subtract(ids)
            await poller?.syncNow(reason: "after done", force: ids.count > 1)
        }
    }

    func mute(_ t: NotificationThread) {
        markDone(t)
        Task { try? await client.mute(threadId: t.id) }
    }

    func markAllVisibleRead() {
        let ids = visible.filter(\.unread).map(\.id)
        let back = prefs.resurfaced.intersection(ids)
        if !back.isEmpty { prefs.resurfaced.subtract(back) }
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
