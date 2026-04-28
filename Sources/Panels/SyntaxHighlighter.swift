import AppKit

enum CodeLanguage: String, CaseIterable {
    case swift, typescript, javascript, python, rust, zig, json, yaml
    case markdown, shell, c, cpp, go, html, css, toml, sql, unknown

    static func detect(from fileExtension: String) -> CodeLanguage {
        switch fileExtension.lowercased() {
        case "swift": return .swift
        case "ts", "tsx": return .typescript
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "py": return .python
        case "rs": return .rust
        case "zig": return .zig
        case "json": return .json
        case "yml", "yaml": return .yaml
        case "md", "markdown": return .markdown
        case "sh", "bash", "zsh": return .shell
        case "c", "h": return .c
        case "cpp", "hpp", "cc", "cxx": return .cpp
        case "go": return .go
        case "html", "htm": return .html
        case "css": return .css
        case "toml": return .toml
        case "sql": return .sql
        default: return .unknown
        }
    }
}

enum TokenCategory {
    case keyword, string, comment, number, type, `operator`
}

struct SyntaxTheme {
    let colors: [TokenCategory: NSColor]

    static let dark = SyntaxTheme(colors: [
        .keyword: NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1),
        .string: NSColor(red: 0.40, green: 0.80, blue: 0.40, alpha: 1),
        .comment: NSColor(red: 0.55, green: 0.55, blue: 0.57, alpha: 1),
        .number: NSColor(red: 0.95, green: 0.65, blue: 0.25, alpha: 1),
        .type: NSColor(red: 0.40, green: 0.82, blue: 0.90, alpha: 1),
        .operator: NSColor.white,
    ])

    static let light = SyntaxTheme(colors: [
        .keyword: NSColor(red: 0.55, green: 0.15, blue: 0.70, alpha: 1),
        .string: NSColor(red: 0.15, green: 0.50, blue: 0.15, alpha: 1),
        .comment: NSColor(red: 0.45, green: 0.45, blue: 0.47, alpha: 1),
        .number: NSColor(red: 0.80, green: 0.45, blue: 0.10, alpha: 1),
        .type: NSColor(red: 0.15, green: 0.35, blue: 0.75, alpha: 1),
        .operator: NSColor.black,
    ])
}

