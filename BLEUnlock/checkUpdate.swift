import Cocoa

private let KEY = "lastUpdateCheck"
private let INTERVAL = 24.0 * 60 * 60
// This fork has its own release channel; checking upstream would always report a version
// mismatch, because upstream stays at 1.12.2 while this build is ahead of it.
private let LATEST_RELEASE_API = "https://api.github.com/repos/shui462115/BLEUnlock/releases/latest"
private var notified = false
private var lastCheckAt = UserDefaults.standard.double(forKey: KEY)

func checkUpdate() {
    guard !notified else { return }
    // The whole check can be switched off with:
    //   defaults write jp.sone.BLEUnlock checkForUpdates -bool false
    if let enabled = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool, !enabled {
        DiagnosticsLogger.shared.log("update_check_skipped", fields: ["reason": "disabled"])
        return
    }
    let now = NSDate().timeIntervalSince1970
    guard now - lastCheckAt >= INTERVAL else {
        DiagnosticsLogger.shared.log("update_check_skipped", fields: ["reason": "checked_recently"])
        return
    }
    doCheckUpdate()
}

private func doCheckUpdate() {
    var request = URLRequest(url: URL(string: LATEST_RELEASE_API)!)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let task = URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
        guard let jsondata = data,
              let json = try? JSONSerialization.jsonObject(with: jsondata),
              let dict = json as? [String: Any],
              let version = dict["tag_name"] as? String else {
            DiagnosticsLogger.shared.log("update_check_failed",
                                         fields: ["error": error?.localizedDescription ?? "unexpected response"])
            return
        }
        lastCheckAt = NSDate().timeIntervalSince1970
        UserDefaults.standard.set(lastCheckAt, forKey: KEY)
        compareVersionsAndNotify(version)
    })
    task.resume()
}

/// Only a genuinely newer release deserves a notification. Notifying on "different" made
/// every launch pop up "update available" as soon as the installed build was ahead of the
/// published tag.
private func isNewer(_ candidate: String, than current: String) -> Bool {
    func components(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text.split(separator: ".").map { part in
            Int(part.prefix(while: { $0.isNumber })) ?? 0
        }
    }
    let candidateParts = components(candidate)
    let currentParts = components(current)
    for index in 0..<max(candidateParts.count, currentParts.count) {
        let left = index < candidateParts.count ? candidateParts[index] : 0
        let right = index < currentParts.count ? currentParts[index] : 0
        if left != right { return left > right }
    }
    return false
}

private func compareVersionsAndNotify(_ latestVersion: String) {
    guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
    let newer = isNewer(latestVersion, than: version)
    DiagnosticsLogger.shared.log("update_check", fields: [
        "current": version,
        "latest": latestVersion,
        "newer": String(newer),
    ])
    guard newer else { return }
    notify()
    notified = true
}

private func notify() {
    let un = NSUserNotification()
    un.title = "BLEUnlock"
    un.subtitle = t("notification_update_available")
    NSUserNotificationCenter.default.deliver(un)
}
