import Foundation

/// A tiny, best-effort diagnostic logger for `AppModel`.
///
/// PURELY OBSERVATIONAL. This exists to answer one question after the fact --
/// where did the time go on a slow sync -- by recording every point where
/// that time could hide (poll ticks, retries, transfers). It changes no
/// behaviour anywhere it's called from: every entry point here is a
/// fire-and-forget call that never throws and never blocks its caller on
/// disk I/O.
///
/// Every failure -- can't create the directory, can't open the file, can't
/// rotate -- is swallowed. A logger that can crash the app it's watching is
/// worse than no logger at all.
enum DiagnosticLog {
    /// `~/Library/Logs/HiDock/hidock.log`. Same convention as any other
    /// per-app log under `~/Library/Logs`.
    static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/HiDock/hidock.log")
    }()

    /// The file is rotated to `hidock.log.1` once it exceeds this size, so a
    /// device left plugged in for months can't grow the log without bound.
    static let rotationCapBytes = 5_000_000

    /// Records one event. Formatting happens synchronously (cheap, pure, no
    /// I/O); the actual disk write is handed to a detached task so a caller
    /// on `@MainActor` -- which is every real caller -- never blocks on file
    /// I/O, however small.
    ///
    /// `suffix`, when present, is appended verbatim after the key=value
    /// pairs rather than as another pair -- used for the poll loop's
    /// `-> sync` decision marker, which reads as an annotation on the line
    /// rather than a field of it.
    static func log(
        _ event: String, _ pairs: KeyValuePairs<String, String> = [:], suffix: String? = nil
    ) {
        let line = format(event: event, pairs: pairs, suffix: suffix)
        Task.detached(priority: .utility) {
            append(line, to: defaultURL)
        }
    }

    // MARK: - Formatting (pure, synchronous, testable)

    /// One line: ISO-8601 timestamp with milliseconds, two spaces, the event
    /// name, then any key=value pairs. A value containing whitespace (or an
    /// empty value) is double-quoted so the line stays one grep-able record
    /// -- `awk`/`grep -o 'key=[^ ]*'` still works on every other field.
    static func format(
        event: String,
        pairs: KeyValuePairs<String, String> = [:],
        suffix: String? = nil,
        at date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date)

        let rendered = pairs.map { key, value -> String in
            let needsQuoting = value.isEmpty || value.contains(where: \.isWhitespace)
            return needsQuoting ? "\(key)=\"\(value)\"" : "\(key)=\(value)"
        }.joined(separator: " ")

        var line = "\(timestamp)  \(event)"
        if !rendered.isEmpty { line += "  \(rendered)" }
        if let suffix { line += " \(suffix)" }
        return line
    }

    /// Renders a `Duration` as fixed-point seconds, e.g. `6.09` -- the shape
    /// used for both transfer elapsed time and the retry backoff delay.
    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f", value)
    }

    // MARK: - I/O (best-effort; every failure is swallowed)

    /// Appends `line` to `url`, creating the containing directory and
    /// rotating first if needed. Reopens the file on every call rather than
    /// holding a handle open for the process lifetime -- simplest thing that
    /// works at "a few lines per 10 seconds".
    static func append(_ line: String, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return
        }
        rotateIfNeeded(url)

        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Swallowed -- see the type's doc comment.
            }
        } else {
            try? data.write(to: url)
        }
    }

    /// Moves `url` to `<url>.1` (replacing any existing rotation) once it
    /// exceeds `cap` bytes. A no-op if `url` doesn't exist yet or is under
    /// the cap.
    static func rotateIfNeeded(_ url: URL, cap: Int = rotationCapBytes) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > cap else { return }

        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}
