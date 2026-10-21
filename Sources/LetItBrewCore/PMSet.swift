import Foundation

public enum PMSet {
    /// Pure parse of `pmset -g` output, separated from the shell-out so it can
    /// be tested directly.
    ///
    /// `pmset -g` prints a `SleepDisabled` line only when the flag is on, so
    /// its absence means sleep is enabled, which is the default. Nil means
    /// there was no output at all to read, or the output couldn't be trusted:
    /// a value other than `0`/`1`, or two `SleepDisabled` lines that disagree.
    public static func parseSleepDisabled(from output: String?) -> Bool? {
        guard let output else { return nil }
        var found: Bool?
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            let value: Bool
            switch fields[1] {
            case "0": value = false
            case "1": value = true
            default: return nil
            }
            if let found, found != value { return nil }
            found = value
        }
        return found ?? false
    }
}

/// The two power sources whose settings pmset keeps separately.
public enum PowerModeSource: String, Codable, CaseIterable, Sendable {
    case battery
    case charger

    /// An XPC-safe bitmask: 1 battery, 2 charger.
    public static func mask(_ sources: Set<PowerModeSource>) -> Int {
        sources.reduce(0) { $0 | $1.maskBit }
    }

    public static func sources(fromMask mask: Int) -> Set<PowerModeSource> {
        guard mask >= 0 else { return [] }
        return Set(allCases.filter { mask & $0.maskBit != 0 })
    }

    private var maskBit: Int {
        switch self {
        case .battery: 1
        case .charger: 2
        }
    }

    /// The pmset flag that scopes a write to this source.
    public var pmsetFlag: String {
        switch self {
        case .battery: "-b"
        case .charger: "-c"
        }
    }
}

/// One source's energy mode exactly as pmset reports it. Newer macOS names the
/// setting `powermode` (0 automatic, 1 low power, 2 high power); older releases
/// name it `lowpowermode`. In both, 1 is Low Power Mode.
public struct PowerModeValue: Codable, Equatable, Sendable {
    public static let lowPower = 1

    public let key: String
    public let value: Int

    public init(key: String, value: Int) {
        self.key = key
        self.value = value
    }
}

/// The energy mode of each source this Mac has. A source pmset does not list
/// is nil: a desktop Mac has no battery section.
public struct PowerModeSnapshot: Codable, Equatable, Sendable {
    public var battery: PowerModeValue?
    public var charger: PowerModeValue?

    public init(battery: PowerModeValue? = nil, charger: PowerModeValue? = nil) {
        self.battery = battery
        self.charger = charger
    }

    public subscript(source: PowerModeSource) -> PowerModeValue? {
        get {
            switch source {
            case .battery: battery
            case .charger: charger
            }
        }
        set {
            switch source {
            case .battery: battery = newValue
            case .charger: charger = newValue
            }
        }
    }

    /// The sources this Mac lets Let It Brew switch.
    public var sources: [PowerModeSource] {
        PowerModeSource.allCases.filter { self[$0] != nil }
    }

    public var isLowPowerEverywhere: Bool {
        !sources.isEmpty && sources.allSatisfy { self[$0]?.value == PowerModeValue.lowPower }
    }
}

extension PMSet {
    public static let powerModeKeys: Set<String> = ["powermode", "lowpowermode"]

    /// Pure parse of `pmset -g custom`. Nil means the output could not be
    /// trusted: a non-integer or negative value, conflicting duplicate lines,
    /// or both names in one source. An empty snapshot means this Mac reports
    /// no energy mode at all.
    public static func parsePowerModes(from output: String?) -> PowerModeSnapshot? {
        guard let output, !output.isEmpty else { return nil }
        var snapshot = PowerModeSnapshot()
        var section: PowerModeSource?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":"), !line.hasPrefix(" ") {
                section = switch trimmed {
                case "Battery Power:": .battery
                case "AC Power:": .charger
                default: nil
                }
                continue
            }
            guard let section else { continue }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, powerModeKeys.contains(String(fields[0])) else { continue }
            guard let value = Int(fields[1]), value >= 0 else { return nil }
            let reading = PowerModeValue(key: String(fields[0]), value: value)
            if let existing = snapshot[section], existing != reading { return nil }
            snapshot[section] = reading
        }
        return snapshot
    }
}
