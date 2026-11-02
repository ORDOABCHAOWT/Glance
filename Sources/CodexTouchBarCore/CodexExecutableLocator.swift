import Foundation

public enum CodexExecutableLocator {
    public static func find() -> URL? {
        find(applicationDirectories: ["/Applications", NSHomeDirectory() + "/Applications"])
    }

    public static func find(
        applicationDirectories: [String],
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        let relativePaths = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex",
        ]
        let candidates = applicationDirectories.flatMap { directory in
            ["ChatGPT.app", "Codex.app"].flatMap { app in
                relativePaths.map { directory + "/" + app + "/" + $0 }
            }
        } + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.first(where: isExecutable).map(URL.init(fileURLWithPath:))
    }
}
