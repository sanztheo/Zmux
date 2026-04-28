import Bonsplit
import Combine
import CryptoKit
import Foundation

struct ZmuxConfigFile: Codable, Sendable {
    var actions: [String: ZmuxConfigActionDefinition]
    var ui: ZmuxConfigUIDefinition?
    var newWorkspaceCommand: String?
    var surfaceTabBarButtons: [ZmuxSurfaceTabBarButton]?
    var commands: [ZmuxCommandDefinition]

    private enum CodingKeys: String, CodingKey {
        case actions
        case ui
        case newWorkspaceCommand
        case surfaceTabBarButtons
        case commands
    }

    init(
        actions: [String: ZmuxConfigActionDefinition] = [:],
        ui: ZmuxConfigUIDefinition? = nil,
        newWorkspaceCommand: String? = nil,
        surfaceTabBarButtons: [ZmuxSurfaceTabBarButton]? = nil,
        commands: [ZmuxCommandDefinition] = []
    ) {
        self.actions = actions
        self.ui = ui
        self.newWorkspaceCommand = newWorkspaceCommand
        self.surfaceTabBarButtons = surfaceTabBarButtons
        self.commands = commands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedActions = try container.decodeIfPresent(
            [String: ZmuxConfigActionDefinition].self,
            forKey: .actions
        ) ?? [:]
        actions = try Self.normalizedActions(
            decodedActions,
            codingPath: decoder.codingPath + [CodingKeys.actions]
        )
        ui = try container.decodeIfPresent(ZmuxConfigUIDefinition.self, forKey: .ui)

        if let rawNewWorkspaceCommand = try container.decodeIfPresent(String.self, forKey: .newWorkspaceCommand) {
            let trimmed = rawNewWorkspaceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.newWorkspaceCommand],
                        debugDescription: "newWorkspaceCommand must not be blank"
                    )
                )
            }
            newWorkspaceCommand = trimmed
        } else {
            newWorkspaceCommand = nil
        }

        let rootSurfaceButtons = try container.decodeIfPresent(
            [ZmuxSurfaceTabBarButton].self,
            forKey: .surfaceTabBarButtons
        )
        let configuredSurfaceButtons = ui?.surfaceTabBar?.buttons ?? rootSurfaceButtons
        if let configuredSurfaceButtons {
            surfaceTabBarButtons = try Self.validatedSurfaceTabBarButtons(
                configuredSurfaceButtons,
                codingPath: decoder.codingPath + [
                    ui?.surfaceTabBar?.buttons == nil ? CodingKeys.surfaceTabBarButtons : CodingKeys.ui
                ]
            )
        } else {
            surfaceTabBarButtons = nil
        }
        commands = try container.decodeIfPresent([ZmuxCommandDefinition].self, forKey: .commands) ?? []
    }

    private static func normalizedActions(
        _ decodedActions: [String: ZmuxConfigActionDefinition],
        codingPath: [CodingKey]
    ) throws -> [String: ZmuxConfigActionDefinition] {
        var actions: [String: ZmuxConfigActionDefinition] = [:]
        for (rawID, action) in decodedActions {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions keys must not be blank"
                    )
                )
            }
            if actions[id] != nil {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions must not contain duplicate ids"
                    )
                )
            }
            actions[id] = action
        }
        return actions
    }

    private static func validatedSurfaceTabBarButtons(
        _ buttons: [ZmuxSurfaceTabBarButton],
        codingPath: [CodingKey]
    ) throws -> [ZmuxSurfaceTabBarButton] {
        var seen = Set<String>()
        for button in buttons {
            if !seen.insert(button.id).inserted {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "surface tab bar buttons must not contain duplicate ids"
                    )
                )
            }
        }
        return buttons
    }
}

enum ZmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newTerminal = "zmux.newTerminal"
    case newBrowser = "zmux.newBrowser"
    case splitRight = "zmux.splitRight"
    case splitDown = "zmux.splitDown"

    init?(configID: String) {
        switch configID {
        case "zmux.newTerminal", "newTerminal":
            self = .newTerminal
        case "zmux.newBrowser", "newBrowser":
            self = .newBrowser
        case "zmux.splitRight", "splitRight":
            self = .splitRight
        case "zmux.splitDown", "splitDown":
            self = .splitDown
        default:
            return nil
        }
    }

    var configID: String {
        rawValue
    }

    var defaultIcon: String {
        switch self {
        case .newTerminal:
            return "terminal"
        case .newBrowser:
            return "globe"
        case .splitRight:
            return "square.split.2x1"
        case .splitDown:
            return "square.split.1x2"
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action {
        switch self {
        case .newTerminal:
            return .newTerminal
        case .newBrowser:
            return .newBrowser
        case .splitRight:
            return .splitRight
        case .splitDown:
            return .splitDown
        }
    }
}

enum ZmuxConfigTerminalCommandTarget: String, Codable, Sendable, Hashable {
    case currentTerminal
    case newTabInCurrentPane

    static let defaultForActions: ZmuxConfigTerminalCommandTarget = .newTabInCurrentPane
}

extension ZmuxSurfaceTabBarBuiltInAction {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let action = Self(configID: value) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown built-in action '\(value)'"
                )
            )
        }
        self = action
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(configID)
    }
}

enum ZmuxConfigAgentKind: Sendable, Hashable {
    case codex
    case claudeCode

    var commandName: String {
        switch self {
        case .codex:
            return "codex"
        case .claudeCode:
            return "claude"
        }
    }

    var defaultIcon: ZmuxButtonIcon {
        switch self {
        case .codex:
            return .symbol("sparkles")
        case .claudeCode:
            return .symbol("brain.head.profile")
        }
    }
}

extension ZmuxConfigAgentKind: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "codex":
            self = .codex
        case "claude", "claudeCode", "claude-code":
            self = .claudeCode
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown agent '\(value)'"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .codex:
            try container.encode("codex")
        case .claudeCode:
            try container.encode("claude")
        }
    }
}

enum ZmuxButtonIcon: Codable, Sendable, Hashable {
    case symbol(String)
    case emoji(String, scale: Double = 1)
    case imagePath(String)

    var symbolName: String {
        if case .symbol(let name) = self {
            return name
        }
        return "questionmark.circle"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case value
        case path
        case scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try Self.trimmedString(forKey: .type, in: container)
        switch type {
        case "symbol", "sfSymbol", "systemImage":
            self = .symbol(try Self.trimmedString(forKey: .name, in: container))
        case "emoji":
            self = .emoji(
                try Self.trimmedString(forKey: .value, in: container),
                scale: try Self.emojiScale(in: container)
            )
        case "image", "file":
            self = .imagePath(try Self.trimmedString(forKey: .path, in: container))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown icon type '\(type)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let name):
            try container.encode("symbol", forKey: .type)
            try container.encode(name, forKey: .name)
        case .emoji(let value, let scale):
            try container.encode("emoji", forKey: .type)
            try container.encode(value, forKey: .value)
            if scale != 1 {
                try container.encode(scale, forKey: .scale)
            }
        case .imagePath(let path):
            try container.encode("image", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }

    func bonsplitIcon(
        configSourcePath: String?,
        globalConfigPath: String,
        allowProjectLocalImage: Bool = true
    ) -> BonsplitConfiguration.SplitActionButton.Icon {
        switch self {
        case .symbol(let name):
            return .systemImage(name)
        case .emoji(let value, let scale):
            return .emoji(value, scale: scale)
        case .imagePath(let path):
            guard let preparedImage = Self.preparedImageAsset(
                path,
                relativeToConfig: configSourcePath,
                globalConfigPath: globalConfigPath
            ) else {
                NSLog("[ZmuxConfig] icon image path is not allowed: %@", path)
                return .systemImage("questionmark.circle")
            }
            if preparedImage.isProjectLocal && !allowProjectLocalImage {
                return .systemImage("lock.fill")
            }
            return .imageData(preparedImage.data)
        }
    }

    func projectLocalImageFingerprint(configSourcePath: String?, globalConfigPath: String) -> String? {
        guard case .imagePath(let path) = self,
              let preparedImage = Self.preparedImageAsset(
                  path,
                  relativeToConfig: configSourcePath,
                  globalConfigPath: globalConfigPath
              ),
              preparedImage.isProjectLocal else {
            return nil
        }
        return preparedImage.fingerprint
    }

    func resolvingRelativeImagePath(relativeToConfig configSourcePath: String?) -> ZmuxButtonIcon {
        guard case .imagePath(let path) = self else { return self }
        return .imagePath(Self.resolvePath(path, relativeToConfig: configSourcePath))
    }

    private static let maxImageBytes = 1_000_000

    private static func emojiScale(in container: KeyedDecodingContainer<CodingKeys>) throws -> Double {
        let scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        guard scale.isFinite, scale > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .scale,
                in: container,
                debugDescription: "Emoji icon scale must be a positive number"
            )
        }
        return scale
    }

    private struct PreparedImageAsset {
        let data: Data
        let fingerprint: String
        let isProjectLocal: Bool
    }

    private static func looksLikeSVGPath(_ value: String) -> Bool {
        (value as NSString).pathExtension.lowercased() == "svg"
    }

    private static func isSafeSVG(data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lowered = text.lowercased()
        guard !lowered.contains("<!doctype"),
              !lowered.contains("<!entity") else {
            return false
        }

        let inspector = SVGSecurityInspector()
        return inspector.parse(data: data)
    }

