import Testing
@testable import LetItBrewCore

@Test func readsSleepDisabledWhenPresent() {
    let output = """
    System-wide power settings:
    Currently in use:
     standby              1
     SleepDisabled        1
     hibernatemode        3
    """
    #expect(PMSet.parseSleepDisabled(from: output) == true)
}

@Test func absentKeyMeansSleepIsEnabled() {
    // pmset prints SleepDisabled only when the flag is on; absence is the
    // default state, not an unknown one.
    let output = """
    System-wide power settings:
    Currently in use:
     standby              1
     hibernatemode        3
    """
    #expect(PMSet.parseSleepDisabled(from: output) == false)
}

@Test func explicitZeroMeansEnabled() {
    #expect(PMSet.parseSleepDisabled(from: " SleepDisabled        0") == false)
}

@Test func noOutputAtAllIsUnknown() {
    #expect(PMSet.parseSleepDisabled(from: nil) == nil)
}

@Test func doesNotMatchASimilarlyNamedKey() {
    #expect(PMSet.parseSleepDisabled(from: " SleepDisabledExtra   1") == false)
}

@Test func invalidValueIsUnknownRatherThanEnabled() {
    // Only 0/1 are trustworthy; anything else must not be quietly folded
    // into "sleep enabled".
    #expect(PMSet.parseSleepDisabled(from: " SleepDisabled        2") == nil)
}

@Test func conflictingDuplicateKeysAreUnknown() {
    let output = """
     SleepDisabled        1
     SleepDisabled         0
    """
    #expect(PMSet.parseSleepDisabled(from: output) == nil)
}

@Test func agreeingDuplicateKeysCollapseToOneResult() {
    let output = """
     SleepDisabled        1
     SleepDisabled         1
    """
    #expect(PMSet.parseSleepDisabled(from: output) == true)
}

@Test func realPMSetReaderReadsThisMachinesActualState() throws {
    // Exercises the real `pmset -g` shell-out, not just the parser, so a
    // fake standing in for the reader can't hide a broken Process pipeline.
    //
    // Deliberately does not assert true/false: that's this Mac's current
    // `disablesleep` state today, but it must not be a fixed expectation —
    // a Mac actually running Let It Brew with lid-closed mode on would have it
    // flip to true, and a test that fails when the product does its job
    // is worse than no test. What's invariant is that the process launches,
    // the pipe drains, the exit status is handled, and the output parses to
    // a real answer rather than "couldn't read".
    _ = try #require(PMSetSleepControl().isSleepDisabled() as Bool?)
}

private let laptopCustom = """
Battery Power:
 Sleep On Power Button 1
 powermode            0
 standby              1
 displaysleep         30
AC Power:
 Sleep On Power Button 1
 powermode            2
 womp                 1
"""

@Test func readsEachSourcesPowerModeExactly() {
    #expect(PMSet.parsePowerModes(from: laptopCustom) == PowerModeSnapshot(
        battery: PowerModeValue(key: "powermode", value: 0),
        charger: PowerModeValue(key: "powermode", value: 2)
    ))
}

@Test func readsTheOlderLowPowerModeName() {
    let output = """
    Battery Power:
     lowpowermode         1
    AC Power:
     lowpowermode         0
    """
    let snapshot = PMSet.parsePowerModes(from: output)
    #expect(snapshot?.battery == PowerModeValue(key: "lowpowermode", value: 1))
    #expect(snapshot?.charger == PowerModeValue(key: "lowpowermode", value: 0))
    #expect(snapshot?.isLowPowerEverywhere == false)
}

@Test func aDesktopHasOnlyTheChargerSource() {
    let output = """
    AC Power:
     powermode            1
    UPS Power:
     powermode            0
    """
    let snapshot = PMSet.parsePowerModes(from: output)
    #expect(snapshot == PowerModeSnapshot(charger: PowerModeValue(key: "powermode", value: 1)))
    #expect(snapshot?.sources == [.charger])
    #expect(snapshot?.isLowPowerEverywhere == true)
}

@Test func aMacWithoutAnEnergyModeReportsNoSources() {
    let output = """
    Battery Power:
     standby              1
    AC Power:
     standby              1
    """
    #expect(PMSet.parsePowerModes(from: output)?.sources == [])
    #expect(PMSet.parsePowerModes(from: output)?.isLowPowerEverywhere == false)
}

@Test func untrustworthyPowerModeOutputIsRejected() {
    #expect(PMSet.parsePowerModes(from: nil) == nil)
    #expect(PMSet.parsePowerModes(from: "") == nil)
    #expect(PMSet.parsePowerModes(from: "Battery Power:\n powermode  low\n") == nil)
    #expect(PMSet.parsePowerModes(from: "Battery Power:\n powermode  -1\n") == nil)
    #expect(PMSet.parsePowerModes(
        from: "Battery Power:\n powermode  0\n powermode  1\n"
    ) == nil)
    #expect(PMSet.parsePowerModes(
        from: "Battery Power:\n powermode  0\n lowpowermode  0\n"
    ) == nil)
}
