import CryptoKit
import Foundation

struct ZmuxActionTrustDescriptor: Codable, Sendable {
    var schemaVersion: Int = 1
    var actionID: String
    var kind: String
    var command: String?
    var target: String?
    var workspaceCommand: ZmuxCommandDefinition?
    var configPath: String?
    var projectRoot: String?
    var iconFingerprint: String?

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return Self.sha256Hex(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class ZmuxActionTrust {
    static let shared = ZmuxActionTrust()
    static let didChangeNotification = Notification.Name("zmux.actionTrustDidChange")

    private let storePath: String
    private var trustedFingerprints: Set<String>

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("zmux")
        storePath = appSupport.appendingPathComponent("trusted-actions.json").path

        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupport.path) {
            try? fm.createDirectory(atPath: appSupport.path, withIntermediateDirectories: true)
        }

        if let data = fm.contents(atPath: storePath),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            trustedFingerprints = Set(values)
        } else {
            trustedFingerprints = []
        }
    }

    func isTrusted(_ descriptor: ZmuxActionTrustDescriptor) -> Bool {
        trustedFingerprints.contains(descriptor.fingerprint)
    }

    func trust(_ descriptor: ZmuxActionTrustDescriptor) {
        trustedFingerprints.insert(descriptor.fingerprint)
        save()
    }

    func clearAll() {
        trustedFingerprints.removeAll()
        save()
    }

    var allTrustedFingerprints: [String] {
        trustedFingerprints.sorted()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(trustedFingerprints.sorted()) else { return }
        FileManager.default.createFile(atPath: storePath, contents: data)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
