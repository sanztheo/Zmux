import Foundation

public struct ZMUXAuthAutoLoginCredentials: Equatable, Sendable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public enum ZMUXAuthLaunchConfig {
    public static func autoLoginCredentials(
        from environment: [String: String],
        clearAuth: Bool,
        mockDataEnabled: Bool
    ) -> ZMUXAuthAutoLoginCredentials? {
        if clearAuth || mockDataEnabled {
            return nil
        }
        guard let email = environment["ZMUX_UITEST_STACK_EMAIL"], !email.isEmpty else {
            return nil
        }
        guard let password = environment["ZMUX_UITEST_STACK_PASSWORD"], !password.isEmpty else {
            return nil
        }
        return ZMUXAuthAutoLoginCredentials(email: email, password: password)
    }

    public static func fixtureUser(
        from environment: [String: String],
        clearAuth: Bool,
        mockDataEnabled: Bool
    ) -> ZMUXAuthUser? {
        if clearAuth || mockDataEnabled {
            return nil
        }
        guard environment["ZMUX_UITEST_AUTH_FIXTURE"] == "1" else {
            return nil
        }
        return ZMUXAuthUser(
            id: environment["ZMUX_UITEST_AUTH_USER_ID"] ?? "uitest_user",
            primaryEmail: environment["ZMUX_UITEST_AUTH_EMAIL"] ?? "uitest@zmux.local",
            displayName: environment["ZMUX_UITEST_AUTH_NAME"] ?? "UI Test"
        )
    }
}

public enum ZMUXAuthMagicLinkCode {
    public static func compose(code: String, nonce: String) -> String {
        code + nonce
    }
}

public struct ZMUXAuthState: Equatable, Sendable {
    public let isAuthenticated: Bool
    public let currentUser: ZMUXAuthUser?
    public let isRestoringSession: Bool

    public init(isAuthenticated: Bool, currentUser: ZMUXAuthUser?, isRestoringSession: Bool) {
        self.isAuthenticated = isAuthenticated
        self.currentUser = currentUser
        self.isRestoringSession = isRestoringSession
    }

    public static func primed(
        clearAuthRequested: Bool,
        mockDataEnabled: Bool,
        fixtureUser: ZMUXAuthUser?,
        autoLoginCredentials: ZMUXAuthAutoLoginCredentials?,
        cachedUser: ZMUXAuthUser?,
        hasTokens: Bool,
        mockUser: ZMUXAuthUser
    ) -> Self {
        if clearAuthRequested {
            return .cleared()
        }

        if mockDataEnabled {
            return Self(isAuthenticated: true, currentUser: mockUser, isRestoringSession: false)
        }

        if let fixtureUser {
            return Self(isAuthenticated: true, currentUser: fixtureUser, isRestoringSession: false)
        }

        if autoLoginCredentials != nil {
            return Self(isAuthenticated: true, currentUser: cachedUser, isRestoringSession: false)
        }

        return Self(
            isAuthenticated: hasTokens,
            currentUser: cachedUser,
            isRestoringSession: false
        )
    }

    public static func cleared() -> Self {
        Self(isAuthenticated: false, currentUser: nil, isRestoringSession: false)
    }
}