    private static func resolvePath(_ path: String, relativeToConfig configSourcePath: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return expanded
        }
        guard let configSourcePath else { return expanded }
        let base = (configSourcePath as NSString).deletingLastPathComponent
        return (base as NSString).appendingPathComponent(expanded)
    }

    private static func safeResolvedImagePath(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().hasPrefix("http://"),
              !trimmed.lowercased().hasPrefix("https://") else {
            return nil
        }

        let isGlobal = configSourcePath == nil || configSourcePath == globalConfigPath
        if !isGlobal {
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard !(expanded as NSString).isAbsolutePath,
                  expanded == trimmed else {
                return nil
            }
        }

        let resolvedPath = resolvePath(trimmed, relativeToConfig: configSourcePath)
        guard !resolvedPath.isEmpty else { return nil }
        let standardizedPath = (resolvedPath as NSString).standardizingPath

        guard !isGlobal, let configSourcePath else {
            return standardizedPath
        }

        let allowedRoot = projectRoot(forConfigPath: configSourcePath)
        let resolvedURL = URL(fileURLWithPath: standardizedPath).resolvingSymlinksInPath()
        let allowedURL = URL(fileURLWithPath: allowedRoot).resolvingSymlinksInPath()
        let resolved = resolvedURL.path
        let allowed = allowedURL.path
        guard resolved == allowed || resolved.hasPrefix(allowed + "/") else {
            return nil
        }
        return resolved
    }

    private static func preparedImageAsset(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
    ) -> PreparedImageAsset? {
        guard let resolvedPath = safeResolvedImagePath(
            path,
            relativeToConfig: configSourcePath,
            globalConfigPath: globalConfigPath
        ) else {
            return nil
        }
        guard let data = FileManager.default.contents(atPath: resolvedPath) else {
            NSLog("[ZmuxConfig] icon image does not exist: %@", resolvedPath)
            return nil
        }
        guard data.count <= maxImageBytes else {
            NSLog("[ZmuxConfig] icon image is too large: %@", resolvedPath)
            return nil
        }
        if looksLikeSVGPath(resolvedPath), !isSafeSVG(data: data) {
            NSLog("[ZmuxConfig] icon SVG contains unsupported content: %@", resolvedPath)
            return nil
        }

        let isProjectLocal = configSourcePath != nil && configSourcePath != globalConfigPath
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PreparedImageAsset(data: data, fingerprint: fingerprint, isProjectLocal: isProjectLocal)
    }

    static func projectRoot(forConfigPath configPath: String) -> String {
        let configDir = (configPath as NSString).deletingLastPathComponent
        if (configDir as NSString).lastPathComponent == ".zmux" {
            return (configDir as NSString).deletingLastPathComponent
        }
        return configDir
    }

    private final class SVGSecurityInspector: NSObject, XMLParserDelegate {
        private var isSafe = true
        private var elementStack: [String] = []

        func parse(data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldProcessNamespaces = false
            parser.shouldResolveExternalEntities = false
            let parsed = parser.parse()
            return parsed && isSafe
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let loweredName = elementName.lowercased()
            elementStack.append(loweredName)

            if loweredName == "script" || loweredName == "foreignobject" {
                markUnsafe(parser)
                return
            }

            for (name, value) in attributeDict {
                guard Self.isSafeSVGAttribute(name: name, value: value) else {
                    markUnsafe(parser)
                    return
                }
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard !elementStack.isEmpty else { return }
            elementStack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard elementStack.last == "style" else { return }
            guard Self.isSafeSVGStyle(string) else {
                markUnsafe(parser)
                return
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard elementStack.last == "style",
                  let text = String(data: CDATABlock, encoding: .utf8) else {
                return
            }
            guard Self.isSafeSVGStyle(text) else {
                markUnsafe(parser)
                return
            }
        }

        func parser(
            _ parser: XMLParser,
            foundProcessingInstructionWithTarget target: String,
            data: String?
        ) {
            if target.lowercased() == "xml-stylesheet" {
                markUnsafe(parser)
            }
        }

        private func markUnsafe(_ parser: XMLParser) {
            isSafe = false
            parser.abortParsing()
        }

        private static func isSafeSVGAttribute(name: String, value: String) -> Bool {
            let loweredName = name.lowercased()
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredValue = trimmedValue.lowercased()

            if loweredName.hasPrefix("on") {
                return false
            }

            if loweredName == "xmlns" || loweredName.hasPrefix("xmlns:") {
                return true
            }

            if loweredName == "href" || loweredName == "xlink:href" {
                return isSafeSVGReference(trimmedValue)
            }

            if containsBlockedSVGValue(loweredValue) {
                return false
            }

            if loweredValue.contains("url(") {
                return containsOnlyInternalSVGURLs(trimmedValue)
            }

            return true
        }

        private static func isSafeSVGStyle(_ value: String) -> Bool {
            let loweredValue = value.lowercased()
            guard !loweredValue.contains("@import"),
                  !containsBlockedSVGValue(loweredValue) else {
                return false
            }
            if loweredValue.contains("url(") {
                return containsOnlyInternalSVGURLs(value)
            }
            return true
        }

        private static func isSafeSVGReference(_ value: String) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return true }
            if trimmedValue.hasPrefix("#") {
                return true
            }
            if trimmedValue.lowercased().hasPrefix("url(") {
                return containsOnlyInternalSVGURLs(trimmedValue)
            }
            return false
        }

        private static func containsBlockedSVGValue(_ value: String) -> Bool {
            let blockedFragments = [
                "javascript:",
                "data:",
                "http://",
                "https://",
                "file://",
                "blob:"
            ]
            return blockedFragments.contains { value.contains($0) }
        }

        private static func containsOnlyInternalSVGURLs(_ value: String) -> Bool {
            let loweredValue = value.lowercased()
            var searchStart = loweredValue.startIndex

            while let range = loweredValue.range(
                of: "url(",
                options: [],
                range: searchStart..<loweredValue.endIndex
            ) {
                let contentStart = range.upperBound
                guard let closing = loweredValue[contentStart...].firstIndex(of: ")") else {
                    return false
                }

                var reference = String(loweredValue[contentStart..<closing])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if (reference.hasPrefix("\"") && reference.hasSuffix("\"")) ||
                    (reference.hasPrefix("'") && reference.hasSuffix("'")) {
                    reference.removeFirst()
                    reference.removeLast()
                }

                guard reference.hasPrefix("#") else {
                    return false
                }

                searchStart = loweredValue.index(after: closing)
            }

            return true
        }
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

struct ZmuxConfigUIDefinition: Codable, Sendable, Hashable {
    var newWorkspace: ZmuxConfigButtonPlacement?
    var surfaceTabBar: ZmuxSurfaceTabBarUIDefinition?
}

struct ZmuxSurfaceTabBarUIDefinition: Codable, Sendable, Hashable {
    var buttons: [ZmuxSurfaceTabBarButton]?
}

struct ZmuxConfigButtonPlacement: Codable, Sendable, Hashable {
    var action: String?
    var icon: ZmuxButtonIcon?
    var tooltip: String?

    private enum CodingKeys: String, CodingKey {
        case action
        case icon
        case tooltip
    }

    init(action: String? = nil, icon: ZmuxButtonIcon? = nil, tooltip: String? = nil) {
        self.action = action
        self.icon = icon
        self.tooltip = tooltip
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try Self.trimmedString(forKey: .action, in: container)
        icon = try container.decodeIfPresent(ZmuxButtonIcon.self, forKey: .icon)
        tooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        allowBlankAsNil: Bool = false
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowBlankAsNil { return nil }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

struct ZmuxConfigActionDefinition: Codable, Sendable, Hashable {
    var action: ZmuxSurfaceTabBarButtonAction?
    var title: String?
    var subtitle: String?
    var keywords: [String]?
    var palette: Bool?
    var shortcut: StoredShortcut?
    var icon: ZmuxButtonIcon?
    var tooltip: String?
    var confirm: Bool?
    var terminalCommandTarget: ZmuxConfigTerminalCommandTarget?

    private enum CodingKeys: String, CodingKey {
        case type
        case builtin
        case command
        case commandName
        case name
        case agent
        case args
        case title
        case subtitle
        case description
        case keywords
        case palette
        case shortcut
        case icon
        case tooltip
        case confirm
        case target
    }

    init(
        action: ZmuxSurfaceTabBarButtonAction? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        keywords: [String]? = nil,
        palette: Bool? = nil,
        shortcut: StoredShortcut? = nil,
        icon: ZmuxButtonIcon? = nil,
        tooltip: String? = nil,
        confirm: Bool? = nil,
        terminalCommandTarget: ZmuxConfigTerminalCommandTarget? = nil
    ) {
        self.action = action
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.palette = palette
        self.shortcut = shortcut
        self.icon = icon
        self.tooltip = tooltip
        self.confirm = confirm
        self.terminalCommandTarget = terminalCommandTarget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try Self.trimmedString(forKey: .type, in: container)
        title = try Self.trimmedString(forKey: .title, in: container, allowBlankAsNil: true)
        subtitle = try Self.trimmedString(forKey: .subtitle, in: container, allowBlankAsNil: true)
            ?? Self.trimmedString(forKey: .description, in: container, allowBlankAsNil: true)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        palette = try container.decodeIfPresent(Bool.self, forKey: .palette)
        shortcut = try Self.decodeShortcut(forKey: .shortcut, in: container)
        icon = try container.decodeIfPresent(ZmuxButtonIcon.self, forKey: .icon)
        tooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
        terminalCommandTarget = try container.decodeIfPresent(ZmuxConfigTerminalCommandTarget.self, forKey: .target)

        let inferredType: String?
        if let type {
            inferredType = type
        } else if container.contains(.agent) {
            inferredType = "agent"
        } else if container.contains(.builtin) {
            inferredType = "builtin"
        } else if container.contains(.command) {
            inferredType = "command"
        } else {
            inferredType = nil
        }

        switch inferredType {
        case "builtin":
            let raw = try Self.trimmedString(forKey: .builtin, in: container) ?? ""
            guard let builtIn = ZmuxSurfaceTabBarBuiltInAction(configID: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .builtin,
                    in: container,
                    debugDescription: "Unknown built-in action '\(raw)'"
                )
            }
            action = .builtIn(builtIn)
        case "command":
            let command = try Self.requiredTrimmedString(forKey: .command, in: container)
            action = .command(command)
        case "agent":
            let agent = try container.decode(ZmuxConfigAgentKind.self, forKey: .agent)
            let args = try Self.trimmedString(forKey: .args, in: container, allowBlankAsNil: true)
            action = .agent(agent, args: args)
        case "workspaceCommand":
            let commandName = try Self.trimmedString(forKey: .commandName, in: container)
                ?? Self.trimmedString(forKey: .name, in: container)
                ?? Self.trimmedString(forKey: .command, in: container)
            guard let commandName else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "workspaceCommand actions require commandName"
                    )
                )
            }
            action = .workspaceCommand(commandName)
        case nil:
            action = nil
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown action type '\(inferredType ?? "")'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(keywords, forKey: .keywords)
        try container.encodeIfPresent(palette, forKey: .palette)
        try Self.encodeShortcut(shortcut, forKey: .shortcut, in: &container)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(confirm, forKey: .confirm)
        try container.encodeIfPresent(terminalCommandTarget, forKey: .target)
        guard let action else { return }
        switch action {
        case .builtIn(let builtIn):
            try container.encode("builtin", forKey: .type)
            try container.encode(builtIn.configID, forKey: .builtin)
        case .command(let command):
            try container.encode("command", forKey: .type)
            try container.encode(command, forKey: .command)
        case .agent(let agent, let args):
            try container.encode("agent", forKey: .type)
            try container.encode(agent, forKey: .agent)
            try container.encodeIfPresent(args, forKey: .args)
        case .workspaceCommand(let commandName):
            try container.encode("workspaceCommand", forKey: .type)
            try container.encode(commandName, forKey: .commandName)
        case .actionReference(let identifier):
            try container.encode("builtin", forKey: .type)
            try container.encode(identifier, forKey: .builtin)
        }
    }

    private static func requiredTrimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        guard let value = try trimmedString(forKey: key, in: container) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "\(key.stringValue) is required"
                )
            )
        }
        return value
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        allowBlankAsNil: Bool = false
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowBlankAsNil { return nil }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }

    private static func decodeShortcut(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> StoredShortcut? {
        guard container.contains(key) else { return nil }
        if let rawShortcut = try? container.decode(String.self, forKey: key) {
            guard let shortcut = StoredShortcut.parseConfig(rawShortcut) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "shortcut must use modifier+key syntax like 'cmd+shift+t'"
                )
            }
            return shortcut
        }
        if let rawShortcut = try? container.decode([String].self, forKey: key) {
            guard let shortcut = StoredShortcut.parseConfig(strokes: rawShortcut) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "shortcut chords must be one or two non-empty strokes"
                )
            }
            return shortcut
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "shortcut must be a string or array of one or two strings"
        )
    }

    private static func encodeShortcut(
        _ shortcut: StoredShortcut?,
        forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        guard let shortcut else { return }
        if let secondStroke = shortcut.secondStroke {
            try container.encode(
                [shortcut.firstStroke.configString(), secondStroke.configString()],
                forKey: key
            )
        } else {
            try container.encode(shortcut.firstStroke.configString(), forKey: key)
        }
    }
}

