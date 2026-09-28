import Foundation

/// Current Kilo uses the OpenCode message schema in its own SQLite database.
enum KiloHistory {
    private static func databases(root: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        var files = [root]
        if isDirectory.boolValue {
            files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
                .filter { $0.pathExtension == "db" }
        }
        return try files.filter { try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true }.sorted { $0.path < $1.path }
    }

    static func fingerprint(root: URL) throws -> String {
        let fm = FileManager.default
        var stamps: [String] = []
        for file in try databases(root: root) {
            for suffix in ["", "-wal", "-journal"] {
                let path = file.path + suffix
                guard fm.fileExists(atPath: path) else { stamps.append("\(path)|missing"); continue }
                let values = try fm.attributesOfItem(atPath: path)
                guard let size = values[.size] as? NSNumber, let date = values[.modificationDate] as? Date,
                      let inode = values[.systemFileNumber] as? NSNumber else {
                    throw ProviderFailure.unavailable(tr("Kilo-Dateistand konnte nicht gelesen werden."))
                }
                stamps.append("\(path)|\(inode)|\(size)|\(date.timeIntervalSince1970)")
            }
        }
        return stableID(stamps.joined(separator: "\n"))
    }

    static func read(root: URL, now: Date) throws -> (events: [ActivityEvent], notices: [String]) {
        var notices: [String] = [], events: [ActivityEvent] = []
        for file in try databases(root: root) {
            try Task.checkCancellation()
            let result = try OpenCodeHistory.read(path: file.path, now: now, lookbackDays: 90, source: .kilo)
            events += result.events
            notices += result.importWarnings ?? []
        }
        return (events, notices)
    }
}
