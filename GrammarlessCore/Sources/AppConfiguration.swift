import Combine
import Foundation
import LocalAuthentication
import Security

public enum GrammarlessLanguageMode: String, Codable, CaseIterable, Identifiable {
    case zh
    case en

    public var id: String { rawValue }

    public var promptLanguageName: String {
        switch self {
        case .zh:
            return "Simplified Chinese"
        case .en:
            return "English"
        }
    }

    public var promptLanguageInstruction: String {
        "All user-facing responses, explanations, report fields, chat messages, and JSON string values that are not copied from the document must be written in \(promptLanguageName). Do not switch languages. Do not mix Chinese and English except for proper nouns, code, model names, acronyms, or exact document quotes."
    }
}

public struct AppConfiguration: Codable, Equatable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var debounceMilliseconds: Int
    public var reviewTimeoutSeconds: Double
    public var actionTimeoutSeconds: Double
    public var uiLanguage: GrammarlessLanguageMode
    public var isGhostTextEnabled: Bool

    public init(
        baseURL: String = "http://127.0.0.1:8317/v1",
        apiKey: String = "",
        model: String = "gpt-5.4-mini",
        debounceMilliseconds: Int = 700,
        reviewTimeoutSeconds: Double = 18,
        actionTimeoutSeconds: Double = 15,
        uiLanguage: GrammarlessLanguageMode = .zh,
        isGhostTextEnabled: Bool = true
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.debounceMilliseconds = debounceMilliseconds
        self.reviewTimeoutSeconds = reviewTimeoutSeconds
        self.actionTimeoutSeconds = actionTimeoutSeconds
        self.uiLanguage = uiLanguage
        self.isGhostTextEnabled = isGhostTextEnabled
    }

    enum CodingKeys: String, CodingKey {
        case baseURL
        case apiKey
        case model
        case debounceMilliseconds
        case reviewTimeoutSeconds
        case actionTimeoutSeconds
        case uiLanguage
        case isGhostTextEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfiguration()
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        debounceMilliseconds = try container.decodeIfPresent(Int.self, forKey: .debounceMilliseconds) ?? defaults.debounceMilliseconds
        reviewTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .reviewTimeoutSeconds) ?? defaults.reviewTimeoutSeconds
        actionTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .actionTimeoutSeconds) ?? defaults.actionTimeoutSeconds
        uiLanguage = try container.decodeIfPresent(GrammarlessLanguageMode.self, forKey: .uiLanguage) ?? defaults.uiLanguage
        isGhostTextEnabled = try container.decodeIfPresent(Bool.self, forKey: .isGhostTextEnabled) ?? defaults.isGhostTextEnabled
    }

    public func sanitized() -> AppConfiguration {
        var copy = self
        copy.baseURL = Self.sanitizedBaseURL(baseURL)
        copy.apiKey = Self.sanitizedSecret(apiKey)
        copy.model = Self.sanitizedIdentifier(model)
        return copy
    }

    public static func sanitizedBaseURL(_ value: String) -> String {
        value.removingWhitespaceAndNewlines()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func sanitizedSecret(_ value: String) -> String {
        value.removingWhitespaceAndNewlines()
    }

    public static func sanitizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func removingWhitespaceAndNewlines() -> String {
        unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
    }
}

public protocol APIKeyStoring: AnyObject {
    func readAPIKey() -> String?
    @discardableResult
    func writeAPIKey(_ apiKey: String) -> Bool
    @discardableResult
    func deleteAPIKey() -> Bool
}

public final class KeychainAPIKeyStore: APIKeyStoring {
    private let service: String
    private let account: String

    public init(
        service: String = "local.yxp.grammarless",
        account: String = "openai-compatible-api-key"
    ) {
        self.service = service
        self.account = account
    }

    public func readAPIKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        applyNonInteractiveAuthContext(to: &query)

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func writeAPIKey(_ apiKey: String) -> Bool {
        guard !apiKey.isEmpty else {
            return deleteAPIKey()
        }

        let encoded = Data(apiKey.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var updateQuery = baseQuery()
        applyNonInteractiveAuthContext(to: &updateQuery)
        let status = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        if status == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = encoded
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            applyNonInteractiveAuthContext(to: &addQuery)
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    public func deleteAPIKey() -> Bool {
        var query = baseQuery()
        applyNonInteractiveAuthContext(to: &query)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        return query
    }

    private func applyNonInteractiveAuthContext(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
    }
}

public final class DisabledAPIKeyStore: APIKeyStoring {
    private let fallbackAPIKey: String?

    public init(fallbackAPIKey: String? = nil) {
        self.fallbackAPIKey = fallbackAPIKey
    }

    public func readAPIKey() -> String? {
        fallbackAPIKey
    }

    @discardableResult
    public func writeAPIKey(_ apiKey: String) -> Bool {
        false
    }

    @discardableResult
    public func deleteAPIKey() -> Bool {
        false
    }
}

public final class ConfigurationStore: ObservableObject {
    public static let storageKey = "Grammarless.AppConfiguration"

    @Published public private(set) var configuration: AppConfiguration

    private let defaults: UserDefaults
    private let apiKeyStore: APIKeyStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        apiKeyStore: APIKeyStoring = KeychainAPIKeyStore()
    ) {
        self.defaults = defaults
        self.apiKeyStore = apiKeyStore
        let loadedFromDefaults: Bool
        if
            let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? decoder.decode(AppConfiguration.self, from: data)
        {
            configuration = decoded.sanitized()
            loadedFromDefaults = true
        } else {
            configuration = AppConfiguration().sanitized()
            loadedFromDefaults = false
        }

        if loadedFromDefaults, !configuration.apiKey.isEmpty {
            if apiKeyStore.writeAPIKey(configuration.apiKey) {
                persist()
            } else if let data = try? encoder.encode(configuration) {
                defaults.set(data, forKey: Self.storageKey)
            }
        } else if let storedKey = apiKeyStore.readAPIKey(), !AppConfiguration.sanitizedSecret(storedKey).isEmpty {
            configuration.apiKey = AppConfiguration.sanitizedSecret(storedKey)
        } else if loadedFromDefaults, let data = try? encoder.encode(configuration) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    public func update(_ mutate: (inout AppConfiguration) -> Void) {
        var next = configuration
        mutate(&next)
        configuration = next.sanitized()
        persist()
    }

    public func replace(with configuration: AppConfiguration) {
        self.configuration = configuration.sanitized()
        persist()
    }

    public func reset() {
        configuration = AppConfiguration().sanitized()
        persist()
    }

    private func persist() {
        configuration = configuration.sanitized()
        let keyStored = apiKeyStore.writeAPIKey(configuration.apiKey)
        var persistedConfiguration = configuration.sanitized()
        if keyStored {
            persistedConfiguration.apiKey = ""
        }
        guard let data = try? encoder.encode(persistedConfiguration) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
