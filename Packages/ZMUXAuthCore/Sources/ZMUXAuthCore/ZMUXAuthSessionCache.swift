import Foundation

public protocol ZMUXAuthKeyValueStore: AnyObject {
    func bool(forKey defaultName: String) -> Bool
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: ZMUXAuthKeyValueStore {}

public final class ZMUXAuthSessionCache: @unchecked Sendable {
    private let keyValueStore: ZMUXAuthKeyValueStore
    private let key: String

    public init(keyValueStore: ZMUXAuthKeyValueStore, key: String) {
        self.keyValueStore = keyValueStore
        self.key = key
    }

    public var hasTokens: Bool {
        keyValueStore.bool(forKey: key)
    }

    public func setHasTokens(_ value: Bool) {
        keyValueStore.set(value, forKey: key)
    }

    public func clear() {
        keyValueStore.removeObject(forKey: key)
    }
}
