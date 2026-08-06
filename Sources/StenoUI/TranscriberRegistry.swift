import Foundation

/// Which backends exist.
public enum TranscriberRegistry {
    public static func all() -> [any Transcriber] {
        [SpeechAnalyzerTranscriber(), DeepgramTranscriber()]
    }

    /// The backend that runs UNATTENDED after every sync. Always on-device,
    /// and not user-overridable: automatic transcription only stays honest
    /// while it is free. Cloud is a deliberate per-recording action, named at
    /// the moment of that action -- see `all()`'s call site in
    /// `MenuBarView`'s per-recording context menu, not a persisted setting.
    public static func automatic() -> any Transcriber {
        SpeechAnalyzerTranscriber()
    }
}
