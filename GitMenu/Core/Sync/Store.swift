import Foundation

struct StoreState: Codable {
    var threads: [String: NotificationThread] = [:]
    var details: [String: ThreadDetails] = [:]
    var lastModified: String? = nil
    var lastSync: Date? = nil
    var fullSyncDone = false
}

/// JSON-on-disk persistence. The inbox is at most a few thousand threads; a file read at launch is fine.
final class Store {
    private let url: URL
    private(set) var state: StoreState

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitMenu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("state-v4.json")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(StoreState.self, from: data) {
            state = s
        } else {
            state = StoreState()
        }
    }

    func update(_ f: (inout StoreState) -> Void) {
        f(&state)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
    }

    func wipe() {
        state = StoreState()
        try? FileManager.default.removeItem(at: url)
    }
}
