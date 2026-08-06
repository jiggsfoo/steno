import Foundation

/// Which backends exist and which one the user picked.
public enum TranscriberRegistry {
    public static let selectionKey = "transcriberID"

    public static func all() -> [any Transcriber] {
        [SpeechAnalyzerTranscriber(), DeepgramTranscriber()]
    }

    /// The backend that runs UNATTENDED after every sync. Always on-device,
    /// and not user-overridable: automatic transcription only stays honest
    /// while it is free. Cloud is a deliberate per-recording action.
    public static func automatic() -> any Transcriber {
        SpeechAnalyzerTranscriber()
    }

    /// The backend chosen in Settings, used for explicit re-transcription.
    public static func selected() -> any Transcriber {
        let id = UserDefaults.standard.string(forKey: selectionKey)
        return all().first { $0.id == id } ?? automatic()
    }
}
