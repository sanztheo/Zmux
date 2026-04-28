import ZMUXAuthCore
import Foundation
import Testing

@Suite("ZMUXAuthCore")
struct ZMUXAuthStateTests {
    @Test("Config resolves development defaults and overrides")
    func configResolvesDevelopmentDefaultsAndOverrides() {
        let defaults = ZMUXAuthConfig.resolve(
            environment: .development,
            developmentProjectId: "dev-project",
            productionProjectId: "prod-project",
            developmentPublishableClientKey: "dev-key",
            productionPublishableClientKey: "prod-key"
        )
        #expect(defaults == ZMUXAuthConfig(projectId: "dev-project", publishableClientKey: "dev-key"))

        let overrides = ZMUXAuthConfig.resolve(
            environment: .development,
            overrides: [
                "STACK_PROJECT_ID_DEV": "override-project",
                "STACK_PUBLISHABLE_CLIENT_KEY_DEV": "override-key",
            ],
            developmentProjectId: "dev-project",
            productionProjectId: "prod-project",
            developmentPublishableClientKey: "dev-key",
            productionPublishableClientKey: "prod-key"
        )
        #expect(overrides == ZMUXAuthConfig(projectId: "override-project", publishableClientKey: "override-key"))
    }

    @Test("Config resolves production defaults and overrides")
    func configResolvesProductionDefaultsAndOverrides() {
        let defaults = ZMUXAuthConfig.resolve(
            environment: .production,
            developmentProjectId: "dev-project",
            productionProjectId: "prod-project",
            developmentPublishableClientKey: "dev-key",
            productionPublishableClientKey: "prod-key"
        )
        #expect(defaults == ZMUXAuthConfig(projectId: "prod-project", publishableClientKey: "prod-key"))

        let overrides = ZMUXAuthConfig.resolve(
            environment: .production,
            overrides: [
                "STACK_PROJECT_ID_PROD": "override-project",
                "STACK_PUBLISHABLE_CLIENT_KEY_PROD": "override-key",
            ],
            developmentProjectId: "dev-project",
            productionProjectId: "prod-project",
            developmentPublishableClientKey: "dev-key",
            productionPublishableClientKey: "prod-key"
        )
        #expect(overrides == ZMUXAuthConfig(projectId: "override-project", publishableClientKey: "override-key"))
    }

