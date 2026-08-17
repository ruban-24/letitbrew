import Foundation
import Testing
@testable import LetItBrewCore
@Test func preparationRejectsUnsupportedVersion() throws { let snapshot = try ExactFileSnapshot(path: "/tmp/missing", exists: false); #expect(throws: ExactTargetPreparationError.self) { _ = try ExactTargetPreparation(agent: .claude, snapshot: snapshot, expectedState: .absent, version: 2) } }
@Test func preparationRoundTrips() throws { let snapshot = try ExactFileSnapshot(path: "/tmp/missing", exists: false); let value = try ExactTargetPreparation(agent: .cursor, snapshot: snapshot, expectedState: .absent); #expect(try JSONDecoder().decode(ExactTargetPreparation.self, from: JSONEncoder().encode(value)) == value) }
@Test func preparationRejectsUnknownWireField() throws {
    let snapshot = try ExactFileSnapshot(path: "/tmp/missing", exists: false)
    let value = try ExactTargetPreparation(agent: .cursor, snapshot: snapshot, expectedState: .absent)
    var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    root["extra"] = true
    #expect(throws: ExactTargetPreparationError.self) { _ = try JSONDecoder().decode(ExactTargetPreparation.self, from: JSONSerialization.data(withJSONObject: root)) }
}
