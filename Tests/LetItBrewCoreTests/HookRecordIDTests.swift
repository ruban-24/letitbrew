import Testing
@testable import LetItBrewCore

@Test func hookRecordIDRoundTripsReservedSeparatorsAndUnicodeByUTF8ByteLength() throws {
    let original = try #require(HookRecordID(
        agent: .claude,
        parentID: "parent|:café",
        childID: "child:🧑‍💻|"
    ))
    #expect(original.encoded == "v1|6:claude|13:parent|:café|18:child:🧑‍💻|")
    #expect(HookRecordID(encoded: original.encoded) == original)
}

@Test func hookRecordIDCanonicalEmptyChildParsesAsNil() throws {
    let parsed = try #require(HookRecordID(encoded: "v1|5:codex|6:parent|0:"))
    #expect(parsed.agent == .codex)
    #expect(parsed.parentID == "parent")
    #expect(parsed.childID == nil)
    #expect(parsed.encoded == "v1|5:codex|6:parent|0:")
}

@Test func hookRecordIDRejectsEveryMalformedStructuralCase() {
    let malformed = [
        "v2|5:codex|6:parent|0:",        // unknown version
        "v1|4:nope|6:parent|0:",         // unknown agent
        "v1|5:codex|0:|0:",             // empty parent
        "v1|:codex|6:parent|0:",         // empty length
        "v1|x:codex|6:parent|0:",        // non-decimal length
        "v1|05:codex|6:parent|0:",       // noncanonical leading zero
        "v1|5:codex|06:parent|0:",       // noncanonical parent length
        "v1|5:codex|6:parent|00:",       // noncanonical child length
        "v1|999999999999999999999999999999999999:codex|6:parent|0:", // overflow
        "v1|5:code",                     // truncation
        "v1|5:codex6:parent|0:",          // missing separator
        "v1|5:codex|6parent|0:",          // missing colon
        "v1|5:codex|7:parent|0:",         // field truncation into separator
        "v1|5:codex|6:parent|0:trailing", // trailing bytes
    ]

    for encoded in malformed {
        #expect(HookRecordID(encoded: encoded) == nil, Comment(rawValue: encoded))
    }
}

@Test func hookRecordIDRejectsLengthsThatSplitUTF8Scalars() {
    #expect(HookRecordID(encoded: "v1|5:codex|1:é|0:") == nil)
    #expect(HookRecordID(encoded: "v1|5:codex|2:é|1:🧑") == nil)
}

@Test func hookRecordIDInitializerRejectsAnEmptyParent() {
    #expect(HookRecordID(agent: .codex, parentID: "", childID: nil) == nil)
}
