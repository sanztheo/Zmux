import AppKit
import Foundation
import SwiftUI

/// Resolves Material Icon Theme (VSCode) icons for files and folders.
/// Loads `material-icons.json` once and serves SVGs from `MaterialIcons/` bundle folder.
final class MaterialIconResolver {
    static let shared = MaterialIconResolver()

    private struct Manifest: Decodable {
        let fileNames: [String: String]?
        let fileExtensions: [String: String]?
        let languageIds: [String: String]?
        let folderNames: [String: String]?
        let folderNamesExpanded: [String: String]?
        let file: String?
        let folder: String?
        let folderExpanded: String?
    }

    // Material Icon Theme exposes some languages only via `languageIds` (e.g.
    // TypeScript, JavaScript). VSCode resolves these through its language
    // registration, which we don't have. This static table bridges common file
    // extensions to language IDs so `.ts`, `.js`, etc. resolve correctly.
    private static let extensionToLanguageId: [String: String] = [
        "ts": "typescript",
        "mts": "typescript",
        "cts": "typescript",
        "js": "javascript",
        "cjs": "javascript",
        "ets": "typescript",
        "vue": "vue",
        "svelte": "svelte",
        "astro": "astro",
        "html": "html",
        "css": "css",
        "scss": "scss",
        "less": "less",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "xml": "xml",
        "sh": "shellscript",
        "bash": "shellscript",
        "zsh": "shellscript",
        "fish": "shellscript",
        "zig": "zig",
        "kt": "kotlin",
        "kts": "kotlin",
        "scala": "scala",
        "clj": "clojure",
        "cljs": "clojure",
        "ex": "elixir",
        "exs": "elixir",
        "erl": "erlang",
        "hs": "haskell",
        "ml": "ocaml",
        "fs": "fsharp",
        "lua": "lua",
        "r": "r",
        "dart": "dart",
        "groovy": "groovy",
        "ps1": "powershell",
    ]

    private let fileNames: [String: String]
    private let fileExtensions: [String: String]
    private let languageIds: [String: String]
    private let folderNames: [String: String]
    private let folderNamesExpanded: [String: String]
    private let defaultFile: String
    private let defaultFolder: String
    private let defaultFolderExpanded: String

    private let imageCache = NSCache<NSString, NSImage>()
    private let iconsSubdir = "MaterialIcons"

    private init() {
        guard
            let url = Bundle.main.url(forResource: "material-icons", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            self.fileNames = [:]
            self.fileExtensions = [:]
            self.languageIds = [:]
            self.folderNames = [:]
            self.folderNamesExpanded = [:]
            self.defaultFile = "file"
            self.defaultFolder = "folder"
            self.defaultFolderExpanded = "folder-open"
            return
        }

        self.fileNames = Self.lowercased(manifest.fileNames)
        self.fileExtensions = Self.lowercased(manifest.fileExtensions)
        self.languageIds = Self.lowercased(manifest.languageIds)
        self.folderNames = Self.lowercased(manifest.folderNames)
        self.folderNamesExpanded = Self.lowercased(manifest.folderNamesExpanded)
        self.defaultFile = manifest.file ?? "file"
        self.defaultFolder = manifest.folder ?? "folder"
        self.defaultFolderExpanded = manifest.folderExpanded ?? "folder-open"
    }

    private static func lowercased(_ dict: [String: String]?) -> [String: String] {
        guard let dict else { return [:] }
        var out = [String: String](minimumCapacity: dict.count)
        for (k, v) in dict { out[k.lowercased()] = v }
        return out
    }

    func iconID(forFile name: String) -> String {
        let lower = name.lowercased()
        if let id = fileNames[lower] { return id }

        // Walk the suffix list once: ["spec.test.ts", "test.ts", "ts"] for "foo.spec.test.ts".
        // Try longest match first to favour specific compound extensions like "d.ts" over "ts".
        // The previous loop never reduced its working string and infinite-looped on any name
        // with two or more extensions.
        let dotComponents = lower.split(separator: ".", omittingEmptySubsequences: false)
        if dotComponents.count > 1 {
            for start in 1..<dotComponents.count {
                let candidate = dotComponents[start...].joined(separator: ".")
                if candidate.isEmpty { continue }
                if let id = fileExtensions[candidate] { return id }
            }
        }

        // Fallback: bridge through languageIds for extensions that VSCode
        // resolves via language registration (e.g. `.ts` → typescript).
        let primaryExt = (lower as NSString).pathExtension
        if !primaryExt.isEmpty,
           let langId = Self.extensionToLanguageId[primaryExt],
           let id = languageIds[langId] {
            return id
        }
        return defaultFile
    }

    func iconID(forFolder name: String, expanded: Bool) -> String {
        let lower = name.lowercased()
        if expanded, let id = folderNamesExpanded[lower] { return id }
        if let id = folderNames[lower] {
            return expanded ? "\(id)-open" : id
        }
        return expanded ? defaultFolderExpanded : defaultFolder
    }

    func image(for id: String) -> NSImage? {
        let key = id as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let url = Bundle.main.url(
            forResource: id,
            withExtension: "svg",
            subdirectory: iconsSubdir
        ) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        imageCache.setObject(image, forKey: key)
        return image
    }
}

/// SwiftUI view that renders a Material Icon by id, falling back to an SF Symbol.
struct MaterialIconView: View {
    let iconID: String
    let fallbackSystemName: String
    var size: CGFloat = 16

    var body: some View {
        if let nsImage = MaterialIconResolver.shared.image(for: iconID) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSystemName)
                .font(.system(size: size * 0.85))
                .frame(width: size, height: size)
        }
    }
}
