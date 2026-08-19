import Foundation

/// Collision-safe identity for one hook-backed parent or child session.
///
/// The wire format is versioned and length-prefixed in UTF-8 bytes so vendor
/// identifiers may contain the same separators used by the envelope.
public struct HookRecordID: Equatable, Sendable {
    public let agent: AgentID
    public let parentID: String
    public let childID: String?

    public init?(agent: AgentID, parentID: String, childID: String? = nil) {
        guard !parentID.isEmpty else { return nil }
        self.agent = agent
        self.parentID = parentID
        self.childID = childID.flatMap { $0.isEmpty ? nil : $0 }
    }

    public init?(encoded: String) {
        let bytes = Array(encoded.utf8)
        let prefix = Array("v1|".utf8)
        guard bytes.starts(with: prefix) else { return nil }

        var index = prefix.count
        guard let agentValue = Self.readField(from: bytes, index: &index),
              Self.consumeSeparator(in: bytes, index: &index),
              let agent = AgentID(rawValue: agentValue),
              let parentID = Self.readField(from: bytes, index: &index),
              !parentID.isEmpty,
              Self.consumeSeparator(in: bytes, index: &index),
              let childValue = Self.readField(from: bytes, index: &index),
              index == bytes.count
        else { return nil }

        self.agent = agent
        self.parentID = parentID
        self.childID = childValue.isEmpty ? nil : childValue
    }

    public var encoded: String {
        "v1|\(Self.field(agent.rawValue))|\(Self.field(parentID))|\(Self.field(childID ?? ""))"
    }

    private static func field(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private static func consumeSeparator(in bytes: [UInt8], index: inout Int) -> Bool {
        guard index < bytes.count, bytes[index] == 0x7c else { return false }
        index += 1
        return true
    }

    private static func readField(from bytes: [UInt8], index: inout Int) -> String? {
        let lengthStart = index
        var length = 0

        while index < bytes.count, bytes[index] != 0x3a {
            let byte = bytes[index]
            guard byte >= 0x30, byte <= 0x39 else {
                return nil
            }
            let digit = Int(byte - 0x30)
            let (multiplied, multiplicationOverflow) = length.multipliedReportingOverflow(by: 10)
            let (next, additionOverflow) = multiplied.addingReportingOverflow(digit)
            guard !multiplicationOverflow, !additionOverflow else { return nil }
            length = next
            index += 1
        }

        guard index > lengthStart,
              index < bytes.count,
              bytes[index] == 0x3a,
              index - lengthStart == 1 || bytes[lengthStart] != 0x30
        else { return nil }

        index += 1
        let (end, overflow) = index.addingReportingOverflow(length)
        guard !overflow, end <= bytes.count,
              let value = String(bytes: bytes[index..<end], encoding: .utf8)
        else { return nil }
        index = end
        return value
    }
}
