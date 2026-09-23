import Foundation
import Security

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, anthropic, openai, claudeAccount
    var id: String { rawValue }
    var title: String {
        switch self { case .local: "Local (on this Mac)"; case .anthropic: "Claude API"; case .claudeAccount: "Claude account"; case .openai: "OpenAI" }
    }
    var models: [String] {
        switch self {
        case .local: []
        case .claudeAccount: ["haiku", "sonnet"]
        case .anthropic: ["claude-haiku-4-5-20251001", "claude-sonnet-5"]
        case .openai: ["gpt-4.1-mini", "gpt-4.1"]
        }
    }
    static func modelTitle(_ model: String) -> String {
        switch model {
        case "haiku": "Claude Haiku (fast)"
        case "sonnet": "Claude Sonnet"
        case "claude-haiku-4-5-20251001": "Claude Haiku 4.5 (fast)"
        case "claude-sonnet-5": "Claude Sonnet 5"
        case "gpt-4.1-mini": "GPT-4.1 mini (fast)"
        case "gpt-4.1": "GPT-4.1"
        default: model
        }
    }
    var requiresAPIKey: Bool { self == .anthropic || self == .openai }
    var keyURL: URL {
        URL(string: self == .anthropic ? "https://platform.claude.com/settings/keys" : "https://platform.openai.com/api-keys")!
    }
}

/// Only the explicit Save and enable action writes this preference. No secrets.
struct AIConfiguration: Codable, Equatable, Sendable {
    var provider: AIProvider = .local
    var model: String = ""
    static let defaultsKey = "aiProviderConfiguration"
    static var current: AIConfiguration { read(from: .standard) }
    static func read(from defaults: UserDefaults) -> AIConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.provider == .local || value.provider.models.contains(value.model) else { return .init() }
        return value
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
    // The existing session lifecycle pins a string model identifier. Namespace
    // cloud IDs so that a local session can never turn into a cloud session
    // when settings change, and a cloud ID can never reach Ollama.
    var modelReference: String { "cloud:\(provider.rawValue):\(model)" }
    static func cloud(from reference: String) -> AIConfiguration? {
        let parts = reference.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "cloud",
              let provider = AIProvider(rawValue: parts[1]), provider != .local,
              !parts[2].isEmpty else { return nil }
        return .init(provider: provider, model: parts[2])
    }
}

enum AIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Device-only generic passwords; never UserDefaults, files, logs or iCloud.
enum AIKeychain {
    private static let service = "com.coach.MeetingCoach.ai-api-keys"
    private static func query(_ provider: AIProvider, serviceName: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: serviceName, kSecAttrAccount as String: provider.rawValue,
         kSecAttrSynchronizable as String: false]
    }
    static func read(_ provider: AIProvider, serviceName: String = service) throws -> String? {
        var q = query(provider, serviceName: serviceName)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw AIError.message("Could not read the API key from Keychain (\(status)).")
        }
        return key
    }
    static func save(_ key: String, for provider: AIProvider, serviceName: String = service) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.requiresAPIKey, !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else {
            throw AIError.message("Enter a valid API key without spaces.")
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(provider, serviceName: serviceName) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query(provider, serviceName: serviceName).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw AIError.message("Could not save the API key in Keychain (\(added)).") }
        } else if status != errSecSuccess {
            throw AIError.message("Could not update the API key in Keychain (\(status)).")
        }
    }
    static func delete(_ provider: AIProvider, serviceName: String = service) throws {
        let status = SecItemDelete(query(provider, serviceName: serviceName) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIError.message("Could not remove the API key from Keychain (\(status)).")
        }
    }
}
