import Foundation

/// Pure order coordinator.  The prepared value crosses persistence unchanged,
/// which makes a post-registry re-read structurally impossible at this layer.
public enum AgentInstallTransaction {
    public static func install<Prepared>(preflightPureTransform: () throws -> Prepared,
                                         persistExactTarget: (Prepared) throws -> Void,
                                         commitVendorMutation: (Prepared) throws -> Void) throws {
        let prepared = try preflightPureTransform()
        try persistExactTarget(prepared)
        try commitVendorMutation(prepared)
    }
    public static func uninstall(removeOwnedOrProveAbsent: () throws -> Void,
                                 clearExactTarget: () throws -> Void) throws {
        try removeOwnedOrProveAbsent()
        try clearExactTarget()
    }
}
