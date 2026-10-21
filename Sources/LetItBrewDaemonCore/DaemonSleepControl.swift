import Foundation
import LetItBrewCore

public protocol DaemonSleepSettingControlling: AnyObject {
    func readDisabled() -> Bool?
    func writeDisabled(_ disabled: Bool) -> Bool
}

public protocol DaemonPowerModeControlling: AnyObject {
    /// Nil when the setting could not be read or trusted.
    func readPowerModes() -> PowerModeSnapshot?
    func writePowerMode(_ value: PowerModeValue, for source: PowerModeSource) -> Bool
}

/// The privileged daemon's only system mutations: `disablesleep`, and the
/// per-source energy mode it switches to Low Power for closed-lid work.
public final class PMSetDaemonSleepControl: DaemonSleepSettingControlling,
    DaemonPowerModeControlling {
    public init() {}

    public func readDisabled() -> Bool? {
        PMSet.parseSleepDisabled(from: run(["-g"]))
    }

    public func writeDisabled(_ disabled: Bool) -> Bool {
        run(["-a", "disablesleep", disabled ? "1" : "0"]) != nil
    }

    public func readPowerModes() -> PowerModeSnapshot? {
        PMSet.parsePowerModes(from: run(["-g", "custom"]))
    }

    public func writePowerMode(_ value: PowerModeValue, for source: PowerModeSource) -> Bool {
        // Only the two energy-mode names parsePowerModes reads may be written.
        guard PMSet.powerModeKeys.contains(value.key), value.value >= 0 else { return false }
        return run([source.pmsetFlag, value.key, String(value.value)]) != nil
    }

    private func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            // A successful pmset write is normally silent, so success must
            // not be inferred from output being nonempty.
            if arguments.first != "-g" { return "ok" }
            let text = String(decoding: data, as: UTF8.self)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
