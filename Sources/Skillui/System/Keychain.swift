import Foundation
import LocalAuthentication
import Security

/// Minimal Keychain wrapper for the GitHub PAT (a credential shouldn't sit in UserDefaults).
enum Keychain {
    private static let service = "com.maximedesogus.skillui"
    private static let account = "github-pat"

    enum ReadResult: Equatable {
        case success(String)
        case notFound
        case interactionRequired
        case failed(OSStatus)
    }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func authenticationContext(allowInteraction: Bool) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        return context
    }

    static func setToken(_ token: String?) {
        var delete = base
        delete[kSecUseAuthenticationContext as String] = authenticationContext(allowInteraction: false)
        SecItemDelete(delete as CFDictionary)
        guard let token, !token.isEmpty, let data = token.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func readToken(allowInteraction: Bool = false) -> ReadResult {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authenticationContext(allowInteraction: allowInteraction)
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data,
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty else { return .notFound }
            return .success(token)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .interactionRequired
        default:
            return .failed(status)
        }
    }

    static func token(allowInteraction: Bool = false) -> String? {
        if case .success(let token) = readToken(allowInteraction: allowInteraction) { return token }
        return nil
    }
}
