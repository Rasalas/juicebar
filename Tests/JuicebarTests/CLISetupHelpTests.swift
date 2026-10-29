import XCTest
import JuicebarCore
@testable import Juicebar

@MainActor final class CLISetupHelpTests: XCTestCase {
    func testDefaultCommandsRemainSimple() {
        XCTAssertEqual(CLISetupHelp.loginCommand(for: AccountConfiguration(id: "fixture", provider: .codex)), "codex login")
        XCTAssertEqual(CLISetupHelp.loginCommand(for: AccountConfiguration(id: "fixture", provider: .claude)), "claude auth login")
        XCTAssertNil(CLISetupHelp.loginCommand(for: AccountConfiguration(id: "fixture", provider: .opencodeGo)))
    }
    func testShellCommandsRoundTripLiteralExecutableProfileAndArguments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-words-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // This is a fixture executable, never a provider CLI. It only prints its arguments and environment.
        let executable = directory.appendingPathComponent("cli 'quote' \"double\" $value `data`\nnext")
        try Data("#!/bin/sh\nprintf '%s\\000' \"$CODEX_HOME\" \"$CLAUDE_CONFIG_DIR\" \"$@\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for provider in [ProviderKind.codex, .claude] {
            for profile in ["/tmp/profile with 'quotes' \"and\" $variable `literal` ;*\nnext", "~/Profile 'with spaces'", "~", "/tmp/plain"] {
                var configuration = AccountConfiguration(id: "fixture", provider: provider)
                configuration.executablePath = executable.path
                configuration.profileDirectory = profile
                let command = try XCTUnwrap(CLISetupHelp.loginCommand(for: configuration))
                for shell in ["/bin/zsh", "/bin/bash"] {
                    let process = Process(), output = Pipe()
                    process.executableURL = URL(fileURLWithPath: shell)
                    process.arguments = ["-f", "-c", command]
                    process.environment = ["PATH": "/usr/bin:/bin", "CODEX_HOME": "", "CLAUDE_CONFIG_DIR": ""]
                    process.standardOutput = output
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    XCTAssertEqual(process.terminationStatus, 0, shell)
                    let fields = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                    let expanded = NSString(string: profile).expandingTildeInPath
                    XCTAssertEqual(Array(fields.prefix(2)), provider == .codex ? [expanded, ""] : ["", expanded])
                    XCTAssertEqual(Array(fields.dropFirst(2).dropLast()), provider == .codex ? ["login"] : ["auth", "login"])
                }
            }
        }
    }
    func testExecutableTildeExpandsBeforeQuoting() throws {
        var configuration = AccountConfiguration(id: "fixture", provider: .codex)
        configuration.executablePath = "~/My Tools/codex"
        let command = try XCTUnwrap(CLISetupHelp.loginCommand(for: configuration))
        XCTAssertEqual(command, "'" + NSString(string: configuration.executablePath).expandingTildeInPath + "' login")
        configuration.executablePath = "/tmp/codex"
        configuration.profileDirectory = "/tmp/profile"
        XCTAssertEqual(CLISetupHelp.loginCommand(for: configuration), "CODEX_HOME=/tmp/profile /tmp/codex login")
    }
}
