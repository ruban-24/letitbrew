import Foundation
import Testing
@testable import LetItBrewAppCore
import LetItBrewCore

private let t0 = Date(timeIntervalSince1970: 5_000)
private let terminal: Int32 = 100
private let chat: Int32 = 200

private func time(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

private func lastInput(_ attribution: FrontmostInputAttribution, _ app: Int32) -> Date? {
    guard case .lastInput(let date) = attribution.observation(forApp: app, global: .none) else {
        return nil
    }
    return date
}

@Test func typingInAnotherAppNeverCreditsTheSessionsApp() {
    var attribution = FrontmostInputAttribution()
    attribution.activate(terminal, at: t0)
    attribution.activate(chat, at: time(5))
    attribution.credit(inputAt: time(10))
    attribution.credit(inputAt: time(20))
    #expect(lastInput(attribution, terminal) == .distantPast)
    #expect(lastInput(attribution, chat) == time(20))
}

@Test func inputIsCreditedToTheAppInFrontWhenItHappenedEvenIfJudgedLater() {
    var attribution = FrontmostInputAttribution()
    attribution.activate(terminal, at: t0)
    // Approved with Enter, then switched to the chat and typed there before
    // either time was judged.
    attribution.activate(chat, at: time(10))
    attribution.credit(inputAt: time(15))
    attribution.credit(inputAt: time(8))
    #expect(lastInput(attribution, terminal) == time(8))
    #expect(lastInput(attribution, chat) == time(15))
}

@Test func theClickThatBringsAnAppForwardCountsForIt() {
    var attribution = FrontmostInputAttribution()
    let lead = FrontmostInputAttribution.activationLead
    attribution.activate(chat, at: t0)
    attribution.activate(terminal, at: time(10))
    // The click lands just before the terminal reports it is active, and an
    // app may act on that first click.
    attribution.credit(inputAt: time(10 - lead))
    #expect(lastInput(attribution, terminal) == time(10 - lead))
    attribution.credit(inputAt: time(10 - lead - 0.5))
    #expect(lastInput(attribution, terminal) == time(10 - lead))
    #expect(lastInput(attribution, chat) == time(10 - lead))
}

@Test func activationsStayInTimeOrderWhenAReadingLags() {
    let editor: Int32 = 300
    var attribution = FrontmostInputAttribution()
    attribution.activate(chat, at: t0)
    attribution.activate(terminal, at: time(10))
    // A lagging clock reading cannot place the editor's switch before the
    // terminal's, so input at 7 s still belongs to the chat.
    attribution.activate(editor, at: time(5))
    attribution.credit(inputAt: time(7))
    #expect(lastInput(attribution, chat) == time(7))
    #expect(lastInput(attribution, editor) == .distantPast)
}

@Test func anUnreadableCounterStaysUnreadableForEveryApp() {
    var attribution = FrontmostInputAttribution()
    attribution.activate(terminal, at: t0)
    attribution.credit(inputAt: time(5))
    #expect(attribution.observation(forApp: terminal, global: .unavailable) == .unavailable)
    #expect(attribution.observation(forApp: chat, global: .unavailable) == .unavailable)
}

@Test func historyIsKeptOnlyForTheRetentionWindow() {
    var attribution = FrontmostInputAttribution()
    let retention = FrontmostInputAttribution.retention
    attribution.activate(terminal, at: t0)
    attribution.credit(inputAt: time(1))
    attribution.activate(chat, at: time(2))
    attribution.credit(inputAt: time(retention))
    #expect(lastInput(attribution, terminal) == time(1))
    attribution.credit(inputAt: time(retention + 2))
    #expect(lastInput(attribution, terminal) == .distantPast)
    // The activation in effect at the cutoff is kept, so later input still
    // finds its app.
    attribution.activate(terminal, at: time(2 * retention + 10))
    attribution.credit(inputAt: time(2 * retention + 5))
    #expect(lastInput(attribution, chat) == time(2 * retention + 5))
}

@Test func inputFromBeforeLaunchCountsForEveryApp() {
    var attribution = FrontmostInputAttribution()
    // Relaunched at 100 s; the approval was made before that in an app whose
    // activation was never seen.
    attribution.activate(chat, at: time(100))
    attribution.credit(inputAt: time(40))
    #expect(lastInput(attribution, terminal) == time(40))
    #expect(lastInput(attribution, chat) == time(40))
    attribution.credit(inputAt: time(120))
    #expect(lastInput(attribution, terminal) == time(40))
}
