import ZMUXAuthCore
import Foundation

struct AuthTeamSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let slug: String?

    init(id: String, displayName: String, slug: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.slug = slug
    }
}

enum SettingsPIIDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case visible
    case hidden

    static let key = "zmux.settings.piiDisplayMode"
    static let defaultValue = visible.rawValue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .visible:
            return String(
                localized: "settings.account.displayMode.visible",
                defaultValue: "Show personal info"
            )
        case .hidden:
            return String(
                localized: "settings.account.displayMode.hidden",
                defaultValue: "Hide personal info"
            )
        }
    }
}

final class AuthSettingsStore {
    private enum Keys {
        static let selectedTeamID = "zmux.auth.selectedTeamID"
        static let cachedUser = "zmux.auth.cachedUser"
    }

    let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var selectedTeamID: String? {
        get {
            normalized(userDefaults.string(forKey: Keys.selectedTeamID))
        }
        set {
            if let normalizedValue = normalized(newValue) {
                userDefaults.set(normalizedValue, forKey: Keys.selectedTeamID)
            } else {
                userDefaults.removeObject(forKey: Keys.selectedTeamID)
            }
        }
    }

    func cachedUser() -> ZMUXAuthUser? {
        guard let data = userDefaults.data(forKey: Keys.cachedUser) else { return nil }
        return try? decoder.decode(ZMUXAuthUser.self, from: data)
    }

    func saveCachedUser(_ user: ZMUXAuthUser?) {
        guard let user else {
            userDefaults.removeObject(forKey: Keys.cachedUser)
            return
        }
        guard let data = try? encoder.encode(user) else { return }
        userDefaults.set(data, forKey: Keys.cachedUser)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
