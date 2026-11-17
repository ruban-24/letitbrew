import Foundation

/// Where the `letitbrew` command-line tool can live. `root` is `/` on a real
/// Mac; tests point it at a temporary directory.
public struct CommandLineToolLocations: Equatable, Sendable {
    /// The CLI inside this app bundle, `…/Contents/Helpers/letitbrew`.
    public let bundledCLI: String
    /// The link Settings installs and removes.
    public let link: String
    /// Homebrew on Intel shares `/usr/local`; its Caskroom tells its link
    /// apart from ours, since both point at the app bundle.
    let intelCaskroom: String
    /// Homebrew on Apple Silicon links `$(brew --prefix)/bin/letitbrew`.
    let appleSiliconHomebrewLink: String

    public init(bundledCLI: String, root: String = "/") {
        let root = root as NSString
        self.bundledCLI = bundledCLI
        link = root.appendingPathComponent("usr/local/bin/letitbrew")
        intelCaskroom = root.appendingPathComponent("usr/local/Caskroom/letitbrew")
        appleSiliconHomebrewLink = root.appendingPathComponent("opt/homebrew/bin/letitbrew")
    }
}

public enum CommandLineToolState: Equatable, Sendable {
    case notInstalled
    /// Our link in `/usr/local/bin`; the only state that may be removed.
    case installed
    case installedByHomebrew
    /// Another app's file or link is at `/usr/local/bin/letitbrew`.
    case blocked
}

/// Detects who owns `letitbrew` on the PATH and builds the commands that
/// install or remove our link. The commands run as root behind the
/// administrator prompt, so each re-checks the disk before it changes it.
public enum CommandLineTool {
    public static func state(at locations: CommandLineToolLocations) -> CommandLineToolState {
        switch occupant(of: locations.link, locations: locations) {
        case .letItBrew:
            return exists(locations.intelCaskroom) ? .installedByHomebrew : .installed
        case .caskroom:
            return .installedByHomebrew
        case .nothing, .other:
            switch occupant(of: locations.appleSiliconHomebrewLink, locations: locations) {
            case .letItBrew, .caskroom:
                return .installedByHomebrew
            case .nothing, .other:
                break
            }
            return exists(locations.link) ? .blocked : .notInstalled
        }
    }

    /// Links `/usr/local/bin/letitbrew` to the bundled CLI, creating
    /// `/usr/local/bin` if needed. Never replaces anything. `nil` unless
    /// nothing is installed.
    public static func installCommand(at locations: CommandLineToolLocations) -> String? {
        guard state(at: locations) == .notInstalled else { return nil }
        let link = shellQuoted(locations.link)
        let directory = shellQuoted((locations.link as NSString).deletingLastPathComponent)
        return "[ ! -e \(link) ] && [ ! -L \(link) ] && /bin/mkdir -p \(directory) && /bin/ln -s \(shellQuoted(locations.bundledCLI)) \(link)"
    }

    /// Deletes our link, and only while it still points where it did when
    /// checked. `nil` unless our link is installed.
    public static func removeCommand(at locations: CommandLineToolLocations) -> String? {
        guard state(at: locations) == .installed,
              case .letItBrew(let destination) = occupant(of: locations.link, locations: locations)
        else { return nil }
        let link = shellQuoted(locations.link)
        return "[ -L \(link) ] && [ \"$(/usr/bin/readlink \(link))\" = \(shellQuoted(destination)) ] && /bin/rm \(link)"
    }

    /// AppleScript that shows the standard macOS administrator prompt, then
    /// runs `command` as root.
    public static func administratorAppleScript(running command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    private enum Occupant: Equatable {
        case nothing
        case letItBrew(destination: String)
        case caskroom
        case other
    }

    private static func occupant(of path: String, locations: CommandLineToolLocations) -> Occupant {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return exists(path) ? .other : .nothing
        }
        let absolute = destination.hasPrefix("/")
            ? destination
            : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        let target = (absolute as NSString).standardizingPath
        if target.contains("/Caskroom/letitbrew/") { return .caskroom }
        if target == (locations.bundledCLI as NSString).standardizingPath
            || target.hasSuffix("/Let It Brew.app/Contents/Helpers/letitbrew") {
            return .letItBrew(destination: destination)
        }
        return .other
    }

    /// True for anything at `path`, including a dangling link.
    private static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// How an `osascript` run of the administrator prompt ended.
public enum CommandLineToolAuthorization: Equatable, Sendable {
    case succeeded
    /// The person chose Cancel; nothing was changed.
    case cancelled
    case failed(String)

    public static func outcome(status: Int32, output: String) -> CommandLineToolAuthorization {
        if status == 0 { return .succeeded }
        if output.contains("(-128)") { return .cancelled }
        var message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "execution error: ") {
            message = String(message[range.upperBound...])
        }
        return .failed(message.isEmpty ? "The command-line tool couldn't be changed." : message)
    }
}

/// Settings → General → Command-line tool wording for each state.
public struct CommandLineToolPresentation: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case install
        case remove

        public var title: String {
            switch self {
            case .install: "Install…"
            case .remove: "Remove…"
            }
        }
    }

    public let detail: String
    public let showsInstalledDot: Bool
    public let action: Action?
    public let footer: String?

    public init(state: CommandLineToolState) {
        switch state {
        case .notInstalled:
            detail = "Not installed"
            showsInstalledDot = false
            action = .install
            footer = "Lets you run `letitbrew hold` in any terminal. Adds a link in /usr/local/bin and asks for your password."
        case .installed:
            detail = "Installed in /usr/local/bin"
            showsInstalledDot = true
            action = .remove
            footer = nil
        case .installedByHomebrew:
            detail = "Installed by Homebrew"
            showsInstalledDot = true
            action = nil
            footer = nil
        case .blocked:
            detail = "/usr/local/bin/letitbrew belongs to another app. Let It Brew won't replace it."
            showsInstalledDot = false
            action = nil
            footer = nil
        }
    }
}
