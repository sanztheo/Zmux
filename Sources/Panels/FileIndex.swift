import Foundation

struct IndexedFile: Sendable, Hashable {
    let path: String
    let name: String
    let lowerName: String
    let parentPath: String
}

struct SearchHit: Sendable, Hashable {
    let entry: IndexedFile
    let score: Int
}

actor FileIndex {
    private(set) var entries: [IndexedFile] = []
    private(set) var isReady: Bool = false

    let rootPath: String
    let includeHidden: Bool

    private static let alwaysSkip: Set<String> = [
        ".git",
        "node_modules",
        ".next",
        ".turbo",
        ".cache",
        ".swiftpm",
        ".build",
        "DerivedData",
        "build",
        "dist",
        ".venv",
        "venv",
        "target",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        ".gradle",
        ".idea",
        ".vscode",
    ]

    private static let maxEntries = 250_000
    private static let yieldInterval = 4_096

    init(rootPath: String, includeHidden: Bool) {
        self.rootPath = rootPath
        self.includeHidden = includeHidden
    }

    func rebuild() async {
        isReady = false
        var collected: [IndexedFile] = []
        collected.reserveCapacity(50_000)

        let fm = FileManager.default
        var stack: [String] = [rootPath]
        var counter = 0

        while let dir = stack.popLast() {
            if collected.count >= Self.maxEntries { break }
            if Task.isCancelled { return }

            let url = URL(fileURLWithPath: dir)
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
            guard let contents = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: includeHidden ? [] : [.skipsHiddenFiles]
            ) else { continue }

            for itemURL in contents {
                let name = itemURL.lastPathComponent
                if Self.alwaysSkip.contains(name) { continue }

                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

                if isDir {
                    stack.append(itemURL.path)
                    continue
                }

                collected.append(
                    IndexedFile(
                        path: itemURL.path,
                        name: name,
                        lowerName: name.lowercased(),
                        parentPath: dir
                    )
                )

                counter += 1
                if counter % Self.yieldInterval == 0 {
                    await Task.yield()
                    if Task.isCancelled { return }
                }
            }
        }

        entries = collected
        isReady = true
    }

    func search(query: String, limit: Int) -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let lowerQuery = trimmed.lowercased()

        // Regex shortcut: /pattern/
        if trimmed.count >= 2, trimmed.hasPrefix("/"), trimmed.hasSuffix("/") {
            let pattern = String(trimmed.dropFirst().dropLast())
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return []
            }
            return regexMatches(regex: regex, limit: limit, scoreBase: 100)
        }

        // Glob shortcut: contains * or ?
        if lowerQuery.contains("*") || lowerQuery.contains("?") {
            let escaped = NSRegularExpression.escapedPattern(for: lowerQuery)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            guard let regex = try? NSRegularExpression(pattern: "^" + escaped + "$", options: [.caseInsensitive]) else {
                return []
            }
            return regexMatches(regex: regex, limit: limit, scoreBase: 200)
        }

        // Extension shortcut: .swift, .ts, ...
        if lowerQuery.hasPrefix("."), lowerQuery.count >= 2 {
            return extensionMatches(suffix: lowerQuery, limit: limit)
        }

        return fuzzyMatches(query: trimmed, lowerQuery: lowerQuery, limit: limit)
    }

    // MARK: - Match strategies

    private func regexMatches(regex: NSRegularExpression, limit: Int, scoreBase: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        hits.reserveCapacity(limit * 2)
        for entry in entries {
            let range = NSRange(entry.name.startIndex..., in: entry.name)
            if regex.firstMatch(in: entry.name, range: range) != nil {
                hits.append(SearchHit(entry: entry, score: scoreBase))
            }
        }
        return rankAndCap(hits, limit: limit)
    }

    private func extensionMatches(suffix: String, limit: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        hits.reserveCapacity(limit * 2)
        for entry in entries where entry.lowerName.hasSuffix(suffix) {
            hits.append(SearchHit(entry: entry, score: 500))
        }
        return rankAndCap(hits, limit: limit)
    }

    private func fuzzyMatches(query: String, lowerQuery: String, limit: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        hits.reserveCapacity(limit * 4)

        for entry in entries {
            guard let score = score(name: entry.name, lowerName: entry.lowerName, query: query, lowerQuery: lowerQuery) else {
                continue
            }
            hits.append(SearchHit(entry: entry, score: score))
        }
        return rankAndCap(hits, limit: limit)
    }

    private func rankAndCap(_ hits: [SearchHit], limit: Int) -> [SearchHit] {
        var sorted = hits
        sorted.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.name.count != rhs.entry.name.count {
                return lhs.entry.name.count < rhs.entry.name.count
            }
            return lhs.entry.path < rhs.entry.path
        }
        return Array(sorted.prefix(limit))
    }

    // MARK: - Scoring

    private func score(name: String, lowerName: String, query: String, lowerQuery: String) -> Int? {
        if lowerName == lowerQuery { return 10_000 }
        if lowerName.hasPrefix(lowerQuery) { return 5_000 }

        if let r = lowerName.range(of: lowerQuery) {
            let pos = lowerName.distance(from: lowerName.startIndex, to: r.lowerBound)
            var bonus = 0
            if pos > 0 {
                let prevIdx = lowerName.index(r.lowerBound, offsetBy: -1)
                let prev = lowerName[prevIdx]
                if prev == "_" || prev == "-" || prev == "." || prev == "/" || prev == " " {
                    bonus = 200
                }
            } else {
                bonus = 200
            }
            return 1_000 - min(pos, 500) + bonus
        }

        if let humps = camelHumpsScore(name: name, query: query) {
            return humps
        }
        return nil
    }

    private func camelHumpsScore(name: String, query: String) -> Int? {
        guard query.count >= 2, query.count <= 8,
              query.allSatisfy({ $0.isLetter })
        else { return nil }
        let nameChars = Array(name)
        let queryChars = Array(query)
        var qi = 0
        var lastWasBoundary = true
        for ch in nameChars {
            guard qi < queryChars.count else { break }
            let isBoundary = ch == "_" || ch == "-" || ch == "." || ch == "/"
            if isBoundary {
                lastWasBoundary = true
                continue
            }
            let isUpper = ch.isUppercase
            if (isUpper || lastWasBoundary) &&
                ch.lowercased() == queryChars[qi].lowercased() {
                qi += 1
            }
            lastWasBoundary = false
        }
        return qi == queryChars.count ? 300 : nil
    }
}
