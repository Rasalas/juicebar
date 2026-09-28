import Foundation

/// File selection and document envelopes belong to the log format, not the importer.
extension ActivitySource {
    func acceptsLog(_ file: URL) -> Bool {
        switch self {
        case .gemini:
            return file.pathExtension == "jsonl" || (file.pathExtension == "json" && file.lastPathComponent.hasPrefix("session-"))
        case .cline: return file.lastPathComponent.hasSuffix(".messages.json")
        case .roo: return file.lastPathComponent == "ui_messages.json"
        case .opencode, .kilo: return false
        default: return file.pathExtension == "jsonl"
        }
    }

    var logMarkers: [Data] {
        let markers: [String]
        switch self {
        case .codex: markers = ["\"token_count\"", "\"token_usage_record\"", "\"turn_context\"", "\"session_meta\""]
        case .pi: markers = ["\"usage\"", "\"session\""]
        case .gemini: markers = ["\"tokens\""]
        case .qwen: markers = ["\"usageMetadata\""]
        default: markers = ["\"usage\""]
        }
        return markers.map { Data($0.utf8) }
    }

    func fileIdentity(_ file: URL) -> String {
        // Roo stores one array per task; its timestamp IDs are only unique within that task.
        stableID(self == .roo ? file.deletingLastPathComponent().lastPathComponent : file.path)
    }
}

extension UsageLogParser {
    mutating func consumeDocument(_ value: Any) throws {
        switch source {
        case .gemini:
            guard let record = value as? [String: Any], record["sessionId"] is String,
                  record["messages"] is [[String: Any]] else { throw invalidDocument }
            consume(record)
        case .cline:
            guard let record = value as? [String: Any], JSONValue.number(record["version"]) == 1,
                  let messages = record["messages"] as? [[String: Any]] else { throw invalidDocument }
            for message in messages { try Task.checkCancellation(); consume(message) }
        case .roo:
            guard let messages = value as? [[String: Any]] else { throw invalidDocument }
            for message in messages { try Task.checkCancellation(); consume(message) }
        default: throw invalidDocument
        }
    }

    private var invalidDocument: ProviderFailure {
        .invalidData(tr("Unbekanntes Log-Format: {0}", source.name))
    }
}
