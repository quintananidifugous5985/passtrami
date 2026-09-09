import Foundation

struct CLIInstaller {
    enum InstallError: LocalizedError {
        case missingExecutable, conflictingCommand, invalidShellFile(String), malformedBlock(String)
        var errorDescription: String? {
            switch self {
            case .missingExecutable: "The bundled aster command is missing."
            case .conflictingCommand: "Another command already exists at ~/.local/bin/aster. Move it before changing the CLI installation."
            case .invalidShellFile(let name): "Could not read \(name) as a text file."
            case .malformedBlock(let name): "The CLI PATH block in \(name) is incomplete. Correct it before installing."
            }
        }
    }

    private let manager = FileManager.default
    private let startMarker = "# >>> Aster CLI >>>"
    private let endMarker = "# <<< Aster CLI <<<"
    private let executableURL: URL
    private let homeURL: URL
    private var commandURL: URL { homeURL.appendingPathComponent(".local/bin/aster") }
    private var shellFiles: [URL] {
        [".zprofile", ".zshrc"].map { homeURL.appendingPathComponent($0) }
    }

    init(
        executableURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/aster"),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.executableURL = executableURL
        self.homeURL = homeURL
    }
    private var pathBlock: String {
        """
        # >>> Aster CLI >>>
        case ":$PATH:" in
          *":$HOME/.local/bin:"*) ;;
          *) export PATH="$HOME/.local/bin:$PATH" ;;
        esac
        # <<< Aster CLI <<<
        """
    }

    var isInstalled: Bool {
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: commandURL.path),
              resolvedLink(destination) == executableURL.resolvingSymlinksInPath() else { return false }
        return true
    }

    func uninstall() throws {
        try checkExistingCommand()
        guard (try? manager.destinationOfSymbolicLink(atPath: commandURL.path)) != nil else { return }
        // Remove the shortcut, not its target or the shared ~/.local/bin PATH entry.
        try manager.removeItem(at: commandURL)
    }

    func install() throws {
        guard manager.isExecutableFile(atPath: executableURL.path) else { throw InstallError.missingExecutable }
        try checkExistingCommand()
        // Read and validate both shell files before changing either file.
        let updates = try shellFiles.map { originalURL -> (URL, String, NSNumber?) in
            let url = originalURL.resolvingSymlinksInPath()
            let exists = manager.fileExists(atPath: url.path)
            let text: String
            var permissions: NSNumber?
            if exists {
                let attributes = try manager.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let contents = try? String(contentsOf: url, encoding: .utf8) else {
                    throw InstallError.invalidShellFile(originalURL.lastPathComponent)
                }
                text = contents
                permissions = attributes[.posixPermissions] as? NSNumber
            } else { text = "" }
            return (url, try updatedShellText(text, name: originalURL.lastPathComponent), permissions)
        }
        try manager.createDirectory(at: commandURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (url, text, permissions) in updates {
            try text.write(to: url, atomically: true, encoding: .utf8)
            if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        }
        if (try? manager.destinationOfSymbolicLink(atPath: commandURL.path)) != nil {
            try manager.removeItem(at: commandURL)
        }
        try manager.createSymbolicLink(at: commandURL, withDestinationURL: executableURL)
    }

    private func checkExistingCommand() throws {
        if let destination = try? manager.destinationOfSymbolicLink(atPath: commandURL.path) {
            let resolved = resolvedLink(destination)
            if resolved == executableURL.resolvingSymlinksInPath() { return }
            // An existing link to this app can be updated after the app moves.
            let bundleURL = resolved.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard resolved.lastPathComponent == "aster",
                  let identifier = Bundle.main.bundleIdentifier,
                  Bundle(url: bundleURL)?.bundleIdentifier == identifier else {
                throw InstallError.conflictingCommand
            }
            return
        }
        if manager.fileExists(atPath: commandURL.path) { throw InstallError.conflictingCommand }
    }

    private func resolvedLink(_ destination: String) -> URL {
        URL(fileURLWithPath: destination, relativeTo: commandURL.deletingLastPathComponent())
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    private func updatedShellText(_ text: String, name: String) throws -> String {
        let starts = text.components(separatedBy: startMarker).count - 1
        let ends = text.components(separatedBy: endMarker).count - 1
        if starts == 0 && ends == 0 {
            let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
            return text + separator + pathBlock + "\n"
        }
        guard starts == 1, ends == 1,
              let start = text.range(of: startMarker), let end = text.range(of: endMarker),
              start.lowerBound < end.lowerBound else { throw InstallError.malformedBlock(name) }
        return text.replacingCharacters(in: start.lowerBound..<end.upperBound, with: pathBlock)
    }
}
