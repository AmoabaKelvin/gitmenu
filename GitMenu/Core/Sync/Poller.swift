import Foundation
import AppKit
import Network

struct SyncDelta {
    var added: [NotificationThread] = []
    var updated: [NotificationThread] = []
    var isFirstSync = false
    var previousNewest: Date = .distantPast
}

/// Polls GET /notifications every few seconds and on every event that suggests something changed:
/// wake, network return, panel open, our own mutations.
@MainActor
final class Poller {
    private let client: GitHubClient
    private let store: Store
    private let enricher: Enricher
    private let onDelta: (SyncDelta) -> Void
    private let onStatus: (String?) -> Void

    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var online = true
    private var activity: NSObjectProtocol?
    /// Same cadence as Neat. 304 responses are free, so this costs nothing until GitHub says otherwise.
    private let pollInterval: TimeInterval = 5
    private let fullWalkEvery = 120
    private var backoffUntil: Date = .distantPast
    private var pollCount = 0
    private var syncing = false
    private var pendingResync = false
    private var lastSyncStart: Date = .distantPast

    init(client: GitHubClient, store: Store, enricher: Enricher, onDelta: @escaping (SyncDelta) -> Void, onStatus: @escaping (String?) -> Void) {
        self.client = client
        self.store = store
        self.enricher = enricher
        self.onDelta = onDelta
        self.onStatus = onStatus
    }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Polling GitHub notifications")
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { await self?.syncNow(reason: "wake") } }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { await self?.syncNow(reason: "screen wake") } }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let was = self.online
                self.online = path.status == .satisfied
                if self.online && !was { await self.syncNow(reason: "network") }
            }
        }
        m.start(queue: .global(qos: .utility))
        pathMonitor = m
        reschedule()
        Task { await syncNow(reason: "launch") }
    }

    func stop() {
        timer?.invalidate()
        pathMonitor?.cancel()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
    }

    private func reschedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow(reason: "timer") }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Coalesces: a sync requested while one is running triggers exactly one follow-up.
    func syncNow(reason: String, force: Bool = false) async {
        if syncing { pendingResync = true; return }
        if !force && !online { return }
        if !force && Date() < backoffUntil { return }
        if !force && Date().timeIntervalSince(lastSyncStart) < 2 { return }
        syncing = true
        lastSyncStart = Date()
        logger.info("sync start: \(reason) force=\(force)")
        defer {
            syncing = false
            if pendingResync { pendingResync = false; Task { await syncNow(reason: "coalesced") } }
        }
        do {
            try await sync(force: force)
            onStatus(nil)
        } catch {
            logger.error("sync failed: \(error.localizedDescription)")
            if case GitHubError.http(let code, _) = error, code == 403 || code == 429 {
                backoffUntil = Date().addingTimeInterval(120)
                logger.error("rate limited; backing off for 2 minutes")
            }
            onStatus(error.localizedDescription)
        }
    }

    /// Delta polls send If-Modified-Since, which GitHub treats as "threads updated since", read or not.
    /// A full walk lists everything not yet done (`all=true`) plus the unread list, so threads read or
    /// done on another client are reconciled here.
    private func sync(force: Bool) async throws {
        pollCount += 1
        let fullWalk = force || !store.state.fullSyncDone || pollCount % fullWalkEvery == 0
        let ifModified = fullWalk ? nil : store.state.lastModified
        let known = store.state.threads
        let previousNewest = known.values.map(\.updatedAt).max() ?? .distantPast

        var fetched: [NotificationThread] = []
        var page = 1
        var lastModified: String?
        while page <= 60 {
            let p = try await client.notifications(page: page, all: true, ifModifiedSince: page == 1 ? ifModified : nil)
            if p.notModified { logger.info("304 not modified"); return }
            if page == 1 { lastModified = p.lastModified }
            fetched += p.threads
            if !p.hasNext { break }
            page += 1
        }

        var nowRead: [NotificationThread] = []
        var doneElsewhere: [String] = []
        if fullWalk {
            doneElsewhere = known.keys.filter { id in !fetched.contains { $0.id == id } }
            var unread: [NotificationThread] = []
            var upage = 1
            while upage <= 60 {
                let p = try await client.notifications(page: upage, all: false, ifModifiedSince: nil)
                unread += p.threads
                if !p.hasNext { break }
                upage += 1
            }
            let unreadIds = Set(unread.map(\.id))
            let fetchedIds = Set(fetched.map(\.id))
            fetched += unread.filter { !fetchedIds.contains($0.id) }
            nowRead = known.values.filter { $0.unread && !unreadIds.contains($0.id) }.map { $0.with(unread: false) }
            page += upage
        }

        var bySubject: [String: NotificationThread] = [:]
        for t in fetched {
            let key = t.subject.url ?? t.id
            if let e = bySubject[key], e.updatedAt >= t.updatedAt { continue }
            bySubject[key] = t
        }
        fetched = Array(bySubject.values)

        var delta = SyncDelta(isFirstSync: !store.state.fullSyncDone, previousNewest: previousNewest)
        for t in fetched {
            if let old = known[t.id] {
                if old.updatedAt != t.updatedAt || old.unread != t.unread { delta.updated.append(t) }
            } else {
                delta.added.append(t)
            }
        }

        let needDetails = (delta.added + delta.updated).filter { t in
            store.state.details[t.id] == nil || known[t.id]?.updatedAt != t.updatedAt
        }
        let details = needDetails.isEmpty ? [:] : await enricher.enrich(needDetails)

        store.update { s in
            for t in fetched { s.threads[t.id] = t }
            for t in nowRead { s.threads[t.id] = t }
            for id in doneElsewhere { s.threads[id] = nil; s.details[id] = nil }
            for (k, v) in details { s.details[k] = v }
            let history = s.threads.values.filter { !$0.unread }.sorted { $0.updatedAt > $1.updatedAt }
            for t in history.dropFirst(300) { s.threads[t.id] = nil; s.details[t.id] = nil }
            s.lastModified = lastModified ?? s.lastModified
            s.lastSync = Date()
            s.fullSyncDone = true
        }
        logger.info("sync done: full=\(fullWalk) fetched=\(fetched.count) requests=\(page) added=\(delta.added.count) updated=\(delta.updated.count) nowRead=\(nowRead.count) done=\(doneElsewhere.count) enriched=\(details.count)")
        onDelta(delta)
    }

    func applyLocal(_ f: (inout StoreState) -> Void) {
        store.update(f)
    }
}
