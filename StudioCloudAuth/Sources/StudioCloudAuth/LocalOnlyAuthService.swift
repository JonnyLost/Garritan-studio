import Foundation
import Combine

/// Local-only implementation of the existing optional authentication interface.
/// Standard Studio builds do not download, link, initialize, or contact Supabase.
/// This intentionally preserves the public UI-facing API of StudioCloudAuth.
public struct AuthUser: Codable, Sendable {
    public let id: String
    public let email: String?
    public let fullName: String?
    public let avatarURL: String?
    public let provider: AuthProvider
    public let createdAt: Date

    public init(id: String, email: String?, fullName: String?, avatarURL: String?, provider: AuthProvider, createdAt: Date) {
        self.id = id
        self.email = email
        self.fullName = fullName
        self.avatarURL = avatarURL
        self.provider = provider
        self.createdAt = createdAt
    }
}

public enum AuthProvider: String, Codable, Sendable {
    case email
    case apple
    case google
}

public enum AuthError: LocalizedError {
    case notConfigured
    case invalidCredentials
    case emailNotVerified
    case networkError(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Cloud authentication is disabled in this local Studio build."
        case .invalidCredentials:
            return "Invalid email or password."
        case .emailNotVerified:
            return "Please verify your email address."
        case .networkError(let message):
            return "Network error: \(message)"
        case .unknown(let message):
            return message
        }
    }
}

@MainActor
public final class SupabaseAuthService: ObservableObject {
    public static let shared = SupabaseAuthService()
    @Published public private(set) var currentUser: AuthUser?
    @Published public private(set) var isAuthenticated = false
    @Published public private(set) var isLoading = false

    private init() {}
    public var isConfigured: Bool { false }

    /// A local build must not store a credential it cannot use.
    public func configure(url: String, anonKey: String) {}

    public func signUp(email: String, password: String, fullName: String?) async throws {
        throw AuthError.notConfigured
    }
    public func signIn(email: String, password: String) async throws {
        throw AuthError.notConfigured
    }
    public func resetPassword(email: String) async throws {
        throw AuthError.notConfigured
    }
    public func signInWithApple(idToken: String, nonce: String) async throws {
        throw AuthError.notConfigured
    }
    public func signInWithGoogle(idToken: String, accessToken: String) async throws {
        throw AuthError.notConfigured
    }
    public func signOut() async throws {
        throw AuthError.notConfigured
    }
    public func deleteAccount() async throws {
        throw AuthError.notConfigured
    }
}

/// Preserve the helper's source API for clients that import StudioCloudAuth.
@MainActor
public final class AppleSignInHelper {
    public init() {}
    public func signIn() async throws -> (idToken: String, nonce: String) {
        throw AuthError.notConfigured
    }
}
