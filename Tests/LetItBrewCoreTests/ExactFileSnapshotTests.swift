import Foundation
import Testing
@testable import LetItBrewCore

@Test func snapshotWireFormatRejectsUnknownAndInvalidEvidence() {
    let invalid = [
        #"{"path":"/tmp/x","exists":true,"deviceID":1,"inode":1,"byteCount":0,"modificationSeconds":0,"modificationNanoseconds":1000000000,"sha256":"not-a-digest"}"#,
        #"{"path":"/tmp/x","exists":false,"deviceID":null,"inode":null,"byteCount":null,"modificationSeconds":null,"modificationNanoseconds":null,"sha256":null,"extra":1}"#,
    ]
    for json in invalid {
        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(ExactFileSnapshot.self, from: Data(json.utf8))
        }
    }
}

@Test func exactReadRetriesEINTRAndRejectsShortCount() throws {
    var interruptedCalls = 0
    let bytes = try readExactFileBytes(from: -1, expectedSize: 3, path: "/tmp/read") { _, buffer, _ in
        interruptedCalls += 1
        if interruptedCalls == 1 { errno = EINTR; return -1 }
        if interruptedCalls == 2 {
            buffer[0] = 97; buffer[1] = 98; buffer[2] = 99
            return 3
        }
        return 0
    }
    #expect(bytes == Data("abc".utf8))
    var shortCalls = 0
    #expect(throws: ExactFileSnapshotError.self) {
        _ = try readExactFileBytes(from: -1, expectedSize: 3, path: "/tmp/read") { _, buffer, _ in
            shortCalls += 1
            guard shortCalls == 1 else { return 0 }
            buffer[0] = 97
            return 1
        }
    }
}
