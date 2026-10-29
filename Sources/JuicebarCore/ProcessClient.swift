import Foundation
import Darwin

/// A single, bounded control connection. No prompts are ever sent.
/// Use from one caller off the main thread. Both directions share a deadline and response cap.
public final class ProcessClient {
    private let input = Pipe()
    private let output = Pipe()
    private var pid: pid_t = 0
    private var inputClosed = false
    private var outputClosed = false
    private var buffer = Data()
    private var bytesRead = 0
    private let maximumResponseBytes: Int
    private let deadline: ContinuousClock.Instant

    public init(executable: URL, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 15, maximumResponseBytes: Int = 2_000_000, diagnosticOutput: FileHandle = .nullDevice, workingDirectory: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)) throws {
        self.maximumResponseBytes = max(0, maximumResponseBytes)
        deadline = .now.advanced(by: .seconds(timeout))
        var env = ProcessInfo.processInfo.environment
        // A custom install such as nvm's `#!/usr/bin/env node` needs its own bin directory.
        env["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        environment.forEach { env[$0] = $1 }
        env["PWD"] = workingDirectory.path
        env.removeValue(forKey: "OLDPWD")

        // Own the child and its group until close(). Unlike Foundation Process, we do not reap
        // the leader early: its reserved pid keeps group cleanup safe even after the leader exits.
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        // Runtime worker threads can block signals. Children must still respond to termination.
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigfillset(&defaults)
        try Self.check(posix_spawnattr_setsigmask(&attributes, &mask))
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        try Self.check(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        if diagnosticOutput === FileHandle.nullDevice {
            try Self.check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        } else {
            try Self.check(posix_spawn_file_actions_adddup2(&actions, diagnosticOutput.fileDescriptor, STDERR_FILENO))
        }
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Self.ended }
        }
        // Suppress SIGPIPE on this pipe only, without changing the app's signal disposition.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Self.ended }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        try Task.checkCancellation()
        try Self.check(posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp))
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }
    deinit { close() }

    public func close() {
        guard pid > 0 else { return }
        closeInput()
        // The leader is still ours, including when it is a zombie. Kill helpers before reaping it.
        killpg(pid, SIGTERM)
        let end = ContinuousClock.now.advanced(by: .milliseconds(400))
        var info = siginfo_t()
        while ContinuousClock.now < end {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        killpg(pid, SIGKILL)
        while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
        pid = 0
        try? output.fileHandleForReading.close()
    }

    public func sendInput(_ data: Data, finish: Bool = false) throws {
        do {
            try checkActive()
            guard !inputClosed else { throw Self.ended }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try checkActive()
                    var items = [pollfd(fd: input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), revents: 0),
                                 pollfd(fd: outputClosed ? -1 : output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
                    try wait(&items)
                    // A child may fill stdout before it reads stdin. Drain without discarding replies.
                    if items[1].revents != 0 { try readOutput() }
                    if items[0].revents != 0 {
                        let count = Darwin.write(items[0].fd, bytes.baseAddress!.advanced(by: offset), min(8192, bytes.count - offset))
                        if count > 0 { offset += count }
                        else if count == 0 || !Self.retryable { throw Self.ended }
                    }
                }
            }
            try checkActive()
            if finish { closeInput() }
        } catch { close(); throw error }
    }

    public func send(_ object: [String: Any]) throws {
        do {
            try checkActive()
            try sendInput(JSONSerialization.data(withJSONObject: object) + Data([10]))
        } catch { close(); throw error }
    }

    public func receive(where matches: ([String: Any]) -> Bool) throws -> [String: Any] {
        do {
            while true {
                try checkActive()
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], matches(object) { return object }
                    continue
                }
                guard !outputClosed else { throw Self.ended }
                var items = [pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
                try wait(&items)
                if items[0].revents != 0 { try readOutput() }
            }
        } catch { close(); throw error }
    }

    private static var ended: ProviderFailure {
        .unavailable(tr("Der Anbieterprozess wurde beendet. Anmeldung und CLI-Version prüfen."))
    }
    private static var retryable: Bool { errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK }
    private static func check(_ result: Int32) throws {
        guard result == 0 else { throw ended }
    }
    private func checkActive() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ProviderFailure.timedOut }
        guard pid > 0 else { throw Self.ended }
    }
    private func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        try? input.fileHandleForWriting.close()
    }
    private func wait(_ items: inout [pollfd]) throws {
        // Short bounded polls let synchronous callers observe task cancellation without helper threads.
        let result = poll(&items, nfds_t(items.count), 20)
        if result < 0 && errno != EINTR { throw Self.ended }
        try checkActive()
    }
    private func readOutput() throws {
        var bytes = [UInt8](repeating: 0, count: min(8191, maximumResponseBytes - bytesRead) + 1)
        let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        if count == 0 { outputClosed = true; return }
        if count < 0 {
            if Self.retryable { return }
            throw Self.ended
        }
        guard count <= maximumResponseBytes - bytesRead else { throw ProviderFailure.invalidData(tr("Die Anbieterantwort ist zu groß.")) }
        bytesRead += count
        buffer.append(contentsOf: bytes.prefix(count))
    }
    public static func executable(_ name: String, custom: String = "") throws -> URL {
        let fm = FileManager.default
        return try resolveExecutable(name, custom: custom, homeDirectory: fm.homeDirectoryForCurrentUser,
                                     isExecutableFile: fm.isExecutableFile(atPath:))
    }
    static func resolveExecutable(_ name: String, custom: String = "", homeDirectory: URL,
                                  isExecutableFile: (String) -> Bool) throws -> URL {
        let native = "\(homeDirectory.path)/.local/bin/\(name)"
        let system = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        // Claude's native installer updates this copy. An older npm installation
        // can remain in Homebrew's bin directory and return cached quota data.
        let defaults = name == "claude" ? [native] + system : system + [native]
        let paths = custom.isEmpty ? defaults : [NSString(string: custom).expandingTildeInPath]
        guard let path = paths.first(where: isExecutableFile) else { throw ProviderFailure.missingExecutable(name) }
        return URL(fileURLWithPath: path)
    }
}
