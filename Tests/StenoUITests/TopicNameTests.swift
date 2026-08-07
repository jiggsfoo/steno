import Foundation
import Testing
@testable import StenoUI

@Test(arguments: [
    "../../etc",
    "..",
    ".",
    "Grocery/List",
    "Grocery\\List",
    "/absolute",
    ".hidden",
    ".incoming",
    "",
    "    ",
    "\n\t",
    "2026-08-05",
    "1999-01-31",
    "undated",
    "UNDATED",
    "Old:Name",
])
func hostileOrCollidingNamesAreRejected(_ raw: String) {
    #expect(TopicName.sanitised(raw) == nil, "should have been rejected: \(raw)")
}

@Test func controlCharactersAreRejectedNotStripped() {
    #expect(TopicName.sanitised("Grocery\u{0}List") == nil)
    #expect(TopicName.sanitised("Grocery\u{7}List") == nil)
}

@Test func overlongNamesAreRejectedNotTruncated() {
    #expect(TopicName.sanitised(String(repeating: "a", count: 61)) == nil)
    #expect(TopicName.sanitised(String(repeating: "a", count: 60)) != nil)
}

@Test(arguments: [
    ("Grocery List", "Grocery List"),
    ("  Grocery List  ", "Grocery List"),
    ("grocery list", "grocery list"),
    ("Client Calls 2026", "Client Calls 2026"),
    ("Q3 Planning", "Q3 Planning"),
])
func ordinaryNamesPassThroughWithOnlyWhitespaceTrimmed(_ pair: (String, String)) {
    #expect(TopicName.sanitised(pair.0) == pair.1)
}

/// A date-shaped name would sit beside the library's own dated folders and be
/// indistinguishable from one. `undated` and `.incoming` are Library's too.
@Test func rejectionProtectsTheLibrarysOwnLayout() {
    #expect(TopicName.sanitised("2026-08-05") == nil)
    #expect(TopicName.sanitised("2026-8-5") != nil)   // not the library's format
}

/// The sidebar's sentinel, not a folder: `LibrarySidebar.grouped` files every
/// untopiced recording under `sidecar.topic ?? unfiled`. A recording actually
/// filed under a topic of that name merges into the no-topic group and becomes
/// indistinguishable from the recordings that genuinely have none — reachable
/// the moment the new editor lets someone type it.
///
/// Asserted against `LibrarySidebar.unfiled` itself, not a copy of its
/// spelling: a test with its own literal would keep passing if the sentinel
/// were ever renamed, which is exactly the drift `reserved` references it to
/// avoid.
@Test func theSidebarsUnfiledSentinelIsReserved() {
    #expect(TopicName.sanitised(LibrarySidebar.unfiled) == nil)
    #expect(TopicName.sanitised(LibrarySidebar.unfiled.lowercased()) == nil)
    #expect(TopicName.sanitised("  UNFILED  ") == nil)
}
