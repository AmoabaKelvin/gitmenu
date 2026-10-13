import AppKit
import Security

/// Updates the app in place from GitHub releases. A download is only installed when it carries the same
/// signature as the running app, so a tampered or foreign build is refused.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(String)
        case installing(String)
        case failed(String)
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @Published private(set) var state: State = .idle

    static let repo = "AmoabaKelvin/gitmenu"
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private var asset: URL?
    private var timer: Timer?

    var availableVersion: String? {
        if case .available(let v) = state { return v }
        return nil
    }

    /// Checks now and then every six hours while `enabled`.
    func schedule(enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in Task { @MainActor in await self?.check() } }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await check() }
    }

    func check() async {
        switch state {
        case .checking, .installing: return
        default: break
        }
        state = .checking
        do {
            // Public endpoint, deliberately without the user's token.
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { throw UpdateError("GitHub did not return a release.") }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let zip = (json["assets"] as? [[String: Any]] ?? [])
                .compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".zip") }
            if Self.isNewer(version, than: current), let zip, let url = URL(string: zip) {
                asset = url
                state = .available(version)
                logger.info("update available: \(version)")
            } else {
                state = .upToDate
            }
        } catch {
            logger.error("update check failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    func install() async {
        guard case .available(let version) = state, let asset else { return }
        state = .installing(version)
        do {
            let target = Bundle.main.bundleURL
            if target.path.contains("/AppTranslocation/") {
                throw UpdateError("Move GitMenu to the Applications folder, open it from there, then update.")
            }
            let fm = FileManager.default
            // Same volume as the app, so the swap is a rename.
            let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            defer { try? fm.removeItem(at: work) }
            let (downloaded, resp) = try await URLSession.shared.download(from: asset)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
            let zip = work.appendingPathComponent("update.zip")
            try fm.moveItem(at: downloaded, to: zip)
            let unpacked = work.appendingPathComponent("unpacked")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            guard let name = try fm.contentsOfDirectory(atPath: unpacked.path).first(where: { $0.hasSuffix(".app") }) else {
                throw UpdateError("The download does not contain an app.")
            }
            let fresh = unpacked.appendingPathComponent(name)
            try Self.verify(fresh)
            let found = Bundle(url: fresh)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            guard Self.isNewer(found, than: current) else { throw UpdateError("The download is not newer than this version.") }
            _ = try fm.replaceItemAt(target, withItemAt: fresh)
            logger.info("updated \(self.current) -> \(found), relaunching")
            relaunch(target)
        } catch {
            logger.error("update failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// The new bundle must satisfy the running app's designated requirement: same identifier, same signing certificate.
    private static func verify(_ app: URL) throws {
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var theirs: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs else {
            throw UpdateError("Could not read the app's signature.")
        }
        // An ad-hoc build is only identified by its own hash, so nothing else can ever match it.
        var info: CFDictionary?
        SecCodeCopySigningInformation(mine, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any], !certs.isEmpty else {
            throw UpdateError("This build is signed ad hoc and cannot update itself.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(theirs, flags, requirement) == errSecSuccess else {
            throw UpdateError("The download is not signed like this copy of GitMenu, so it was not installed.")
        }
    }

    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit, then open the replaced bundle.
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh",
                       String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { p in
                if p.terminationStatus == 0 { c.resume() } else { c.resume(throwing: UpdateError("Could not unpack the download.")) }
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}
