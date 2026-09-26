import Foundation
import JuicebarCore

// Invoked by Claude Code, never by the sandboxed app. No network or credentials.
// Explicit destination; no global Claude settings are changed by this executable.
guard CommandLine.arguments.count == 2 else { exit(2) }
do {
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
        input.append(chunk)
        guard input.count <= 262_144 else { exit(2) }
    }
    guard let observation = try ClaudeStatuslineObservation.capture(input) else { exit(0) }
    let destination = URL(fileURLWithPath: CommandLine.arguments[1])
    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".statusline-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard FileManager.default.createFile(atPath: temporary.path, contents: try observation.encoded(), attributes: [.posixPermissions: 0o600]) else { exit(2) }
    guard rename(temporary.path, destination.path) == 0 else { exit(2) }
} catch {
    // Do not echo input or errors into the CLI status line.
    exit(2)
}
