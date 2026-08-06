import Foundation
import Testing
@testable import StenoUI

@Test func requestCarriesTheKeyAsATokenHeaderAndNeverInTheURL() throws {
    let request = try DeepgramTranscriber.request(
        for: URL(fileURLWithPath: "/tmp/a.mp3"), apiKey: "secret-key")

    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Token secret-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/mpeg")
    #expect(request.url?.absoluteString.contains("secret-key") == false)
    #expect(request.url?.absoluteString.contains("diarize=true") == true)
    #expect(request.url?.absoluteString.contains("model=nova-3") == true)
}

@Test func anEmptyKeyIsRefusedBeforeAnyNetworkCall() {
    #expect(throws: TranscriberError.missingCredential("Deepgram")) {
        try DeepgramTranscriber.request(for: URL(fileURLWithPath: "/tmp/a.mp3"), apiKey: "")
    }
}

/// Fixture captured once from a real 3-second recording (Step 1 of the task
/// brief). Parsed offline — this test makes no network call.
@Test func responseParsesIntoSegmentsWithSpeakers() throws {
    let url = try #require(Bundle.module.url(
        forResource: "deepgram-response", withExtension: "json", subdirectory: "Fixtures"))
    let body = try DeepgramTranscriber.body(
        fromResponse: Data(contentsOf: url), locale: "en_PH")

    #expect(body.backend == "deepgram")
    #expect(body.modelID == "nova-3")
    #expect(!body.text.isEmpty)
    #expect(!body.segments.isEmpty)
    #expect(body.segments.contains { $0.speaker != nil },
            "diarization requested but no speaker came back")
}

@Test func malformedResponseThrowsRatherThanReturningEmptyText() {
    #expect(throws: (any Error).self) {
        try DeepgramTranscriber.body(fromResponse: Data("{}".utf8), locale: "en_PH")
    }
}

@Test func deepgramTranscriberIdIsStableBecauseItIsPersistedInEveryTranscript() {
    #expect(DeepgramTranscriber().id == "deepgram")
}