enum ZmuxSurfaceTabBarButtonAction: Sendable, Hashable {
    case builtIn(ZmuxSurfaceTabBarBuiltInAction)
    case command(String)
    case agent(ZmuxConfigAgentKind, args: String?)
    case workspaceCommand(String)
    case actionReference(String)

    var defaultId: String {
        switch self {
        case .builtIn(let action):
            return action.configID
        case .command(let command):
            return "command." + Self.generatedCommandId(for: command)
        case .agent(let agent, _):
            return agent.commandName
        case .workspaceCommand(let commandName):
            return "workspaceCommand." + Self.generatedCommandId(for: commandName)
        case .actionReference(let identifier):
            return identifier
        }
    }

    var defaultIcon: String {
        defaultButtonIcon.symbolName
    }

    var defaultButtonIcon: ZmuxButtonIcon {
        switch self {
        case .builtIn(let action):
            return .symbol(action.defaultIcon)
        case .command:
            return .symbol("terminal")
        case .agent(let agent, _):
            return agent.defaultIcon
        case .workspaceCommand:
            return .symbol("rectangle.stack.badge.plus")
        case .actionReference:
            return .symbol("questionmark.circle")
        }
    }

    var terminalCommand: String? {
        switch self {
        case .command(let command):
            return command
        case .agent(let agent, let args):
            let trimmedArgs = args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedArgs.isEmpty ? agent.commandName : "\(agent.commandName) \(trimmedArgs)"
        case .builtIn, .workspaceCommand, .actionReference:
            return nil
        }
    }

    var workspaceCommandName: String? {
        if case .workspaceCommand(let name) = self {
            return name
        }
        return nil
    }

    private static func generatedCommandId(for command: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let encoded = command.addingPercentEncoding(withAllowedCharacters: allowed) ?? command
        return encoded.isEmpty ? "command" : encoded
    }
}

