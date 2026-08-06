import Foundation
import Testing
@testable import StenoUI

/// The automatic backend must be the free one. A cloud backend running
/// unattended would bill on every 66-minute meeting without being asked.
@Test func theAutomaticBackendIsAlwaysOnDevice() {
    #expect(TranscriberRegistry.automatic().id == "speechanalyzer")
}

@Test func bothBackendsAreRegistered() {
    #expect(Set(TranscriberRegistry.all().map(\.id)) == ["speechanalyzer", "deepgram"])
}
