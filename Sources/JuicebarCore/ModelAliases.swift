import Foundation

/// Confirmed identities, scoped to providers. Original log names remain unchanged.
public enum ModelAliases {
    public struct Alias: Codable, Sendable {
        public let names: [String]
        public let providers: [String]
        public let canonicalModel: String
        public let displayName: String
        public let source: URL
        public let verifiedOn: String
    }
    public static var entries: [Alias] { ModelCatalog.shared.snapshot.aliases }
    public static func resolve(model: String, provider: String) -> Alias? {
        ModelCatalog.shared.snapshot.resolve(model: model, provider: provider)
    }
}
