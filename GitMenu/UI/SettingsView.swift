import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs

    private static let shortcuts: [(keys: String, action: String)] = [
        ("J K or ↑ ↓", "Move through the list"),
        ("↩", "Open the thread, or open it on GitHub from the thread"),
        ("O", "Open on GitHub"),
        ("E", "Mark as done"),
        ("R", "Mark as read"),
        ("S / ⇧S", "Snooze for three hours / until tomorrow"),
        ("⇧M", "Mute the thread"),
        ("/ or ⌘F", "Filter"),
        ("G", "Group by repository"),
        ("1 – 4", "Switch tab"),
        ("⌘R", "Refresh"),
        ("Esc", "Go back, clear the filter, or close"),
    ]

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Show the unread count in the menu bar", isOn: $prefs.showCount)
                Toggle("Group the inbox by repository", isOn: $prefs.groupByRepo)
                LabeledContent("Open GitMenu from anywhere") { HotKeyRecorder() }
                Picker("Check GitHub every", selection: $prefs.pollInterval) {
                    Text("5 seconds").tag(5.0)
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("Minute").tag(60.0)
                }
            }

            Section {
                Toggle("Show banners for new activity", isOn: $prefs.bannersEnabled)
                Group {
                    Toggle("Play a sound for mentions, reviews and assignments", isOn: $prefs.playSound)
                    DisclosureGroup("Show banners for") {
                        ForEach(Reason.all, id: \.self) { r in
                            Toggle(Reason.phrase(r), isOn: Binding(
                                get: { !prefs.silencedReasons.contains(r) },
                                set: { on in if on { prefs.silencedReasons.remove(r) } else { prefs.silencedReasons.insert(r) } }))
                        }
                    }
                }
                .disabled(!prefs.bannersEnabled)
                Button("Send a test banner") { model.notifier.postTest() }
            } header: {
                Text("Banners")
            } footer: {
                Text("These only decide what interrupts you. Everything still shows in the inbox, and macOS Focus modes hold banners back as usual.")
            }

            Section {
                if prefs.silencedRepos.isEmpty {
                    Text("None. Right-click a notification to silence its repository.").foregroundStyle(.secondary)
                } else {
                    ForEach(prefs.silencedRepos.sorted(), id: \.self) { repo in
                        LabeledContent(repo) { Button("Remove") { prefs.silencedRepos.remove(repo) } }
                    }
                }
            } header: {
                Text("Silenced repositories")
            }

            Section("Keyboard") {
                ForEach(Self.shortcuts, id: \.keys) { s in
                    LabeledContent(s.action) { Text(s.keys).monospaced().foregroundStyle(.secondary) }
                }
            }

            if let u = model.user {
                Section("Account") {
                    LabeledContent("Signed in as \(u.login)") { Button("Sign out") { model.signOut() } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
    }
}

/// Click, then press a key with ⌘, ⌃ or ⌥ held. Esc cancels.
struct HotKeyRecorder: View {
    @EnvironmentObject var prefs: Prefs
    @State private var recording = false
    @State private var monitor: Any?

    private static let names: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑"]

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press a shortcut…" : prefs.hotKey?.display ?? "Record shortcut") {
                if recording { stop() } else { start() }
            }
            if prefs.hotKey != nil, !recording {
                Button("Clear") { prefs.hotKey = nil }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !mods.isDisjoint(with: [.command, .control, .option]) else { return nil }
            let label = Self.names[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").uppercased()
            guard !label.isEmpty else { return nil }
            prefs.hotKey = HotKeyCombo(keyCode: Int(e.keyCode), modifiers: mods.rawValue, label: label)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