struct ZmuxSurfaceTabBarButton: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String?
    var icon: ZmuxButtonIcon?
    var tooltip: String?
    var action: ZmuxSurfaceTabBarButtonAction
    var confirm: Bool?
    var terminalCommandTarget: ZmuxConfigTerminalCommandTarget?
    var actionSourcePath: String?
    var iconSourcePath: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case icon
        case tooltip
        case action
        case builtin
        case command
        case agent
        case args
        case type
        case commandName
        case name
        case confirm
        case target
    }

    static let newTerminal = actionReference(ZmuxSurfaceTabBarBuiltInAction.newTerminal.configID)
    static let newBrowser = actionReference(ZmuxSurfaceTabBarBuiltInAction.newBrowser.configID)
    static let splitRight = actionReference(ZmuxSurfaceTabBarBuiltInAction.splitRight.configID)
    static let splitDown = actionReference(ZmuxSurfaceTabBarBuiltInAction.splitDown.configID)

    static let defaults: [ZmuxSurfaceTabBarButton] = [
        .newTerminal,
        .newBrowser,
        .splitRight,
        .splitDown
    ]

    static func builtIn(
        _ action: ZmuxSurfaceTabBarBuiltInAction,
        id: String? = nil,
        title: String? = nil,
        icon: ZmuxButtonIcon? = nil,
        tooltip: String? = nil
    ) -> ZmuxSurfaceTabBarButton {
        ZmuxSurfaceTabBarButton(
            id: id ?? action.configID,
            title: title,
            icon: icon,
            tooltip: tooltip,
            action: .builtIn(action),
            confirm: nil,
            terminalCommandTarget: nil
        )
    }

    static func actionReference(
        _ actionID: String,
        title: String? = nil,
        icon: ZmuxButtonIcon? = nil,
        tooltip: String? = nil
    ) -> ZmuxSurfaceTabBarButton {
        ZmuxSurfaceTabBarButton(
            id: actionID,
            title: title,
            icon: icon,
            tooltip: tooltip,
            action: .actionReference(actionID)
        )
    }

    var command: String? {
        action.terminalCommand
    }

    var terminalCommand: String? {
        action.terminalCommand
    }

    var resolvedTerminalCommandTarget: ZmuxConfigTerminalCommandTarget {
        terminalCommandTarget ?? ZmuxConfigTerminalCommandTarget.defaultForActions
    }

    var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    func bonsplitActionButton(
        configSourcePath: String?,
        globalConfigPath: String,
        allowProjectLocalIcon: Bool = true
    ) -> BonsplitConfiguration.SplitActionButton {
        let bonsplitAction: BonsplitConfiguration.SplitActionButton.Action = {
            switch action {
            case .builtIn(let builtIn):
                return builtIn.bonsplitAction
            case .command, .agent, .workspaceCommand, .actionReference:
                return .custom(id)
            }
        }()

        return BonsplitConfiguration.SplitActionButton(
            id: id,
            icon: (icon ?? action.defaultButtonIcon).bonsplitIcon(
                configSourcePath: iconSourcePath ?? configSourcePath,
                globalConfigPath: globalConfigPath,
                allowProjectLocalImage: allowProjectLocalIcon
            ),
            tooltip: tooltip ?? title ?? terminalCommand,
            action: bonsplitAction
        )
    }

    init(
        id: String,
        title: String? = nil,
        icon: ZmuxButtonIcon? = nil,
        tooltip: String? = nil,
        action: ZmuxSurfaceTabBarButtonAction,
        confirm: Bool? = nil,
        terminalCommandTarget: ZmuxConfigTerminalCommandTarget? = nil,
        actionSourcePath: String? = nil,
        iconSourcePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.tooltip = tooltip
        self.action = action
        self.confirm = confirm
        self.terminalCommandTarget = terminalCommandTarget
        self.actionSourcePath = actionSourcePath
        self.iconSourcePath = iconSourcePath
    }

    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "surface tab bar button action must not be blank"
                    )
                )
            }
            self = ZmuxSurfaceTabBarButton(
                id: ZmuxSurfaceTabBarBuiltInAction(configID: trimmed)?.configID ?? trimmed,
                action: .actionReference(ZmuxSurfaceTabBarBuiltInAction(configID: trimmed)?.configID ?? trimmed)
            )
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let explicitId = try Self.trimmedString(forKey: .id, in: container)
        let explicitTitle = try Self.trimmedString(forKey: .title, in: container, allowBlankAsNil: true)
        let explicitIcon = try container.decodeIfPresent(ZmuxButtonIcon.self, forKey: .icon)
        let explicitTooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
        let rawAction = try Self.trimmedString(forKey: .action, in: container)
        let rawBuiltin = try Self.trimmedString(forKey: .builtin, in: container)
        let rawCommand = try Self.trimmedString(forKey: .command, in: container)
        let rawAgent = try container.decodeIfPresent(ZmuxConfigAgentKind.self, forKey: .agent)
        let rawArgs = try Self.trimmedString(forKey: .args, in: container, allowBlankAsNil: true)
        let rawType = try Self.trimmedString(forKey: .type, in: container)
        let rawCommandName = try Self.trimmedString(forKey: .commandName, in: container)
            ?? Self.trimmedString(forKey: .name, in: container)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
        terminalCommandTarget = try container.decodeIfPresent(ZmuxConfigTerminalCommandTarget.self, forKey: .target)
        actionSourcePath = nil
        iconSourcePath = nil

        let definedActionForms = [
            rawAction != nil,
            rawBuiltin != nil,
            rawCommand != nil,
            rawAgent != nil,
            rawType != nil
        ].filter(\.self).count
        if definedActionForms > 1 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "surfaceTabBarButtons entries must define only one of 'action', 'builtin', 'command', 'agent', or 'type'"
                )
            )
        }

        if let rawType {
            switch rawType {
            case "workspaceCommand":
                guard let rawCommandName else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "workspaceCommand surface tab bar buttons require commandName"
                        )
                    )
                }
                action = .workspaceCommand(rawCommandName)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown surface tab bar button type '\(rawType)'"
                )
            }
        } else if let rawCommand {
            action = .command(rawCommand)
        } else if let rawAgent {
            action = .agent(rawAgent, args: rawArgs)
        } else if let rawBuiltin {
            guard let builtIn = ZmuxSurfaceTabBarBuiltInAction(configID: rawBuiltin) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .builtin,
                    in: container,
                    debugDescription: "Unknown built-in surface tab bar action '\(rawBuiltin)'"
                )
            }
            action = .builtIn(builtIn)
        } else if let rawAction {
            action = .actionReference(rawAction)
        } else if let explicitId,
                  let builtIn = ZmuxSurfaceTabBarBuiltInAction(configID: explicitId) {
            action = .builtIn(builtIn)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "surfaceTabBarButtons entries must define 'action', 'builtin', 'command', 'agent', or 'type'"
                )
            )
        }

        id = explicitId ?? action.defaultId
        title = explicitTitle
        icon = explicitIcon
        tooltip = explicitTooltip
    }

    func resolved(
        actions: [String: ZmuxResolvedConfigAction],
        codingPath: [CodingKey]
    ) throws -> ZmuxSurfaceTabBarButton {
        guard case .actionReference(let identifier) = action else {
            return self
        }

        if let definition = actions[identifier] {
            return ZmuxSurfaceTabBarButton(
                id: id,
                title: title ?? definition.title,
                icon: icon ?? definition.icon,
                tooltip: tooltip ?? definition.tooltip,
                action: definition.action,
                confirm: confirm ?? definition.confirm,
                terminalCommandTarget: terminalCommandTarget ?? definition.terminalCommandTarget,
                actionSourcePath: definition.actionSourcePath,
                iconSourcePath: icon == nil ? definition.iconSourcePath : iconSourcePath
            )
        }

        if let builtIn = ZmuxSurfaceTabBarBuiltInAction(configID: identifier) {
            return ZmuxSurfaceTabBarButton(
                id: id,
                title: title,
                icon: icon,
                tooltip: tooltip,
                action: .builtIn(builtIn),
                confirm: confirm,
                terminalCommandTarget: terminalCommandTarget
            )
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unknown action reference '\(identifier)'"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(confirm, forKey: .confirm)
        try container.encodeIfPresent(terminalCommandTarget, forKey: .target)

        switch action {
        case .builtIn(let builtIn):
            try container.encode(builtIn.configID, forKey: .builtin)
        case .command(let command):
            try container.encode(command, forKey: .command)
        case .agent(let agent, let args):
            try container.encode(agent, forKey: .agent)
            try container.encodeIfPresent(args, forKey: .args)
        case .workspaceCommand(let commandName):
            try container.encode("workspaceCommand", forKey: .type)
            try container.encode(commandName, forKey: .commandName)
        case .actionReference(let identifier):
            try container.encode(identifier, forKey: .action)
        }
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        allowBlankAsNil: Bool = false
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowBlankAsNil { return nil }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

struct ZmuxResolvedConfigAction: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var keywords: [String]
    var palette: Bool
    var shortcut: StoredShortcut?
    var icon: ZmuxButtonIcon?
    var tooltip: String?
    var action: ZmuxSurfaceTabBarButtonAction
    var confirm: Bool?
    var terminalCommandTarget: ZmuxConfigTerminalCommandTarget?
    var actionSourcePath: String?
    var iconSourcePath: String?

    var terminalCommand: String? {
        action.terminalCommand
    }

    var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    func applying(
        _ definition: ZmuxConfigActionDefinition,
        sourcePath: String?
    ) -> ZmuxResolvedConfigAction? {
        var next = self
        next.title = definition.title ?? next.title
        next.subtitle = definition.subtitle ?? next.subtitle
        if let keywords = definition.keywords {
            next.keywords = keywords
        }
        next.palette = definition.palette ?? next.palette
        next.shortcut = definition.shortcut ?? next.shortcut
        if let icon = definition.icon {
            next.icon = icon
            next.iconSourcePath = sourcePath
        }
        next.tooltip = definition.tooltip ?? next.tooltip
        next.confirm = definition.confirm ?? next.confirm
        next.terminalCommandTarget = definition.terminalCommandTarget ?? next.terminalCommandTarget
        next.actionSourcePath = sourcePath ?? next.actionSourcePath
        if let action = definition.action {
            next.action = action
        }
        return next
    }

    static func fromDefinition(
        id: String,
        definition: ZmuxConfigActionDefinition,
        sourcePath: String?
    ) -> ZmuxResolvedConfigAction? {
        guard let action = definition.action else { return nil }
        let title = definition.title
            ?? definition.tooltip
            ?? Self.defaultTitle(for: id, action: action)
        return ZmuxResolvedConfigAction(
            id: id,
            title: title,
            subtitle: definition.subtitle,
            keywords: definition.keywords ?? [],
            palette: definition.palette ?? true,
            shortcut: definition.shortcut,
            icon: definition.icon ?? action.defaultButtonIcon,
            tooltip: definition.tooltip,
            action: action,
            confirm: definition.confirm,
            terminalCommandTarget: definition.terminalCommandTarget,
            actionSourcePath: sourcePath,
            iconSourcePath: definition.icon == nil ? nil : sourcePath
        )
    }

    static func builtIn(_ builtIn: ZmuxSurfaceTabBarBuiltInAction) -> ZmuxResolvedConfigAction {
        let title: String
        let keywords: [String]
        switch builtIn {
        case .newTerminal:
            title = String(localized: "command.newTerminalTab.title", defaultValue: "New Terminal Tab")
            keywords = ["new", "terminal", "tab", "surface"]
        case .newBrowser:
            title = String(localized: "command.newBrowserTab.title", defaultValue: "New Browser Tab")
            keywords = ["new", "browser", "tab", "surface"]
        case .splitRight:
            title = String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")
            keywords = ["terminal", "split", "right"]
        case .splitDown:
            title = String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")
            keywords = ["terminal", "split", "down"]
        }

        return ZmuxResolvedConfigAction(
            id: builtIn.configID,
            title: title,
            subtitle: String(localized: "command.zmuxConfig.builtInSubtitle", defaultValue: "zmux"),
            keywords: keywords,
            palette: true,
            shortcut: nil,
            icon: .symbol(builtIn.defaultIcon),
            tooltip: nil,
            action: .builtIn(builtIn),
            confirm: nil,
            terminalCommandTarget: nil,
            actionSourcePath: nil,
            iconSourcePath: nil
        )
    }

    private static func defaultTitle(for id: String, action: ZmuxSurfaceTabBarButtonAction) -> String {
        switch action {
        case .agent(let agent, _):
            switch agent {
            case .codex:
                return String(localized: "command.zmuxConfig.defaultCodexTitle", defaultValue: "Codex")
            case .claudeCode:
                return String(localized: "command.zmuxConfig.defaultClaudeCodeTitle", defaultValue: "Claude Code")
            }
        case .command:
            return id
        case .workspaceCommand(let commandName):
            return commandName
        case .builtIn(let builtIn):
            return builtIn.configID
        case .actionReference(let identifier):
            return identifier
        }
    }
}

struct ZmuxCommandDefinition: Codable, Sendable, Identifiable {
    var name: String
    var description: String?
    var keywords: [String]?
    var restart: ZmuxRestartBehavior?
    var workspace: ZmuxWorkspaceDefinition?
    var command: String?
    var confirm: Bool?

    var id: String {
        "zmux.config.command." + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
    }

    init(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        restart: ZmuxRestartBehavior? = nil,
        workspace: ZmuxWorkspaceDefinition? = nil,
        command: String? = nil,
        confirm: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.keywords = keywords
        self.restart = restart
        self.workspace = workspace
        self.command = command
        self.confirm = confirm
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
        restart = try container.decodeIfPresent(ZmuxRestartBehavior.self, forKey: .restart)
        workspace = try container.decodeIfPresent(ZmuxWorkspaceDefinition.self, forKey: .workspace)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command name must not be blank"
                )
            )
        }
        if let cmd = command,
           cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define a blank 'command'"
                )
            )
        }

        if workspace != nil && command != nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define both 'workspace' and 'command'"
                )
            )
        }
        if workspace == nil && command == nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must define either 'workspace' or 'command'"
                )
            )
        }
    }
}

