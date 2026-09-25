import Foundation

/// Confirmed identities, scoped to the providers that used the preview name.
/// Original event IDs and model names are never rewritten by this catalog.
public enum ModelAliases {
    public struct Alias: Decodable, Sendable {
        public let names: [String]
        public let providers: [String]
        public let canonicalModel: String
        public let displayName: String
        public let source: URL
        public let verifiedOn: String
    }
    private struct Catalog: Decodable { let version: Int; let aliases: [Alias] }
    public static let entries: [Alias] = {
        guard let url = Bundle.module.url(forResource: "model-aliases", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data), catalog.version == 1 else { return [] }
        return catalog.aliases
    }()
    private static let index: [String: Alias] = {
        var result: [String: Alias] = [:]
        for entry in entries {
            for provider in entry.providers {
                for name in entry.names { result["\(provider)|\(name)"] = entry }
            }
        }
        return result
    }()
    public static func resolve(model: String, provider: String) -> Alias? {
        index["\(provider.lowercased())|\(model.lowercased())"]
    }
}
