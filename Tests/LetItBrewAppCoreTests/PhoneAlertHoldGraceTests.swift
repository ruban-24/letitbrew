import Foundation
import Testing
@testable import LetItBrewAppCore

private typealias Hold = PhoneAlertHoldGrace.Hold

private let start = Date(timeIntervalSince1970: 1_000_000)
private let held = Hold(system: true, lidClosed: true)
private let released = Hold(system: false, lidClosed: false)

/// `#expect` cannot take a mutating call.
private func poll(
    _ grace: inout PhoneAlertHoldGrace,
    wanted: Hold,
    applied: Hold,
    sendingToPhone: Bool,
    now: Date
) -> Hold {
    grace.hold(wanted: wanted, applied: applied, sendingToPhone: sendingToPhone, now: now)
}

private func settle(_ grace: inout PhoneAlertHoldGrace, _ generation: Int) -> Bool {
    grace.sendSettled(generation: generation)
}

@Test func aReleaseWithNoPhoneSendIsAppliedAtOnce() {
    var grace = PhoneAlertHoldGrace()
    let hold = grace.hold(wanted: released, applied: held, sendingToPhone: false, now: start)
    #expect(hold == released)
}

@Test func phoneSendsWhileTheHoldStaysOnChangeNothing() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: held, applied: held, sendingToPhone: true, now: start) == held)
    #expect(poll(&grace, wanted: released, applied: held, sendingToPhone: false, now: start + 1)
        == released)
}

@Test func aReleaseThatSendsToThePhoneKeepsTheHoldUntilTheSendSettles() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: released, applied: held, sendingToPhone: true, now: start) == held)
    let send = grace.generation
    #expect(poll(&grace, wanted: released, applied: held, sendingToPhone: false, now: start + 1)
        == held)

    #expect(settle(&grace, send))
    #expect(poll(&grace, wanted: released, applied: held, sendingToPhone: false, now: start + 2)
        == released)
}

@Test func aReleaseOfOnlyTheLidHoldKeepsWhatWasApplied() {
    var grace = PhoneAlertHoldGrace()
    let lidOnly = Hold(system: false, lidClosed: true)
    #expect(poll(&grace, wanted: released, applied: lidOnly, sendingToPhone: true, now: start)
        == lidOnly)
}

@Test func theGraceNeverOutlastsFifteenSeconds() {
    var grace = PhoneAlertHoldGrace()
    _ = grace.hold(wanted: released, applied: held, sendingToPhone: true, now: start)
    #expect(poll(&grace, wanted: released, applied: held, sendingToPhone: false, now: start + 14.9)
        == held)
    #expect(poll(&grace, wanted: released, applied: held, sendingToPhone: false, now: start + 15)
        == released)
}

@Test func moreSendsDuringTheGraceWaitTooButNeverExtendIt() {
    var grace = PhoneAlertHoldGrace()
    _ = grace.hold(wanted: released, applied: held, sendingToPhone: true, now: start)
    let generation = grace.generation
    _ = grace.hold(wanted: released, applied: held, sendingToPhone: true, now: start + 1)

    #expect(!settle(&grace, generation))
    #expect(poll(&grace, wanted: released, applied: held, sendingToPhone: false, now: start + 2)
        == held)
    #expect(settle(&grace, generation))

    var capped = PhoneAlertHoldGrace()
    _ = capped.hold(wanted: released, applied: held, sendingToPhone: true, now: start)
    _ = capped.hold(wanted: released, applied: held, sendingToPhone: true, now: start + 14)
    #expect(poll(&capped, wanted: released, applied: held, sendingToPhone: false, now: start + 15)
        == released)
}

@Test func aNewReasonToHoldDuringTheGraceKeepsHolding() {
    var grace = PhoneAlertHoldGrace()
    _ = grace.hold(wanted: released, applied: held, sendingToPhone: true, now: start)
    let generation = grace.generation
    #expect(poll(&grace, wanted: held, applied: held, sendingToPhone: false, now: start + 1) == held)
    grace.sendSettled(generation: generation)
    #expect(poll(&grace, wanted: held, applied: held, sendingToPhone: false, now: start + 2) == held)
}

@Test func aSendFromAnEarlierGraceDoesNotEndTheCurrentOne() {
    var grace = PhoneAlertHoldGrace()
    _ = grace.hold(wanted: released, applied: held, sendingToPhone: true, now: start)
    let earlier = grace.generation
    _ = grace.hold(wanted: released, applied: held, sendingToPhone: false, now: start + 15)

    _ = grace.hold(wanted: released, applied: held, sendingToPhone: true, now: start + 20)
    #expect(!settle(&grace, earlier))
    #expect(poll(&grace, wanted: released, applied: held, sendingToPhone: false, now: start + 21)
        == held)
}

@Test func endingTheGraceAppliesTheWantedHoldAtTheNextPoll() {
    var grace = PhoneAlertHoldGrace()
    _ = grace.hold(wanted: released, applied: held, sendingToPhone: true, now: start)
    grace.end()
    #expect(poll(&grace, wanted: released, applied: released, sendingToPhone: false, now: start + 1)
        == released)
}

@Test func onlyAReleaseWithPhoneSendsIsKept() {
    var grace = PhoneAlertHoldGrace()
    _ = grace.hold(wanted: held, applied: held, sendingToPhone: true, now: start)
    #expect(!grace.isKeeping)
    _ = grace.hold(wanted: released, applied: held, sendingToPhone: true, now: start + 1)
    #expect(grace.isKeeping)
    _ = grace.hold(wanted: released, applied: held, sendingToPhone: false, now: start + 16)
    #expect(!grace.isKeeping)
}
