import SwiftUI

struct InboxView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.searching {
                Hairline()
                searchBar
            }
            Hairline()
            if let issue = model.issue { IssueBanner(issue: issue) }
            ScrollViewReader { proxy in
                content
                    .onChange(of: model.cursor) { _, c in
                        if let c { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(c) } }
                    }
            }
            if model.tab == .inbox, !model.snoozedThreads.isEmpty {
                Hairline()
                snoozedBar
            }
            Hairline()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { t in
                TabButton(title: t.rawValue, count: model.count(for: t), active: model.tab == t) {
                    withAnimation(.easeOut(duration: 0.15)) { model.tab = t }
                }
            }
            Spacer(minLength: 4)
            Button { model.searching ? model.endSearch() : model.startSearch() } label: {
                Icon(name: "search", size: 15).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.searching ? .primary : .secondary)
            .focusEffectDisabled()
            .help("Filter (/)")
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 0)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Icon(name: "search", size: 14).foregroundStyle(.tertiary)
            TextField("Filter by repository, title or author", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Icon(name: "cancel-circle", size: 14) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onChange(of: model.query) { model.cursor = nil }
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .assigned: workList(model.visibleWork(model.work.assigned), empty: "Nothing assigned to you.")
        case .reviews: workList(model.visibleWork(model.work.reviews), empty: "No reviews waiting on you.")
        default:
            let items = model.visible
            if items.isEmpty, model.lastSync == nil, model.issue == nil {
                loadingState("Syncing your notifications…")
            } else if items.isEmpty {
                emptyState(model.showSnoozed ? "Nothing snoozed." : "You're all caught up.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.grouped {
                            ForEach(model.groups) { g in
                                let collapsed = prefs.collapsedRepos.contains(g.id)
                                GroupHeader(group: g, collapsed: collapsed)
                                if !collapsed {
                                    ForEach(g.threads) { row($0, showRepo: false) }
                                }
                            }
                        } else {
                            ForEach(items) { row($0, showRepo: true) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ t: NotificationThread, showRepo: Bool) -> some View {
        ThreadRow(thread: t, details: model.details[t.id], focused: model.cursor == t.id, showRepo: showRepo, snoozedUntil: prefs.snoozed[t.id])
            .contentShape(Rectangle())
            .onTapGesture { model.selected = t }
            .contextMenu { ThreadActions(thread: t) }
            .id(t.id)
    }

    private func workList(_ items: [WorkItem], empty: String) -> some View {
        Group {
            if items.isEmpty, let error = model.work.error {
                workError(error)
            } else if items.isEmpty, !model.work.loaded {
                loadingState("Loading…")
            } else if items.isEmpty {
                emptyState(empty)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            WorkRow(item: item, focused: model.cursor == item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.show(item) }
                                .id(item.id)
                        }
                    }
                }
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        let filtering = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: 6) {
            Spacer()
            Icon(name: filtering ? "search" : "check-circle", size: 28)
                .foregroundStyle(.tertiary)
            Text(filtering ? "Nothing matches \u{201C}\(model.query)\u{201D}." : text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private func loadingState(_ text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// An empty Assigned or Reviews list that failed to load must not read as "nothing to do".
    private func workError(_ reason: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Icon(name: "alert", size: 28).foregroundStyle(.orange)
            Text("Couldn't load this list").font(.callout)
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .textSelection(.enabled)
            Button("Retry") { model.refresh() }.controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private var snoozedBar: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { model.showSnoozed.toggle() } } label: {
            HStack(spacing: 6) {
                Icon(name: model.showSnoozed ? "chevron-left" : "clock", size: 13)
                Text(model.showSnoozed ? "Back to inbox" : "\(model.snoozedThreads.count) snoozed")
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let u = model.user {
                Avatar(url: u.avatarUrl, size: 16)
                Text(u.login).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let v = model.updater.availableVersion {
                Button("Update to \(v)") { Task { await model.updater.install() } }
                    .controlSize(.small)
                    .help("Download, install and relaunch")
            } else if case .installing = model.updater.state {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = model.lastSync {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    // Two minutes without a sync is well past any poll interval, so say so.
                    let age = -d.timeIntervalSinceNow, stale = age > 120
                    Text(age < 60 ? "Synced just now" : age < 86400 * 7 ? "Synced \(Appearance.relative(d)) ago" : "Last synced \(Appearance.relative(d))")
                        .font(.system(size: 12))
                        .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                }
            }
            Button { model.refresh() } label: { Icon(name: "refresh", size: 16) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .focusEffectDisabled()
                .help("Refresh (⌘R)")
            Menu {
                Button("Mark all as read") { model.markAllVisibleRead() }
                Toggle("Group by repository", isOn: $prefs.groupByRepo)
                Button("Settings…") { model.onOpenSettings?() }
                Divider()
                Button("Sign out") { model.signOut() }
                Button("Quit GitMenu") { NSApp.terminate(nil) }
            } label: {
                Icon(name: "more", size: 16).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct IssueBanner: View {
    @EnvironmentObject var model: AppModel
    let issue: SyncIssue

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Icon(name: "alert", size: 15).foregroundStyle(.orange).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title).font(.system(size: 12, weight: .semibold))
                    Text(issue.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if issue == .unauthenticated {
                    Button("Sign in again") { model.signOut() }.controlSize(.small)
                } else {
                    Button("Retry") { model.refresh() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
            Hairline()
        }
    }
}

struct GroupHeader: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    let group: RepoGroup
    let collapsed: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Icon(name: collapsed ? "chevron-right" : "chevron-down", size: 12).foregroundStyle(.tertiary)
            Avatar(url: group.avatarUrl, size: 14, rounded: false)
            Text(group.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if hovering {
                Button("Mark all done") { model.markDone(group.threads) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Mark every notification in \(group.name) as done")
            } else {
                Text(group.unread > 0 ? "\(group.unread) unread" : "\(group.threads.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Color.primary.opacity(hovering ? 0.07 : 0.035))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) {
                if collapsed { prefs.collapsedRepos.remove(group.id) } else { prefs.collapsedRepos.insert(group.id) }
            }
        }
        .onHover { hovering = $0 }
    }
}

struct TabButton: View {
    let title: String
    let count: Int
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                HStack(spacing: 5) {
                    Text(title)
                    if count > 0 {
                        Text(String(count))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(active ? .primary : .secondary)
                Rectangle()
                    .fill(active ? Color.primary : .clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, 6)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

struct WorkRow: View {
    @EnvironmentObject var model: AppModel
    let item: WorkItem
    var focused = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 3) {
                Icon(name: Appearance.glyph(type: item.subjectType, state: item.state), size: 20)
                    .foregroundStyle(Appearance.stateColor(item.state))
                    .frame(width: 24, height: 22)
                Text(String(item.number))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(width: 28)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(item.isPullRequest ? (item.viaTeam ? "Team review requested" : "Review requested") : "Opened").fixedSize()
                        if let a = item.author {
                            Text("by").foregroundStyle(.tertiary)
                            Text(a.login).fixedSize()
                            Avatar(url: a.avatarUrl, size: 16)
                        }
                        Text("in").foregroundStyle(.tertiary)
                        Text(item.repoName).truncationMode(.tail)
                    }
                    .font(.system(size: 13))
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    if hovering {
                        Button { model.open(item) } label: { Icon(name: "arrow-up-right", size: 16).frame(width: 24, height: 24) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .transition(.opacity)
                    } else {
                        Text(Appearance.relative(item.updatedAt))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .frame(height: 20)
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                StatusBadges(isDraft: item.isDraft, reviewDecision: item.reviewDecision, checksState: item.checksState)
                    .frame(height: 18, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(height: 82)
        .background(Color.primary.opacity(focused ? 0.09 : hovering ? 0.06 : 0))
        .overlay(alignment: .leading) { if focused { Rectangle().fill(Color.accentColor).frame(width: 2) } }
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hovering = h } }
    }
}

struct ThreadRow: View {
    @EnvironmentObject var model: AppModel
    let thread: NotificationThread
    let details: ThreadDetails?
    var focused = false
    var showRepo = true
    var snoozedUntil: Date?
    @State private var hovering = false

    private var state: SubjectState { details?.state ?? .none }
    private var repoName: String { thread.repository.name }
    private var subjectKind: String {
        switch thread.subject.type {
        case "PullRequest": return "Pull request"
        case "Issue": return "Issue"
        case "Release": return "Release"
        case "Discussion": return "Discussion"
        case "Commit": return "Commit"
        case "CheckSuite", "WorkflowRun": return "Workflow run"
        default: return "Activity"
        }
    }
    private var newCount: Int { details?.newActivities(since: thread.lastReadAt).count ?? 0 }

    /// The event that caused this notification: the latest activity when it lines up with `updated_at`, else the reason.
    private var event: (verb: String, actor: ThreadDetails.Actor?)? {
        guard let a = details?.latestActivity, abs(a.createdAt.timeIntervalSince(thread.updatedAt)) < 180 else { return nil }
        switch a.kind {
        case "comment": return ("Commented", a.author)
        case "review:approved": return ("Approved", a.author)
        case "review:changes_requested": return ("Changes requested", a.author)
        case "review:commented": return ("Reviewed", a.author)
        case "review_requested": return ("Review requested", a.author)
        case "assigned": return ("Assigned", a.author)
        case "merged": return ("Merged", a.author)
        case "closed": return ("Closed", a.author)
        case "reopened": return ("Reopened", a.author)
        default: return nil
        }
    }

    /// Comments and reviews preview their own text; events (review requested, merged, closed...) preview the description.
    private var preview: String? {
        var text: String? = details?.body
        if let a = details?.latestActivity, a.kind == "comment" || a.kind.hasPrefix("review:"), !a.body.isEmpty { text = a.body }
        if thread.subject.type == "CheckSuite" || thread.subject.type == "WorkflowRun" { text = nil }
        return text?.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("<!--") }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 3) {
                Icon(name: Appearance.glyph(type: thread.subject.type, state: state), size: 20)
                    .foregroundStyle(Appearance.stateColor(state))
                    .frame(width: 24, height: 22)
                if hovering, let n = details?.number ?? thread.subjectNumber {
                    Text(String(n))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(width: 28)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 0) {
                    metaLine.lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 8)
                    if hovering { actions.transition(.opacity.combined(with: .move(edge: .trailing))) } else { timeLabel.transition(.opacity) }
                }
                .frame(height: 20)
                Text(thread.subject.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(thread.unread ? .primary : .secondary)
                Group {
                    if hovering, let p = preview {
                        MarkdownText(source: p, lineLimit: 1).foregroundStyle(.secondary)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        StatusBadges(reviewDecision: details?.reviewDecision, checksState: details?.checksState)
                    }
                }
                .frame(height: 18, alignment: .leading)
                .clipped()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(height: 82)
        .background(Color.primary.opacity(focused ? 0.09 : hovering ? 0.06 : 0))
        .overlay(alignment: .leading) { if focused { Rectangle().fill(Color.accentColor).frame(width: 2) } }
        .overlay(alignment: .topTrailing) {
            if thread.unread {
                if newCount > 1 {
                    Text(String(newCount))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(.orange, in: Capsule())
                        .padding(.top, 5).padding(.trailing, 6)
                } else {
                    Circle().fill(.orange).frame(width: 7, height: 7).padding(.top, 7).padding(.trailing, 8)
                }
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hovering = h } }
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            let e = event
            Text(e?.verb ?? (thread.reason == "subscribed" ? subjectKind : Reason.phrase(thread.reason)))
                .foregroundStyle(.primary)
                .fixedSize()
            if let actor = e?.actor {
                Text("by").foregroundStyle(.tertiary).fixedSize()
                Text(actor.login).foregroundStyle(.primary).fixedSize()
                Avatar(url: actor.avatarUrl, size: 16)
            }
            if showRepo {
                Text("in").foregroundStyle(.tertiary).fixedSize()
                Text(repoName).foregroundStyle(.primary).truncationMode(.tail)
            }
        }
        .font(.system(size: 13))
    }

    private var timeLabel: some View {
        HStack(spacing: 4) {
            if let until = snoozedUntil {
                Icon(name: "clock", size: 12)
                Text(until.formatted(Calendar.current.isDateInToday(until) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()))
            } else {
                Text(Appearance.relative(thread.updatedAt))
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Menu {
                ThreadActions(thread: thread)
            } label: {
                Icon(name: "more", size: 16).frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            Button { model.open(thread) } label: {
                Icon(name: "arrow-up-right", size: 16).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Open on GitHub")
            Button { model.markDone(thread) } label: {
                Icon(name: "tick", size: 16)
                    .frame(width: 30, height: 24)
                    .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Mark done")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)
    }
}
