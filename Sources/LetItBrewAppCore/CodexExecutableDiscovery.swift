import Foundation

/// Deterministic Codex discovery for GUI apps, whose environment commonly
/// omits user shell setup. This inspects known install locations and PATH but
/// never executes a login shell or sources arbitrary profile code.
public enum CodexExecutableDiscovery {
    public static func candidateURLs(
        home: URL,
        environment: [String: String],
        applicationURLs: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        let applications = applicationURLs + [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/Codex.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
        ]
        var candidates = applications.flatMap(appExecutables)
        candidates.append(contentsOf: [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".volta/bin/codex"),
            home.appendingPathComponent(".bun/bin/codex"),
            home.appendingPathComponent("Library/pnpm/codex"),
            home.appendingPathComponent(".local/share/pnpm/codex"),
            home.appendingPathComponent(".asdf/shims/codex"),
            home.appendingPathComponent(".local/share/mise/shims/codex"),
        ])

        let versionedRoots: [(String, String)] = [
            (".nvm/versions/node", "bin/codex"),
            (".asdf/installs/nodejs", "bin/codex"),
            (".local/share/mise/installs/node", "bin/codex"),
            (".local/share/fnm/node-versions", "installation/bin/codex"),
            ("Library/Application Support/fnm/node-versions", "installation/bin/codex"),
        ]
        for (rootPath, suffix) in versionedRoots {
            let root = home.appendingPathComponent(rootPath, isDirectory: true)
            let versions = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            candidates.append(contentsOf: versions.sorted {
                $0.lastPathComponent > $1.lastPathComponent
            }.map { $0.appendingPathComponent(suffix) })
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ])
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("codex")
            })
        }

        var seen: Set<String> = []
        return candidates.filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    public static func locate(
        home: URL,
        environment: [String: String],
        applicationURLs: [URL],
        fileManager: FileManager = .default,
        isExecutable: ((String) -> Bool)? = nil
    ) -> URL? {
        let executableCheck = isExecutable ?? fileManager.isExecutableFile(atPath:)
        return candidateURLs(
            home: home,
            environment: environment,
            applicationURLs: applicationURLs,
            fileManager: fileManager
        ).first { executableCheck($0.path) }
    }

    private static func appExecutables(_ applicationURL: URL) -> [URL] {
        // Preserve legacy discovery, then prefer the package entry point
        // declared in codex-package.json over the internal native executable.
        [
            "Contents/Resources/codex",
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ].map { applicationURL.appendingPathComponent($0) }
    }
}
