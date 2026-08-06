import Foundation
import Testing
@testable import StenoUI

/// Every sidecar already on disk predates spec 2. If adding fields breaks their
/// decode, `scanSidecars()` silently returns fewer recordings and a rebuild
/// quietly empties the library's index.
@Test func aRealSpec1SidecarStillDecodesWithNewFieldsNil() throws {
    let url = try #require(Bundle.module.url(
        forResource: "spec1-sidecar", withExtension: "json", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)

    let sidecar = try Library.decoder.decode(Sidecar.self, from: data)

    #expect(sidecar.deviceModel == "hidock-p1")
    #expect(!sidecar.signature.isEmpty)
    #expect(sidecar.title == nil)
    #expect(sidecar.topic == nil)
    #expect(sidecar.transcribedAt == nil)
    #expect(sidecar.transcriptBackend == nil)
    #expect(sidecar.transcriptionAttempts == nil)
}

/// Round-tripping a spec-1 sidecar must not invent values for the new fields.
@Test func reEncodingASpec1SidecarKeepsNewFieldsAbsent() throws {
    let url = try #require(Bundle.module.url(
        forResource: "spec1-sidecar", withExtension: "json", subdirectory: "Fixtures"))
    let sidecar = try Library.decoder.decode(Sidecar.self, from: Data(contentsOf: url))

    let json = String(decoding: try Library.encoder.encode(sidecar), as: UTF8.self)

    #expect(!json.contains("\"title\""))
    #expect(!json.contains("\"topic\""))
    #expect(!json.contains("\"transcriptionAttempts\""))
}
