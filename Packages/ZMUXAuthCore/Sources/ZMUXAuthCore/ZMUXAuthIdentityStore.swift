import Foundation

public final class ZMUXAuthIdentityStore: @unchecked Sendable {
    private let keyValueStore: ZMUXAuthKeyValueStore
    private let key: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(keyValueStore: ZMUXAuthKeyValueStore, key: String) {
        self.keyValueStore = keyValueStore
        self.key = key
    }

    public func save(_ user: ZMUXAuthUser) throws {
        let data = try encoder.encode(user)
        keyValueStore.set(data, forKey: key)
    }

    public func load() throws -> ZMUXAuthUser? {
        guard let data = keyValueStore.data(forKey: key) else {
            return nil
        }
        return try decoder.decode(ZMUXAuthUser.self, from: data)
    }

    public func clear() {
        keyValueStore.removeObject(forKey: key)
    }
}
