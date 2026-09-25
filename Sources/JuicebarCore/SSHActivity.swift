import Foundation

public enum SSHActivity {
    public static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 200 && !host.hasPrefix("-") &&
        host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@").contains($0) }
    }
    public static func read(host: String, now: Date = Date()) throws -> (events: [ActivityEvent], notices: [String]) {
        guard isValidHost(host) else { throw ProviderFailure.invalidData("Ein SSH-Alias darf nur Buchstaben, Zahlen, Punkt, Bindestrich, Unterstrich und @ enthalten.") }
        guard let scriptURL = Bundle.module.url(forResource: "ssh-usage", withExtension: "py") else { throw ProviderFailure.unavailable("SSH-Collector fehlt im App-Bundle.") }
        let process = try ProcessClient(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: ["-T", "-a", "-x", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "--", host, "python3", "-"], timeout: 180, maximumResponseBytes: 128 * 1024 * 1024)
        defer { process.close() }
        try process.sendInput(Data(contentsOf: scriptURL), finish: true)
        var parser: UsageLogParser?, events: [ActivityEvent] = [], notices: [String] = []
        let since = now.addingTimeInterval(-90 * 86400)
        do {
            while true {
                let row = try process.receive { _ in true }
                if row["done"] as? Bool == true { break }
                if let file = row["file"] as? String, let name = row["source"] as? String, let source = ActivitySource(rawValue: name) {
                    parser = UsageLogParser(source: source, fileID: file)
                } else if let record = row["record"] as? [String: Any] { parser?.consume(record) }
                else if row["endFile"] as? Bool == true {
                    events += parser?.events.filter { $0.date >= since && $0.date <= now } ?? []; parser = nil
                } else if let event = row["event"] as? [String: Any], let id = event["id"] as? String,
                          let date = JSONValue.date(event["date"]), let tokens = JSONValue.number(event["tokens"]), date >= since, date <= now, tokens > 0 {
                    events.append(ActivityEvent(id: id, source: .opencode, date: date, model: event["model"] as? String ?? "Unbekannt", provider: event["provider"] as? String ?? "", tokens: tokens, usage: (event["tokenBreakdown"] as? [String: Any]).flatMap(TokenBreakdown.opencode)))
                } else if let notice = row["notice"] as? String { notices.append("\(host): \(notice)") }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw ProviderFailure.unavailable("\(host): SSH-Import nicht abgeschlossen. Verbindung, bekannten Host-Schlüssel, Schlüsselanmeldung und Python 3 prüfen. Der Import ist auf 3 Minuten begrenzt.") }
        return (events, notices)
    }
}