enum ZmuxRestartBehavior: String, Codable, Sendable {
    case recreate
    case ignore
    case confirm
}

struct ZmuxWorkspaceDefinition: Codable, Sendable {
    var name: String?
    var cwd: String?
    var color: String?
    var layout: ZmuxLayoutNode?

    init(name: String? = nil, cwd: String? = nil, color: String? = nil, layout: ZmuxLayoutNode? = nil) {
        self.name = name
        self.cwd = cwd
        self.color = color
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        layout = try container.decodeIfPresent(ZmuxLayoutNode.self, forKey: .layout)

        if let rawColor = try container.decodeIfPresent(String.self, forKey: .color) {
            guard let normalized = WorkspaceTabColorSettings.normalizedHex(rawColor) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .color,
                    in: container,
                    debugDescription: "Invalid color \"\(rawColor)\". Expected 6-digit hex format: #RRGGBB"
                )
            }
            color = normalized
        } else {
            color = nil
        }
    }
}

indirect enum ZmuxLayoutNode: Codable, Sendable {
    case pane(ZmuxPaneDefinition)
    case split(ZmuxSplitDefinition)

    private enum CodingKeys: String, CodingKey {
        case pane
        case direction
        case split
        case children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasPane = container.contains(.pane)
        let hasDirection = container.contains(.direction)

        if hasPane && hasDirection {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ZmuxLayoutNode must not contain both 'pane' and 'direction' keys"
                )
            )
        }

        if hasPane {
            let pane = try container.decode(ZmuxPaneDefinition.self, forKey: .pane)
            self = .pane(pane)
        } else if hasDirection {
            let splitDef = try ZmuxSplitDefinition(from: decoder)
            self = .split(splitDef)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ZmuxLayoutNode must contain either a 'pane' key or a 'direction' key"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .pane(let pane):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try split.encode(to: encoder)
        }
    }
}

struct ZmuxSplitDefinition: Codable, Sendable {
    var direction: ZmuxSplitDirection
    var split: Double?
    var children: [ZmuxLayoutNode]

    init(direction: ZmuxSplitDirection, split: Double? = nil, children: [ZmuxLayoutNode]) {
        self.direction = direction
        self.split = split
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        direction = try container.decode(ZmuxSplitDirection.self, forKey: .direction)
        split = try container.decodeIfPresent(Double.self, forKey: .split)
        children = try container.decode([ZmuxLayoutNode].self, forKey: .children)
        if children.count != 2 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Split node requires exactly 2 children, got \(children.count)"
                )
            )
        }
    }

    var clampedSplitPosition: Double {
        let value = split ?? 0.5
        return min(0.9, max(0.1, value))
    }

    var splitOrientation: SplitOrientation {
        switch direction {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}

enum ZmuxSplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

struct ZmuxPaneDefinition: Codable, Sendable {
    var surfaces: [ZmuxSurfaceDefinition]

    init(surfaces: [ZmuxSurfaceDefinition]) {
        self.surfaces = surfaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaces = try container.decode([ZmuxSurfaceDefinition].self, forKey: .surfaces)
        if surfaces.isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Pane node must contain at least one surface"
                )
            )
        }
    }
}

struct ZmuxSurfaceDefinition: Codable, Sendable {
    var type: ZmuxSurfaceType
    var name: String?
    var command: String?
    var cwd: String?
    var env: [String: String]?
    var url: String?
    var focus: Bool?
}

enum ZmuxSurfaceType: String, Codable, Sendable {
    case terminal
    case browser
}

struct ZmuxResolvedCommand: Sendable {
    let command: ZmuxCommandDefinition
    let sourcePath: String?
}

struct ZmuxConfigIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case newWorkspaceActionRequiresWorkspaceCommand
        case newWorkspaceCommandNotFound
        case newWorkspaceCommandRequiresWorkspace
        case schemaError
    }

    let kind: Kind
    let settingName: String
    let commandName: String?
    let sourcePath: String?
    let message: String?

    init(
        kind: Kind,
        settingName: String,
        commandName: String? = nil,
        sourcePath: String? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.settingName = settingName
        self.commandName = commandName
        self.sourcePath = sourcePath
        self.message = message
    }

    var id: String {
        [
            kind.rawValue,
            settingName,
            commandName ?? "",
            sourcePath ?? "",
            message ?? ""
        ].joined(separator: "|")
    }

    var logMessage: String {
        switch kind {
        case .newWorkspaceActionRequiresWorkspaceCommand:
            return "\(settingName) must reference a workspaceCommand action"
        case .newWorkspaceCommandNotFound:
            return "\(settingName) '\(commandName ?? "")' does not match any loaded command"
        case .newWorkspaceCommandRequiresWorkspace:
            return "\(settingName) '\(commandName ?? "")' must reference a workspace command"
        case .schemaError:
            return "\(settingName) has a schema error: \(message ?? "unknown error")"
        }
    }
}

@MainActor
final class ZmuxConfigStore: ObservableObject {
    @Published private(set) var loadedCommands: [ZmuxCommandDefinition] = []
    @Published private(set) var loadedActions: [ZmuxResolvedConfigAction] = []
    @Published private(set) var newWorkspaceCommandName: String?
    @Published private(set) var newWorkspaceAction: ZmuxConfigActionDefinition?
    @Published private(set) var surfaceTabBarButtons: [ZmuxSurfaceTabBarButton] = ZmuxSurfaceTabBarButton.defaults
    @Published private(set) var configurationIssues: [ZmuxConfigIssue] = []
    @Published private(set) var configRevision: UInt64 = 0

    /// Which config file each command came from, keyed by command id.
    private(set) var commandSourcePaths: [String: String] = [:]
    private(set) var actionLookup: [String: ZmuxResolvedConfigAction] = [:]
    private(set) var surfaceTabBarButtonSourcePath: String?
    private(set) var surfaceTabBarCommandSourcePaths: [String: String] = [:]
    private(set) var newWorkspaceActionSourcePath: String?

    private(set) var localConfigPath: String?
    private weak var tabManager: TabManager?
    let globalConfigPath: String