enum SyntaxHighlighter {
    static func highlight(_ text: String, language: CodeLanguage, isDarkMode: Bool) -> NSAttributedString {
        let theme = isDarkMode ? SyntaxTheme.dark : SyntaxTheme.light
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let defaultColor: NSColor = isDarkMode ? .white : .black

        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: defaultColor,
        ])

        let fullRange = NSRange(location: 0, length: result.length)
        var masked = [Bool](repeating: false, count: text.utf16.count)

        func applyPattern(_ pattern: String, category: TokenCategory, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
                  let color = theme.colors[category] else { return }
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range else { return }
                let start = range.location
                let end = start + range.length
                if category != .comment && category != .string {
                    for i in start..<min(end, masked.count) where masked[i] { return }
                }
                for i in start..<min(end, masked.count) { masked[i] = true }
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }

        applyPattern(stringPattern(for: language), category: .string)
        applyPattern(commentPattern(for: language), category: .comment, options: [.dotMatchesLineSeparators])

        let keywords = keywords(for: language)
        if !keywords.isEmpty {
            let joined = keywords.joined(separator: "|")
            applyPattern("\\b(\(joined))\\b", category: .keyword)
        }

        applyPattern("\\b\\d+\\.?\\d*\\b", category: .number)

        if usesPascalCaseTypes(language) {
            applyPattern("\\b[A-Z][a-zA-Z0-9]+\\b", category: .type)
        }

        return result
    }

    private static func stringPattern(for language: CodeLanguage) -> String {
        switch language {
        case .javascript, .typescript:
            return #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)"#
        case .python:
            return #"("""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')"#
        default:
            return #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')"#
        }
    }

    private static func commentPattern(for language: CodeLanguage) -> String {
        switch language {
        case .python:
            return #"(#.*$)"#
        case .shell:
            return #"(#.*$)"#
        case .html:
            return #"(<!--[\s\S]*?-->)"#
        case .css:
            return #"(/\*[\s\S]*?\*/)"#
        case .sql:
            return #"(--.*$|/\*[\s\S]*?\*/)"#
        case .json, .yaml, .markdown:
            return #"($^)"#
        default:
            return #"(//.*$|/\*[\s\S]*?\*/)"#
        }
    }

    private static func usesPascalCaseTypes(_ language: CodeLanguage) -> Bool {
        switch language {
        case .swift, .typescript, .javascript, .rust, .go, .cpp, .c:
            return true
        default:
            return false
        }
    }

    private static func keywords(for language: CodeLanguage) -> [String] {
        switch language {
        case .swift:
            return ["func", "var", "let", "if", "else", "guard", "return", "import", "class", "struct",
                    "enum", "protocol", "extension", "switch", "case", "for", "while", "in", "self",
                    "true", "false", "nil", "throws", "async", "await", "try", "catch", "private",
                    "public", "static", "override", "weak", "some", "any"]
        case .typescript:
            return ["const", "let", "var", "function", "return", "if", "else", "for", "while", "class",
                    "interface", "type", "import", "export", "from", "async", "await", "try", "catch",
                    "new", "this", "true", "false", "null", "undefined", "switch", "case", "default",
                    "extends", "implements", "readonly", "enum", "as", "typeof", "keyof"]
        case .javascript:
            return ["const", "let", "var", "function", "return", "if", "else", "for", "while", "class",
                    "import", "export", "from", "async", "await", "try", "catch", "new", "this",
                    "true", "false", "null", "undefined", "switch", "case", "default", "extends", "of"]
        case .python:
            return ["def", "class", "if", "elif", "else", "return", "import", "from", "for", "while",
                    "in", "not", "and", "or", "is", "True", "False", "None", "with", "as", "try",
                    "except", "raise", "lambda", "yield", "async", "await", "pass", "self"]
        case .rust:
            return ["fn", "let", "mut", "if", "else", "match", "return", "use", "mod", "pub", "struct",
                    "enum", "impl", "trait", "for", "while", "loop", "in", "self", "Self", "true",
                    "false", "async", "await", "move", "ref", "where", "type", "const", "unsafe"]
        case .zig:
            return ["fn", "var", "const", "if", "else", "while", "for", "return", "pub", "struct",
                    "enum", "union", "switch", "break", "continue", "try", "catch", "comptime",
                    "unreachable", "undefined", "null", "true", "false", "test", "error"]
        case .go:
            return ["func", "var", "const", "if", "else", "for", "range", "return", "import", "package",
                    "type", "struct", "interface", "map", "chan", "go", "defer", "switch", "case",
                    "default", "select", "nil", "true", "false", "make", "append"]
        case .c:
            return ["if", "else", "for", "while", "return", "int", "char", "void", "float", "double",
                    "struct", "typedef", "enum", "switch", "case", "break", "continue", "sizeof",
                    "static", "const", "unsigned", "long", "short", "include", "define", "NULL"]
        case .cpp:
            return ["if", "else", "for", "while", "return", "int", "char", "void", "class", "struct",
                    "public", "private", "protected", "virtual", "override", "const", "auto", "new",
                    "delete", "template", "typename", "namespace", "using", "static", "true", "false",
                    "nullptr", "throw", "try", "catch", "switch", "case", "enum", "include"]
        case .html:
            return ["html", "head", "body", "div", "span", "script", "style", "link", "meta", "title",
                    "class", "id", "src", "href", "type"]
        case .css:
            return ["display", "position", "margin", "padding", "border", "color", "background", "font",
                    "width", "height", "flex", "grid", "none", "block", "inline", "absolute", "relative",
                    "fixed", "important"]
        case .shell:
            return ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
                    "function", "return", "exit", "echo", "export", "local", "source", "set", "unset",
                    "true", "false", "in", "read"]
        case .sql:
            return ["SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER",
                    "TABLE", "INTO", "VALUES", "SET", "JOIN", "LEFT", "RIGHT", "INNER", "ON", "AND",
                    "OR", "NOT", "NULL", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "AS", "DISTINCT",
                    "INDEX", "PRIMARY", "KEY", "FOREIGN", "REFERENCES"]
        case .toml:
            return ["true", "false"]
        case .json, .yaml, .markdown, .unknown:
            return []
        }
    }
}
