import Foundation
import CodeEditLanguages

enum FileLanguage: String, CaseIterable {
    case swift, typescript, javascript, python, rust, zig, json, yaml
    case markdown, shell, c, cpp, go, html, css, toml, sql, unknown

    static func detect(from fileExtension: String) -> FileLanguage {
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

    var codeLanguage: CodeEditLanguages.CodeLanguage {
        switch self {
        case .swift:      return .swift
        case .typescript: return .typescript
        case .javascript: return .javascript
        case .python:     return .python
        case .rust:       return .rust
        case .zig:        return .zig
        case .go:         return .go
        case .c:          return .c
        case .cpp:        return .cpp
        case .json:       return .json
        case .yaml:       return .yaml
        case .toml:       return .toml
        case .css:        return .css
        case .markdown:   return .markdown
        case .shell:      return .bash
        case .html:       return .html
        case .sql:        return .sql
        case .unknown:    return .default
        }
    }
}
