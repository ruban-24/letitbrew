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
    applied: Hold = held,
    sendingToPhone: Bool,
    at seconds: TimeInterval
) -> Hold {
    grace.hold(
        wanted: wanted,
        applied: applied,
        sendingToPhone: sendingToPhone,
        now: start + seconds
    )
}

private func settle(_ grace: inout PhoneAlertHoldGrace, _ generation: Int) -> Hold? {
    grace.sendSettled(generation: generation)
}

private func expire(_ grace: inout PhoneAlertHoldGrace, _ generation: Int) -> Hold? {
    grace.expire(generation: generation)
}

@Test func aReleaseWithNoPhoneSendIsAppliedAtOnce() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: released, sendingToPhone: false, at: 0) == released)
    #expect(!grace.isKeeping)
}

@Test func phoneSendsWhileTheHoldStaysOnChangeNothing() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: held, sendingToPhone: true, at: 0) == held)
    #expect(!grace.isKeeping)
    #expect(poll(&grace, wanted: released, sendingToPhone: false, at: 1) == released)
}

@Test func aReleaseThatSendsToThePhoneKeepsTheHoldUntilTheSendSettles() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: released, sendingToPhone: true, at: 0) == held)
    let send = grace.generation
    #expect(poll(&grace, wanted: released, sendingToPhone: false, at: 1) == held)

    #expect(settle(&grace, send) == released)
    #expect(!grace.isKeeping)
    #expect(poll(&grace, wanted: released, sendingToPhone: false, at: 2) == released)
}

@Test func aReleaseOfOnlyTheLidHoldKeepsWhatWasApplied() {
    var grace = PhoneAlertHoldGrace()
    let lidOnly = Hold(system: false, lidClosed: true)
    #expect(poll(&grace, wanted: released, applied: lidOnly, sendingToPhone: true, at: 0)
        == lidOnly)
}

@Test func theGraceNeverOutlastsFifteenSeconds() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: released, sendingToPhone: true, at: 0) == held)
    #expect(poll(&grace, wanted: released, sendingToPhone: false, at: 14.9) == held)
    #expect(poll(&grace, wanted: released, sendingToPhone: false, at: 15) == released)
    #expect(!grace.isKeeping)
}

@Test func expiringAtTheCapReleasesWithoutWaitingForAPoll() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: released, sendingToPhone: true, at: 0) == held)
    #expect(expire(&grace, grace.generation) == released)
    #expect(!grace.isKeeping)
    #expect(poll(&grace, wanted: released, sendingToPhone: false, at: 1) == released)
}

@Test func moreSendsDuringTheGraceWaitTooButNeverExtendIt() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: released, sendingToPhone: true, at: 0) == held)
    let generation = grace.generation
    #expect(poll(&grace, wanted: released, sendingToPhone: true, at: 1) == held)
    #expect(grace.generation == generation)

    #expect(settle(&grace, generation) == nil)
    #expect(poll(&grace, wanted: released, sendingToPhone: false, at: 2) == held)
    #expect(settle(&grace, generation) == released)

    var capped = PhoneAlertHoldGrace()
    #expect(poll(&capped, wanted: released, sendingToPhone: true, at: 0) == held)
    #expect(poll(&capped, wanted: released, sendingToPhone: true, at: 14) == held)
    #expect(poll(&capped, wanted: released, sendingToPhone: false, at: 15) == released)
}

@Test func aNewReasonToHoldDuringTheGraceKeepsHolding() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: released, sendingToPhone: true, at: 0) == held)
    let generation = grace.generation
    #expect(poll(&grace, wanted: held, sendingToPhone: false, at: 1) == held)
    #expect(settle(&grace, generation) == held)
    #expect(poll(&grace, wanted: held, sendingToPhone: false, at: 2) == held)
}

@Test func aSendFromAnEarlierGraceDoesNotEndTheCurrentOne() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: released, sendingToPhone: true, at: 0) == held)
    let earlier = grace.generation
    #expect(poll(&grace, wanted: released, sendingToPhone: false, at: 15) == released)

    #expect(poll(&grace, wanted: released, sendingToPhone: true, at: 20) == held)
    #expect(settle(&grace, earlier) == nil)
    #expect(expire(&grace, earlier) == nil)
    #expect(poll(&grace, wanted: released, sendingToPhone: false, at: 21) == held)
}

@Test func endingTheGraceAppliesTheWantedHoldAtTheNextPoll() {
    var grace = PhoneAlertHoldGrace()
    #expect(poll(&grace, wanted: released, sendingToPhone: true, at: 0) == held)
    let generation = grace.generation
    grace.end()
    #expect(poll(&grace, wanted: released, applied: released, sendingToPhone: false, at: 1)
        == released)
    #expect(settle(&grace, generation) == nil)
}