    nonisolated private static func defaultGlobalConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/zmux/zmux.json")
    }

    private struct ActionEntry {
        let definition: ZmuxConfigActionDefinition
        let sourcePath: String?
    }

    private struct ResolvedSurfaceTabBarButtonEntry {
        let button: ZmuxSurfaceTabBarButton
        let terminalCommandSourcePath: String?
    }

    private struct ResolvedSurfaceTabBarButtons {
        let buttons: [ZmuxSurfaceTabBarButton]
        let terminalCommandSourcePaths: [String: String]
    }

    private struct NewWorkspaceCommandResolution {
        let command: ZmuxResolvedCommand?
        let issue: ZmuxConfigIssue?
    }

    private struct ParsedConfigCacheEntry {
        let fileSize: UInt64
        let modificationDate: Date?
        let config: ZmuxConfigFile?
        let issue: ZmuxConfigIssue?
    }

    private struct ParsedConfigResult {
        let config: ZmuxConfigFile?
        let issue: ZmuxConfigIssue?
    }

    private var surfaceTabBarWorkspaceCommands: [String: ZmuxResolvedCommand] = [:]
    private var resolvedNewWorkspaceCommandCache: ZmuxResolvedCommand?
    private var parsedConfigCache: [String: ParsedConfigCacheEntry] = [:]
    private var lifetimeCancellables = Set<AnyCancellable>()
    private var trackingCancellables = Set<AnyCancellable>()
    private var localFileWatchSource: DispatchSourceFileSystemObject?
    private var localFileDescriptor: Int32 = -1
    private var localConfigSearchDirectory: String?
    private var localFallbackDirectoryWatchSource: DispatchSourceFileSystemObject?
    private var localFallbackDirectoryDescriptor: Int32 = -1
    private var globalFileWatchSource: DispatchSourceFileSystemObject?
    private var globalFileDescriptor: Int32 = -1
    private let watchQueue = DispatchQueue(label: "com.zmux.config-file-watch")

    private static let maxReattachAttempts = 5
    private static let reattachDelay: TimeInterval = 0.5

    private static func searchDirectoryForLocalConfigPath(_ path: String) -> String {
        let configDirectory = (path as NSString).deletingLastPathComponent
        if (configDirectory as NSString).lastPathComponent == ".zmux" {
            return (configDirectory as NSString).deletingLastPathComponent
        }
        return configDirectory
    }

    init(
        globalConfigPath: String = ZmuxConfigStore.defaultGlobalConfigPath(),
        localConfigPath: String? = nil,
        startFileWatchers: Bool = true
    ) {
        self.globalConfigPath = globalConfigPath
        self.localConfigPath = localConfigPath
        self.localConfigSearchDirectory = localConfigPath.map(Self.searchDirectoryForLocalConfigPath(_:))
        NotificationCenter.default.publisher(for: ZmuxActionTrust.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applySurfaceTabBarButtonsToCurrentManager()
                self.configRevision &+= 1
            }
            .store(in: &lifetimeCancellables)
        if startFileWatchers {
            if localConfigPath != nil {
                startLocalFileWatcher()
            }
            startGlobalFileWatcher()
        }
    }

    deinit {
        localFileWatchSource?.cancel()
        localFallbackDirectoryWatchSource?.cancel()
        globalFileWatchSource?.cancel()
    }

    // MARK: - Public API

    func wireDirectoryTracking(tabManager: TabManager) {
        trackingCancellables.removeAll()
        self.tabManager = tabManager

        tabManager.$selectedTabId
            .compactMap { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0.id == $1.id })
            .map { workspace -> AnyPublisher<String?, Never> in
                workspace.$surfaceTabBarDirectory.eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .sink { [weak self] directory in
                self?.updateLocalConfigPath(directory)
            }
            .store(in: &trackingCancellables)

        tabManager.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySurfaceTabBarButtonsToCurrentManager()
            }
            .store(in: &trackingCancellables)

        updateLocalConfigPath(tabManager.selectedWorkspace?.surfaceTabBarDirectory)
    }

    private func updateLocalConfigPath(_ directory: String?) {
        let newPath: String?
        if let directory, !directory.isEmpty {
            localConfigSearchDirectory = directory
            newPath = resolvedLocalConfigPath(startingFrom: directory)
        } else {
            localConfigSearchDirectory = nil
            newPath = nil
        }

        guard newPath != localConfigPath else { return }
        stopLocalFileWatcher()
        localConfigPath = newPath
        if newPath != nil {
            startLocalFileWatcher()
        }
        loadAll()
    }

    private func resolvedLocalConfigPath(startingFrom directory: String) -> String {
        findZmuxConfig(startingFrom: directory)
            ?? defaultLocalConfigPath(startingFrom: directory)
    }

    private func defaultLocalConfigPath(startingFrom directory: String) -> String {
        (((directory as NSString).appendingPathComponent(".zmux") as NSString)
            .appendingPathComponent("zmux.json"))
    }

    private func findZmuxConfig(startingFrom directory: String) -> String? {
        var current = directory
        let fs = FileManager.default
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".zmux") as NSString)
                    .appendingPathComponent("zmux.json"),
                (current as NSString).appendingPathComponent("zmux.json")
            ]
            for candidate in candidates where fs.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    func loadAll() {
        var commands: [ZmuxCommandDefinition] = []
        var seenNames = Set<String>()
        var sourcePaths: [String: String] = [:]
        var configuredNewWorkspaceCommandName: String?
        var configuredNewWorkspaceCommandSourcePath: String?
        var configuredNewWorkspaceAction: ZmuxConfigActionDefinition?
        var configuredNewWorkspaceActionSourcePath: String?
        var configuredSurfaceTabBarButtons: [ZmuxSurfaceTabBarButton]?
        var configuredSurfaceTabBarButtonSourcePath: String?
        let localPath = localConfigPath
        let localParseResult = localPath.map { parseConfig(at: $0) }
        let globalParseResult = parseConfig(at: globalConfigPath)
        let localConfig = localParseResult?.config
        let globalConfig = globalParseResult.config
        var issues = [ZmuxConfigIssue]()
        if let issue = localParseResult?.issue {
            issues.append(issue)
        }
        if let issue = globalParseResult.issue {
            issues.append(issue)
        }
        let localActions = localConfig.map { actionEntries(from: $0.actions, sourcePath: localPath) } ?? [:]
        let globalActions = globalConfig.map { actionEntries(from: $0.actions, sourcePath: globalConfigPath) } ?? [:]
        let localActionLookup = mergedActionEntries(primary: localActions, fallback: globalActions)

        // Local config takes precedence
        if let localConfig {
            if let newWorkspaceActionID = localConfig.ui?.newWorkspace?.action {
                if let action = localActionLookup[newWorkspaceActionID] {
                    configuredNewWorkspaceAction = action.definition
                    configuredNewWorkspaceActionSourcePath = action.sourcePath
                } else {
                    NSLog("[ZmuxConfig] ui.newWorkspace.action '%@' does not match any local or global action", newWorkspaceActionID)
                }
            }
            if configuredNewWorkspaceAction == nil,
               let newWorkspaceCommand = localConfig.newWorkspaceCommand {
                configuredNewWorkspaceCommandName = newWorkspaceCommand
                configuredNewWorkspaceCommandSourcePath = localPath
            }
            if let buttons = localConfig.surfaceTabBarButtons {
                configuredSurfaceTabBarButtons = buttons
                configuredSurfaceTabBarButtonSourcePath = localPath
            }
            for command in localConfig.commands {
                if !seenNames.contains(command.name) {
                    commands.append(command)
                    seenNames.insert(command.name)
                    if let localPath {
                        sourcePaths[command.id] = localPath
                    }
                }
            }
        }

        // Global config fills in the rest
        if let globalConfig {
            if configuredNewWorkspaceAction == nil,
               configuredNewWorkspaceCommandName == nil,
               let newWorkspaceActionID = globalConfig.ui?.newWorkspace?.action {
                if let action = localActionLookup[newWorkspaceActionID] {
                    configuredNewWorkspaceAction = action.definition
                    configuredNewWorkspaceActionSourcePath = action.sourcePath
                } else {
                    NSLog("[ZmuxConfig] ui.newWorkspace.action '%@' does not match any local or global action", newWorkspaceActionID)
                }
            }
            if configuredNewWorkspaceAction == nil,
               configuredNewWorkspaceCommandName == nil,
               let newWorkspaceCommand = globalConfig.newWorkspaceCommand {
                configuredNewWorkspaceCommandName = newWorkspaceCommand
                configuredNewWorkspaceCommandSourcePath = globalConfigPath
            }
            if configuredSurfaceTabBarButtons == nil,
               let buttons = globalConfig.surfaceTabBarButtons {
                configuredSurfaceTabBarButtons = buttons
                configuredSurfaceTabBarButtonSourcePath = globalConfigPath
            }
            for command in globalConfig.commands {
                if !seenNames.contains(command.name) {
                    commands.append(command)
                    seenNames.insert(command.name)
                    sourcePaths[command.id] = globalConfigPath
                }
            }
        }

        let resolvedActions = resolvedActionRegistry(
            globalActions: globalActions,
            localActions: localActions,
            commands: commands,
            commandSourcePaths: sourcePaths
        )
        let resolvedActionLookup = Dictionary(uniqueKeysWithValues: resolvedActions.map { ($0.id, $0) })
        let configuredButtons = configuredSurfaceTabBarButtons ?? ZmuxSurfaceTabBarButton.defaults
        let defaultResolvedButtons = (try? ZmuxSurfaceTabBarButton.defaults.map {
            try $0.resolved(actions: resolvedActionLookup, codingPath: [])
        }) ?? [
            .builtIn(.newTerminal),
            .builtIn(.newBrowser),
            .builtIn(.splitRight),
            .builtIn(.splitDown)
        ]
        let resolvedButtons = resolvedSurfaceTabBarButtons(
            configuredButtons,
            actions: resolvedActionLookup,
            settingName: "ui.surfaceTabBar.buttons"
        ) ?? ResolvedSurfaceTabBarButtons(
            buttons: defaultResolvedButtons,
            terminalCommandSourcePaths: [:]
        )
        let resolvedWorkspaceButtons = resolvedSurfaceTabBarWorkspaceCommands(
            resolvedButtons.buttons,
            commands: commands,
            sourcePaths: sourcePaths
        )
        let resolvedNewWorkspaceCommand = resolvedConfiguredNewWorkspaceCommand(
            action: configuredNewWorkspaceAction,
            actionSourcePath: configuredNewWorkspaceActionSourcePath,
            commandName: configuredNewWorkspaceCommandName,
            commandSourcePath: configuredNewWorkspaceCommandSourcePath,
            commands: commands,
            sourcePaths: sourcePaths
        )

        loadedCommands = commands
        loadedActions = resolvedActions
        commandSourcePaths = sourcePaths
        actionLookup = resolvedActionLookup
        newWorkspaceAction = configuredNewWorkspaceAction
        newWorkspaceActionSourcePath = configuredNewWorkspaceActionSourcePath
        newWorkspaceCommandName = configuredNewWorkspaceCommandName
        surfaceTabBarButtonSourcePath = configuredSurfaceTabBarButtonSourcePath
        surfaceTabBarCommandSourcePaths = resolvedButtons.terminalCommandSourcePaths
        surfaceTabBarWorkspaceCommands = resolvedWorkspaceButtons.workspaceCommands
        surfaceTabBarButtons = resolvedWorkspaceButtons.buttons
        resolvedNewWorkspaceCommandCache = resolvedNewWorkspaceCommand.command
        if let issue = resolvedNewWorkspaceCommand.issue {
            issues.append(issue)
        }
        configurationIssues = issues
        applySurfaceTabBarButtonsToCurrentManager()
        configRevision &+= 1
    }

    private func actionEntries(
        from actions: [String: ZmuxConfigActionDefinition],
        sourcePath: String?
    ) -> [String: ActionEntry] {
        actions.mapValues { ActionEntry(definition: $0, sourcePath: sourcePath) }
    }

    private func mergedActionEntries(
        primary: [String: ActionEntry],
        fallback: [String: ActionEntry]
    ) -> [String: ActionEntry] {
        fallback.merging(primary) { _, primary in primary }
    }

    private func sanitizeConfigText(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(text.unicodeScalars.filter { !dangerous.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedActionRegistry(
        globalActions: [String: ActionEntry],
        localActions: [String: ActionEntry],
        commands: [ZmuxCommandDefinition],
        commandSourcePaths: [String: String]
    ) -> [ZmuxResolvedConfigAction] {
        var registry = Dictionary(
            uniqueKeysWithValues: ZmuxSurfaceTabBarBuiltInAction.allCases.map {
                ($0.configID, ZmuxResolvedConfigAction.builtIn($0))
            }
        )

        func apply(_ entries: [String: ActionEntry]) {
            for (id, entry) in entries {
                if let existing = registry[id] {
                    guard let resolved = existing.applying(entry.definition, sourcePath: entry.sourcePath) else { continue }
                    registry[id] = resolved
                } else if let resolved = ZmuxResolvedConfigAction.fromDefinition(
                    id: id,
                    definition: entry.definition,
                    sourcePath: entry.sourcePath
                ) {
                    registry[id] = resolved
                } else {
                    NSLog("[ZmuxConfig] action '%@' ignored because it does not define a runnable action", id)
                }
            }
        }

        apply(globalActions)
        apply(localActions)

        for command in commands where registry[command.id] == nil {
            let sourcePath = commandSourcePaths[command.id]
            registry[command.id] = ZmuxResolvedConfigAction(
                id: command.id,
                title: String(
                    localized: "command.zmuxConfig.customTitle",
                    defaultValue: "Custom: \(sanitizeConfigText(command.name))"
                ),
                subtitle: command.description.map { sanitizeConfigText($0) }
                    ?? String(localized: "command.zmuxConfig.subtitle", defaultValue: "zmux.json"),
                keywords: command.keywords ?? [],
                palette: true,
                shortcut: nil,
                icon: .symbol(command.workspace == nil ? "terminal" : "rectangle.stack.badge.plus"),
                tooltip: command.description,
                action: command.workspace == nil
                    ? .command(command.command ?? "")
                    : .workspaceCommand(command.name),
                confirm: command.confirm,
                terminalCommandTarget: command.workspace == nil ? .currentTerminal : nil,
                actionSourcePath: sourcePath,
                iconSourcePath: nil
            )
        }

        return registry.values.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private func resolvedSurfaceTabBarButtons(
        _ buttons: [ZmuxSurfaceTabBarButton],
        actions: [String: ZmuxResolvedConfigAction],
        settingName: String
    ) -> ResolvedSurfaceTabBarButtons? {
        var resolvedButtons: [ZmuxSurfaceTabBarButton] = []
        var terminalCommandSourcePaths: [String: String] = [:]
        resolvedButtons.reserveCapacity(buttons.count)

        for button in buttons {
            do {
                let resolved = try resolvedSurfaceTabBarButton(button, actions: actions)
                resolvedButtons.append(resolved.button)
                guard resolved.button.terminalCommand != nil else { continue }
                if let commandSourcePath = resolved.terminalCommandSourcePath {
                    terminalCommandSourcePaths[resolved.button.id] = commandSourcePath
                }
            } catch {
                NSLog("[ZmuxConfig] %@ ignored: %@", settingName, String(describing: error))
                return nil
            }
        }

        return ResolvedSurfaceTabBarButtons(
            buttons: resolvedButtons,
            terminalCommandSourcePaths: terminalCommandSourcePaths
        )
    }

    private func resolvedSurfaceTabBarButton(
        _ button: ZmuxSurfaceTabBarButton,
        actions: [String: ZmuxResolvedConfigAction]
    ) throws -> ResolvedSurfaceTabBarButtonEntry {
        guard case .actionReference(let identifier) = button.action else {
            return ResolvedSurfaceTabBarButtonEntry(button: button, terminalCommandSourcePath: nil)
        }

        if let entry = actions[identifier] {
            let resolvedButton = ZmuxSurfaceTabBarButton(
                id: button.id,
                title: button.title ?? entry.title,
                icon: button.icon ?? entry.icon,
                tooltip: button.tooltip ?? entry.tooltip ?? entry.title,
                action: entry.action,
                confirm: button.confirm ?? entry.confirm,
                terminalCommandTarget: button.terminalCommandTarget ?? entry.terminalCommandTarget,
                actionSourcePath: entry.actionSourcePath,
                iconSourcePath: button.icon == nil ? entry.iconSourcePath : button.iconSourcePath
            )
            return ResolvedSurfaceTabBarButtonEntry(
                button: resolvedButton,
                terminalCommandSourcePath: resolvedButton.terminalCommand == nil ? nil : entry.actionSourcePath
            )
        }

        if let builtIn = ZmuxSurfaceTabBarBuiltInAction(configID: identifier) {
            return ResolvedSurfaceTabBarButtonEntry(
                button: ZmuxSurfaceTabBarButton(
                    id: button.id,
                    title: button.title,
                    icon: button.icon,
                    tooltip: button.tooltip,
                    action: .builtIn(builtIn),
                    confirm: button.confirm,
                    terminalCommandTarget: button.terminalCommandTarget
                ),
                terminalCommandSourcePath: nil
            )
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "Unknown action reference '\(identifier)'"
            )
        )
    }

    private func applySurfaceTabBarButtonsToCurrentManager() {
        tabManager?.applySurfaceTabBarButtons(
            surfaceTabBarButtons,
            sourcePath: surfaceTabBarButtonSourcePath,
            globalConfigPath: globalConfigPath,
            terminalCommandSourcePaths: surfaceTabBarCommandSourcePaths,
            workspaceCommands: surfaceTabBarWorkspaceCommands
        )
    }

    private func resolvedSurfaceTabBarWorkspaceCommands(
        _ buttons: [ZmuxSurfaceTabBarButton],
        commands: [ZmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> (buttons: [ZmuxSurfaceTabBarButton], workspaceCommands: [String: ZmuxResolvedCommand]) {
        var visibleButtons: [ZmuxSurfaceTabBarButton] = []
        var workspaceCommands: [String: ZmuxResolvedCommand] = [:]
        visibleButtons.reserveCapacity(buttons.count)

        for button in buttons {
            guard let commandName = button.workspaceCommandName else {
                visibleButtons.append(button)
                continue
            }

            guard let command = resolvedWorkspaceCommand(
                named: commandName,
                settingName: "surfaceTabBarButtons action",
                commands: commands,
                sourcePaths: sourcePaths
            ) else {
                NSLog(
                    "[ZmuxConfig] surfaceTabBarButtons action '%@' hidden because workspace command '%@' is unavailable",
                    button.id,
                    commandName
                )
                continue
            }

            visibleButtons.append(button)
            workspaceCommands[button.id] = command
        }

        return (visibleButtons, workspaceCommands)
    }

    func resolvedNewWorkspaceCommand() -> ZmuxResolvedCommand? {
        resolvedNewWorkspaceCommandCache
    }

    func resolvedAction(id: String) -> ZmuxResolvedConfigAction? {
        actionLookup[id]
    }

    func paletteCustomActions() -> [ZmuxResolvedConfigAction] {
        let builtInIDs = Set(ZmuxSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.palette && !builtInIDs.contains(action.id)
        }
    }

    func shortcutActions() -> [ZmuxResolvedConfigAction] {
        let builtInIDs = Set(ZmuxSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.shortcut != nil && (builtInIDs.contains(action.id) || action.actionSourcePath != nil)
        }.sorted { lhs, rhs in
            let lhsPriority = builtInIDs.contains(lhs.id) ? 0 : 1
            let rhsPriority = builtInIDs.contains(rhs.id) ? 0 : 1
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private func resolvedConfiguredNewWorkspaceCommand(
        action: ZmuxConfigActionDefinition?,
        actionSourcePath: String?,
        commandName: String?,
        commandSourcePath: String?,
        commands: [ZmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> NewWorkspaceCommandResolution {
        if let action {
            guard let actionCommandName = action.action?.workspaceCommandName else {
                return newWorkspaceResolutionIssue(
                    kind: .newWorkspaceActionRequiresWorkspaceCommand,
                    settingName: "ui.newWorkspace.action",
                    commandName: nil,
                    sourcePath: actionSourcePath
                )
            }
            return resolvedConfiguredNewWorkspaceCommand(
                named: actionCommandName,
                settingName: "ui.newWorkspace.action",
                settingSourcePath: actionSourcePath,
                commands: commands,
                sourcePaths: sourcePaths
            )
        }

        guard let commandName else {
            return NewWorkspaceCommandResolution(command: nil, issue: nil)
        }
        return resolvedConfiguredNewWorkspaceCommand(
            named: commandName,
            settingName: "newWorkspaceCommand",
            settingSourcePath: commandSourcePath,
            commands: commands,
            sourcePaths: sourcePaths
        )
    }

    private func resolvedConfiguredNewWorkspaceCommand(
        named commandName: String,
        settingName: String,
        settingSourcePath: String?,
        commands: [ZmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> NewWorkspaceCommandResolution {
        guard let command = commands.first(where: { $0.name == commandName }) else {
            return newWorkspaceResolutionIssue(
                kind: .newWorkspaceCommandNotFound,
                settingName: settingName,
                commandName: commandName,
                sourcePath: settingSourcePath
            )
        }
        guard command.workspace != nil else {
            return newWorkspaceResolutionIssue(
                kind: .newWorkspaceCommandRequiresWorkspace,
                settingName: settingName,
                commandName: commandName,
                sourcePath: sourcePaths[command.id] ?? settingSourcePath
            )
        }
        return NewWorkspaceCommandResolution(
            command: ZmuxResolvedCommand(command: command, sourcePath: sourcePaths[command.id]),
            issue: nil
        )
    }

    private func newWorkspaceResolutionIssue(
        kind: ZmuxConfigIssue.Kind,
        settingName: String,
        commandName: String?,
        sourcePath: String?
    ) -> NewWorkspaceCommandResolution {
        let issue = ZmuxConfigIssue(
            kind: kind,
            settingName: settingName,
            commandName: commandName,
            sourcePath: sourcePath
        )
        NSLog("[ZmuxConfig] %@", issue.logMessage)
        return NewWorkspaceCommandResolution(command: nil, issue: issue)
    }

    private func resolvedWorkspaceCommand(
        named commandName: String,
        settingName: String
    ) -> ZmuxResolvedCommand? {
        resolvedWorkspaceCommand(
            named: commandName,
            settingName: settingName,
            commands: loadedCommands,
            sourcePaths: commandSourcePaths
        )
    }

    private func resolvedWorkspaceCommand(
        named commandName: String,
        settingName: String,
        commands: [ZmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> ZmuxResolvedCommand? {
        guard let command = commands.first(where: { $0.name == commandName }) else {
            NSLog("[ZmuxConfig] %@ '%@' does not match any loaded command", settingName, commandName)
            return nil
        }
        guard command.workspace != nil else {
            NSLog("[ZmuxConfig] %@ '%@' must reference a workspace command", settingName, commandName)
            return nil
        }
        return ZmuxResolvedCommand(command: command, sourcePath: sourcePaths[command.id])
    }

    // MARK: - Parsing

    private func parseConfig(at path: String) -> ParsedConfigResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            parsedConfigCache.removeValue(forKey: path)
            return ParsedConfigResult(config: nil, issue: nil)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes?[.modificationDate] as? Date

        if let cached = parsedConfigCache[path],
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate {
            return ParsedConfigResult(config: cached.config, issue: cached.issue)
        }

        guard let data = fileManager.contents(atPath: path),
              !data.isEmpty else {
            let issue = schemaIssue(path: path, message: "zmux.json is empty")
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                config: nil,
                issue: issue
            )
            return ParsedConfigResult(config: nil, issue: issue)
        }
        do {
            let config = try JSONDecoder().decode(ZmuxConfigFile.self, from: data)
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                config: config,
                issue: nil
            )
            return ParsedConfigResult(config: config, issue: nil)
        } catch {
            let issue = schemaIssue(path: path, message: schemaErrorMessage(error))
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                config: nil,
                issue: issue
            )
            NSLog("[ZmuxConfig] parse error at %@: %@", path, String(describing: error))
            return ParsedConfigResult(config: nil, issue: issue)
        }
    }

    private func schemaIssue(path: String, message: String) -> ZmuxConfigIssue {
        ZmuxConfigIssue(
            kind: .schemaError,
            settingName: (path as NSString).lastPathComponent,
            sourcePath: path,
            message: message
        )
    }

    private func schemaErrorMessage(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context):
            return schemaErrorMessage(context)
        case DecodingError.valueNotFound(_, let context):
            return schemaErrorMessage(context)
        case DecodingError.keyNotFound(let key, let context):
            let path = schemaCodingPath(context.codingPath + [key])
            let detail = sanitizeConfigText(context.debugDescription)
            return "\(path): \(detail)"
        case DecodingError.dataCorrupted(let context):
            return schemaErrorMessage(context)
        default:
            let message = sanitizeConfigText(error.localizedDescription)
            return message.isEmpty ? String(describing: error) : message
        }
    }

    private func schemaErrorMessage(_ context: DecodingError.Context) -> String {
        let path = schemaCodingPath(context.codingPath)
        let detail = sanitizeConfigText(context.debugDescription)
        return detail.isEmpty ? path : "\(path): \(detail)"
    }

    private func schemaCodingPath(_ codingPath: [CodingKey]) -> String {
        let path = codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        return path.isEmpty ? "root" : path
    }

    // MARK: - File watching (local)

    private func startLocalFileWatcher() {
        guard let path = localConfigPath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet — watch the directory instead
            startLocalDirectoryWatcher()
            return
        }
        localFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopLocalFileWatcher()
                    self.loadAll()
                    self.scheduleLocalReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.loadAll()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        localFileWatchSource = source
    }

    private func startLocalDirectoryWatcher() {
        guard let path = localConfigPath else { return }
        let configDirectory = (path as NSString).deletingLastPathComponent
        let fs = FileManager.default
        let dirPath: String
        if fs.fileExists(atPath: configDirectory) {
            dirPath = configDirectory
        } else if let searchDirectory = localConfigSearchDirectory,
                  fs.fileExists(atPath: searchDirectory) {
            dirPath = searchDirectory
        } else {
            dirPath = (configDirectory as NSString).deletingLastPathComponent
        }
        let eventHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.handleLocalDirectoryWatchEvent()
            }
        }

        guard let primaryWatch = startLocalDirectoryWatchSource(at: dirPath, eventHandler: eventHandler) else {
            return
        }
        localFileWatchSource = primaryWatch.source
        localFileDescriptor = primaryWatch.fileDescriptor

        if let searchDirectory = localConfigSearchDirectory,
           fs.fileExists(atPath: configDirectory),
           searchDirectory != dirPath,
           let fallbackWatch = startLocalDirectoryWatchSource(at: searchDirectory, eventHandler: eventHandler) {
            localFallbackDirectoryWatchSource = fallbackWatch.source
            localFallbackDirectoryDescriptor = fallbackWatch.fileDescriptor
        }
    }

    private func startLocalDirectoryWatchSource(
        at dirPath: String,
        eventHandler: @escaping () -> Void
    ) -> (source: DispatchSourceFileSystemObject, fileDescriptor: Int32)? {
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )
        source.setEventHandler(handler: eventHandler)
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        return (source, fd)
    }

    private func handleLocalDirectoryWatchEvent() {
        if let searchDirectory = localConfigSearchDirectory {
            let resolvedPath = resolvedLocalConfigPath(startingFrom: searchDirectory)
            if resolvedPath != localConfigPath {
                localConfigPath = resolvedPath
            }
        }
        guard let configPath = localConfigPath else { return }
        let configDirectory = (configPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: configPath) ||
            FileManager.default.fileExists(atPath: configDirectory) else { return }
        // File or its parent directory appeared — switch to file-level watching.
        stopLocalFileWatcher()
        loadAll()
        startLocalFileWatcher()
    }

    private func scheduleLocalReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let path = self.localConfigPath else { return }
                if FileManager.default.fileExists(atPath: path) {
                    self.loadAll()
                    self.startLocalFileWatcher()
                } else {
                    self.startLocalDirectoryWatcher()
                }
            }
        }
    }

    private func stopLocalFileWatcher() {
        if let source = localFileWatchSource {
            source.cancel()
            localFileWatchSource = nil
        }
        if let source = localFallbackDirectoryWatchSource {
            source.cancel()
            localFallbackDirectoryWatchSource = nil
        }
        localFileDescriptor = -1
        localFallbackDirectoryDescriptor = -1
    }

    // MARK: - File watching (global)

    private func startGlobalFileWatcher() {
        let fd = open(globalConfigPath, O_EVTONLY)
        guard fd >= 0 else {
            startGlobalDirectoryWatcher()
            return
        }
        globalFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopGlobalFileWatcher()
                    self.loadAll()
                    self.scheduleGlobalReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.loadAll()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        globalFileWatchSource = source
    }

    private func scheduleGlobalReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else {
            startGlobalDirectoryWatcher()
            return
        }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: self.globalConfigPath) {
                    self.loadAll()
                    self.startGlobalFileWatcher()
                } else {
                    self.scheduleGlobalReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func startGlobalDirectoryWatcher() {
        let dirPath = (globalConfigPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dirPath) {
            try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        globalFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: self.globalConfigPath) else { return }
                self.stopGlobalFileWatcher()
                self.loadAll()
                self.startGlobalFileWatcher()
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        globalFileWatchSource = source
    }

    private func stopGlobalFileWatcher() {
        if let source = globalFileWatchSource {
            source.cancel()
            globalFileWatchSource = nil
        }
        globalFileDescriptor = -1
    }
}

extension ZmuxConfigStore {
    static func resolveCwd(_ cwd: String?, relativeTo baseCwd: String) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "." else {
            return baseCwd
        }
        if cwd.hasPrefix("~/") || cwd == "~" {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if cwd == "~" { return home }
            return (home as NSString).appendingPathComponent(String(cwd.dropFirst(2)))
        }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseCwd as NSString).appendingPathComponent(cwd)
    }
}