    @Test("Launch config returns credentials only when enabled")
    func launchConfigReturnsCredentialsOnlyWhenEnabled() {
        let environment = [
            "ZMUX_UITEST_STACK_EMAIL": "test@example.com",
            "ZMUX_UITEST_STACK_PASSWORD": "pass123",
        ]

        #expect(
            ZMUXAuthLaunchConfig.autoLoginCredentials(
                from: environment,
                clearAuth: false,
                mockDataEnabled: false
            ) == ZMUXAuthAutoLoginCredentials(email: "test@example.com", password: "pass123")
        )
        #expect(
            ZMUXAuthLaunchConfig.autoLoginCredentials(
                from: environment,
                clearAuth: true,
                mockDataEnabled: false
            ) == nil
        )
        #expect(
            ZMUXAuthLaunchConfig.autoLoginCredentials(
                from: environment,
                clearAuth: false,
                mockDataEnabled: true
            ) == nil
        )
    }

    @Test("Launch config returns fixture user only when enabled")
    func launchConfigReturnsFixtureUserOnlyWhenEnabled() {
        let environment = [
            "ZMUX_UITEST_AUTH_FIXTURE": "1",
            "ZMUX_UITEST_AUTH_USER_ID": "fixture-user",
            "ZMUX_UITEST_AUTH_EMAIL": "fixture@example.com",
            "ZMUX_UITEST_AUTH_NAME": "Fixture User",
        ]

        #expect(
            ZMUXAuthLaunchConfig.fixtureUser(
                from: environment,
                clearAuth: false,
                mockDataEnabled: false
            ) == ZMUXAuthUser(
                id: "fixture-user",
                primaryEmail: "fixture@example.com",
                displayName: "Fixture User"
            )
        )
        #expect(
            ZMUXAuthLaunchConfig.fixtureUser(
                from: environment,
                clearAuth: true,
                mockDataEnabled: false
            ) == nil
        )
        #expect(
            ZMUXAuthLaunchConfig.fixtureUser(
                from: environment,
                clearAuth: false,
                mockDataEnabled: true
            ) == nil
        )
    }

    @Test("Primed state restores cached user and token state")
    func primedStateRestoresCachedUserAndTokenState() {
        let user = ZMUXAuthUser(id: "user_123", primaryEmail: "user@example.com", displayName: "Test User")
        let state = ZMUXAuthState.primed(
            clearAuthRequested: false,
            mockDataEnabled: false,
            fixtureUser: nil,
            autoLoginCredentials: nil,
            cachedUser: user,
            hasTokens: true,
            mockUser: ZMUXAuthUser(id: "mock", primaryEmail: "mock@example.com", displayName: "Mock")
        )

        #expect(state.isAuthenticated)
        #expect(state.currentUser == user)
        #expect(!state.isRestoringSession)
    }

    @Test("Primed state does not authenticate from cached user alone")
    func primedStateDoesNotAuthenticateFromCachedUserAlone() {
        let user = ZMUXAuthUser(id: "user_123", primaryEmail: "user@example.com", displayName: "Test User")
        let state = ZMUXAuthState.primed(
            clearAuthRequested: false,
            mockDataEnabled: false,
            fixtureUser: nil,
            autoLoginCredentials: nil,
            cachedUser: user,
            hasTokens: false,
            mockUser: ZMUXAuthUser(id: "mock", primaryEmail: "mock@example.com", displayName: "Mock")
        )

        #expect(!state.isAuthenticated)
        #expect(state.currentUser == user)
        #expect(!state.isRestoringSession)
    }

    @Test("Primed state uses fixture user")
    func primedStateUsesFixtureUser() {
        let fixtureUser = ZMUXAuthUser(id: "fixture", primaryEmail: "fixture@example.com", displayName: "Fixture")
        let state = ZMUXAuthState.primed(
            clearAuthRequested: false,
            mockDataEnabled: false,
            fixtureUser: fixtureUser,
            autoLoginCredentials: nil,
            cachedUser: nil,
            hasTokens: false,
            mockUser: ZMUXAuthUser(id: "mock", primaryEmail: "mock@example.com", displayName: "Mock")
        )

        #expect(state.isAuthenticated)
        #expect(state.currentUser == fixtureUser)
        #expect(!state.isRestoringSession)
    }

    @Test("Cleared state clears auth")
    func clearedStateClearsAuth() {
        #expect(ZMUXAuthState.cleared() == ZMUXAuthState(isAuthenticated: false, currentUser: nil, isRestoringSession: false))
    }

    @Test("Identity store and session cache round trip")
    func identityStoreAndSessionCacheRoundTrip() throws {
        let store = TestKeyValueStore()
        let identityStore = ZMUXAuthIdentityStore(keyValueStore: store, key: "auth_cached_user")
        let sessionCache = ZMUXAuthSessionCache(keyValueStore: store, key: "auth_has_tokens")
        let user = ZMUXAuthUser(id: "user_123", primaryEmail: "user@example.com", displayName: "Test User")

        try identityStore.save(user)
        #expect(try identityStore.load() == user)

        sessionCache.setHasTokens(true)
        #expect(sessionCache.hasTokens)

        identityStore.clear()
        sessionCache.clear()

        #expect(try identityStore.load() == nil)
        #expect(!sessionCache.hasTokens)
    }
}

private final class TestKeyValueStore: ZMUXAuthKeyValueStore {
    private var storage: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}
