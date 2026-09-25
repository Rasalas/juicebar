import Foundation
import Darwin

/// A single, bounded control connection. No prompts are ever sent.
/// Must be used off the main thread; stdout is drained with a deadline and a size cap.
public final class ProcessClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var bytesRead = 0
    private let maximumResponseBytes: Int
    private let deadline: Date
    public init(executable: URL, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 15, maximumResponseBytes: Int = 2_000_000) throws {
        self.maximumResponseBytes = maximumResponseBytes
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = executable; process.arguments = arguments
        // The working directory and its environment representation must agree.
        // Otherwise a CLI may inspect the app launcher's unrelated project.
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        environment.forEach { env[$0] = $1 }
        env["PWD"] = process.currentDirectoryURL!.path
        env.removeValue(forKey: "OLDPWD")
        process.environment = env
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    deinit { close() }
    public func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let end = Date().addingTimeInterval(0.4)
            while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
    }
    public func sendInput(_ data: Data, finish: Bool = false) throws {
        try input.fileHandleForWriting.write(contentsOf: data)
        if finish { try input.fileHandleForWriting.close() }
    }
    public func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object) + Data([10])
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    public func receive(where matches: ([String: Any]) -> Bool) throws -> [String: Any] {
        while Date() < deadline {
            try Task.checkCancellation()
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], matches(object) { return object }
                continue
            }
            var item = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(item.fd, &bytes, bytes.count)
                guard count > 0 else { throw ProviderFailure.unavailable(tr("Der Anbieterprozess wurde beendet. Anmeldung und CLI-Version prüfen.")) }
                bytesRead += count
                guard bytesRead <= maximumResponseBytes else { throw ProviderFailure.invalidData(tr("Die Anbieterantwort ist zu groß.")) }
                buffer.append(contentsOf: bytes.prefix(count))
            } else if !process.isRunning {
                throw ProviderFailure.unavailable(tr("Der Anbieterprozess wurde beendet. Anmeldung und CLI-Version prüfen."))
            }
        }
        throw ProviderFailure.timedOut
    }
    public static func executable(_ name: String, custom: String = "") throws -> URL {
        let fm = FileManager.default
        let paths = custom.isEmpty ? ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(fm.homeDirectoryForCurrentUser.path)/.local/bin/\(name)"] : [NSString(string: custom).expandingTildeInPath]
        guard let path = paths.first(where: { fm.isExecutableFile(atPath: $0) }) else { throw ProviderFailure.missingExecutable(name) }
        return URL(fileURLWithPath: path)
    }
}
