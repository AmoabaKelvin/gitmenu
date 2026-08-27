import SwiftUI

struct InboxView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
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
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 0)
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .assigned: workList(model.work.assigned, empty: "Nothing assigned to you.")
        case .reviews: workList(model.work.reviews, empty: "No reviews waiting on you.")
        default:
            let items = model.visible
            if items.isEmpty {
                emptyState("You're all caught up.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { t in
                            ThreadRow(thread: t, details: model.details[t.id])
                                .contentShape(Rectangle())
                                .onTapGesture { model.selected = t }
                                .contextMenu {
                                    Button("Open on GitHub") { model.open(t) }
                                    Button("Mark as read") { model.markRead(t) }.disabled(!t.unread)
                                    Button("Mark as done") { model.markDone(t) }
                                    Divider()
                                    Button("Mute thread") { model.mute(t) }
                                }
                                .id(t.id)
                        }
                    }
                }
            }
        }
    }

    private func workList(_ items: [WorkItem], empty: String) -> some View {
        Group {
            if items.isEmpty {
                emptyState(empty)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            WorkRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture { model.open(item) }
                        }
                    }
                }
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Icon(name: "check-circle", size: 28)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let u = model.user {
                Avatar(url: u.avatarUrl, size: 16)
                Text(u.login).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let s = model.status {
                Label(s, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(s)
            } else if let d = model.lastSync {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("Synced \(Appearance.relative(d)) ago")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            Button { model.refresh() } label: { Icon(name: "refresh", size: 16) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .focusEffectDisabled()
                .help("Refresh")
            Menu {
                Button("Mark all as read") { model.markAllVisibleRead() }
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Button("Send test notification") { model.notifier.postTest() }
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
                HStack(spacing: 6) {
                    if item.isDraft { Text("Draft").foregroundStyle(.secondary) }
                    if let r = item.reviewDecision {
                        Text(r.replacingOccurrences(of: "_", with: " ").lowercased().capitalized)
                            .foregroundStyle(r == "APPROVED" ? Appearance.stateColor(.open) : r == "CHANGES_REQUESTED" ? Appearance.stateColor(.closed) : .secondary)
                    }
                    if let c = item.checksState {
                        HStack(spacing: 4) {
                            Circle().fill(c == "SUCCESS" ? Appearance.stateColor(.open) : c == "FAILURE" || c == "ERROR" ? Appearance.stateColor(.closed) : .orange).frame(width: 6, height: 6)
                            Text("Checks " + c.lowercased()).foregroundStyle(.secondary)
                        }
                    }
                    Text(" ")
                }
                .font(.system(size: 12))
                .frame(height: 18, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(height: 82)
        .background(Color.primary.opacity(hovering ? 0.06 : 0))
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hovering = h } }
    }
}

struct ThreadRow: View {
    @EnvironmentObject var model: AppModel
    let thread: NotificationThread
    let details: ThreadDetails?
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
                    metaLine.lineLimit(1)
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
                        Text(" ").font(.system(size: 13))
                    }
                }
                .frame(height: 18, alignment: .leading)
                .clipped()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(height: 82)
        .background(Color.primary.opacity(hovering ? 0.06 : 0))
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
                Text("by").foregroundStyle(.tertiary)
                Text(actor.login).foregroundStyle(.primary).fixedSize()
                Avatar(url: actor.avatarUrl, size: 16)
            }
            Text("in").foregroundStyle(.tertiary)
            Text(repoName).foregroundStyle(.primary).truncationMode(.tail)
        }
        .font(.system(size: 13))
    }

    private var timeLabel: some View {
        Text(Appearance.relative(thread.updatedAt))
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Mark as read") { model.markRead(thread) }.disabled(!thread.unread)
                Button("Mute thread") { model.mute(thread) }
                if let u = model.webUrl(thread) {
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(u.absoluteString, forType: .string)
                    }
                }
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
