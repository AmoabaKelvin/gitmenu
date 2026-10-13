import SwiftUI

struct ThreadDetailView: View {
    @EnvironmentObject var model: AppModel
    let thread: NotificationThread
    /// Set when showing an assigned or review item, which has no notification behind it.
    var work: WorkItem? = nil

    private var details: ThreadDetails? {
        if let work { return model.workDetails[work.id] }
        return model.details[thread.id]
    }
    private var state: SubjectState { details?.state ?? work?.state ?? .none }
    private var reviewDecision: String? { details?.reviewDecision ?? work?.reviewDecision }
    private var checksState: String? { details?.checksState ?? work?.checksState }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    facts
                    timeline
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            HStack {
                Text("Updated \(Appearance.relative(thread.updatedAt)) ago")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button { if let work { model.open(work) } else { model.open(thread) } } label: {
                    HStack(spacing: 6) { Icon(name: "arrow-up-right", size: 14); Text("Open on GitHub") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .onAppear { if work == nil { model.markRead(thread) } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.closeDetail() } label: {
                HStack(spacing: 2) { Icon(name: "chevron-left", size: 14); Text(work == nil ? "Inbox" : model.tab.rawValue) }
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
            Spacer()
            if let work {
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(work.url, forType: .string)
                }
                .controlSize(.small)
            } else {
                Button("Mark done") { model.markDone(thread) }
                    .controlSize(.small)
                    .keyboardShortcut("e", modifiers: [])
                Menu {
                    ThreadActions(thread: thread)
                } label: { Icon(name: "more", size: 16) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Icon(name: Appearance.glyph(type: thread.subject.type, state: state), size: 15)
                    .foregroundStyle(Appearance.stateColor(state))
                if let n = details?.number ?? thread.subjectNumber, let url = URL(string: details?.htmlUrl ?? work?.url ?? thread.repository.htmlUrl) {
                    Link("#" + String(n), destination: url)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                        .help("Open on GitHub")
                }
            }
            Text(thread.subject.title)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                factLabel("Status")
                HStack(spacing: 10) {
                    Text(statusText).foregroundStyle(Appearance.stateColor(state))
                    if let r = reviewDecision, let (icon, text, color) = reviewBadge(r) {
                        HStack(spacing: 4) { Icon(name: icon, size: 14); Text(text) }
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if let c = checksState {
                        Icon(name: c == "SUCCESS" ? "check-circle" : (c == "FAILURE" || c == "ERROR") ? "cancel-circle" : "clock", size: 15)
                            .foregroundStyle(c == "SUCCESS" ? Appearance.stateColor(.open) : (c == "FAILURE" || c == "ERROR") ? Appearance.stateColor(.closed) : .orange)
                            .help("Checks: \(c.lowercased())")
                    }
                }
            }
            if let a = details?.author ?? work?.author {
                GridRow {
                    factLabel("Author")
                    HStack(spacing: 6) { Avatar(url: a.avatarUrl, size: 18); Text(a.login) }
                }
            }
            GridRow {
                factLabel("Repository")
                Text(thread.repository.fullName).textSelection(.enabled)
            }
            if thread.reason != "subscribed" {
                GridRow {
                    factLabel("Reason")
                    Text(Reason.phrase(thread.reason))
                }
            }
            if let labels = details?.labels, !labels.isEmpty {
                GridRow {
                    factLabel("Labels")
                    HStack(spacing: 6) {
                        ForEach(labels, id: \.name) { l in
                            HStack(spacing: 5) {
                                Circle().fill(Color(hex: l.color)).frame(width: 8, height: 8)
                                Text(l.name)
                            }
                        }
                    }
                }
            }
        }
        .font(.system(size: 13))
    }

    private func factLabel(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
    }

    private func reviewBadge(_ r: String) -> (String, String, Color)? {
        switch r {
        case "APPROVED": return ("check-circle", "Approved", Appearance.stateColor(.open))
        case "CHANGES_REQUESTED": return ("alert", "Changes requested", Appearance.stateColor(.closed))
        case "REVIEW_REQUIRED": return ("eye", "Review required", .secondary)
        default: return nil
        }
    }

    private var statusText: String {
        switch (thread.subject.type, state) {
        case (_, .merged): return "Merged"
        case (_, .draft): return "Draft"
        case (_, .closed): return "Closed"
        case (_, .open): return "Open"
        case ("Release", _): return "Released"
        case ("CheckSuite", _), ("WorkflowRun", _): return "Workflow run"
        default: return thread.subject.type
        }
    }

    @ViewBuilder private var timeline: some View {
        let all = details?.activities ?? []
        if work != nil {
            // No read marker to split on, so the description leads and the activity follows in one run.
            if details == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading activity…").foregroundStyle(.secondary) }
                    .font(.system(size: 13))
            }
            description
            if !all.isEmpty { timelineSection("Activity", all.reversed()) }
        } else {
            let fresh = Set((details?.newActivities(since: thread.lastReadAt) ?? []).map(\.id))
            let new = all.filter { fresh.contains($0.id) }.reversed()
            let earlier = all.filter { !fresh.contains($0.id) }.reversed()
            if !new.isEmpty { timelineSection("New", Array(new)) }
            if !earlier.isEmpty { timelineSection("Earlier", Array(earlier)) }
            if all.isEmpty { description }
        }
    }

    @ViewBuilder private var description: some View {
        if let b = details?.body, !b.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Description").font(.system(size: 15, weight: .semibold))
                MarkdownText(source: b, lineLimit: 14).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func timelineSection(_ title: String, _ items: [ThreadDetails.Activity]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            ForEach(items) { a in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        if let au = a.author {
                            Avatar(url: au.avatarUrl, size: 20)
                        } else {
                            Icon(name: "user", size: 20).foregroundStyle(.tertiary)
                        }
                        Text(headline(a)).font(.system(size: 13))
                        Spacer()
                        Text(Appearance.relative(a.createdAt)).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if !a.body.isEmpty && (a.kind == "comment" || a.kind.hasPrefix("review:")) {
                        MarkdownText(source: a.body, lineLimit: 12)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.leading, 12)
                            .overlay(alignment: .leading) { Rectangle().fill(.primary.opacity(0.15)).frame(width: 2) }
                            .padding(.leading, 30)
                    }
                }
            }
        }
    }

    private func headline(_ a: ThreadDetails.Activity) -> String {
        let who = a.author?.login ?? "Someone"
        switch a.kind {
        case "comment": return "Comment by \(who)"
        case "review:approved": return "Approved by \(who)"
        case "review:changes_requested": return "Changes requested by \(who)"
        case "review:commented", "review:dismissed", "review:pending": return "Review by \(who)"
        case "review_requested": return a.body.isEmpty ? "Review requested" : "Review requested from \(a.body)"
        case "assigned": return a.body.isEmpty ? "Assigned" : "Assigned to \(a.body)"
        case "merged": return "Merged by \(who)"
        case "closed": return "Closed by \(who)"
        case "reopened": return "Reopened by \(who)"
        case "ready_for_review": return "Marked ready for review"
        default: return a.kind.capitalized
        }
    }
}

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt64(h, radix: 16) ?? 0x999999
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
