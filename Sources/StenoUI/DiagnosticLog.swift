import Darwin
import Foundation

/// A tiny, best-effort diagnostic logger for `AppModel`/`SyncEngine`.
///
/// PURELY OBSERVATIONAL. This exists to answer one question after the fact --
/// where did the time go on a slow sync -- by recording every point where
/// that time could hide (poll ticks, retries, transfers). It changes no
/// behaviour anywhere it's called from: every entry point here is a
/// fire-and-forget call that never throws and never blocks its caller on
/// disk I/O.
///
/// An actual instance (not a bare namespace), so it can be injected. `nil` is
/// the "don't log" case: `SyncEngine`'s tests construct it with no logger at
/// all, so a `FakeDevice`-driven test run cannot write a single byte to the
/// user's real `~/Library/Logs/Steno/steno.log` -- there is no shared
/// mutable path or environment variable to override, just a dependency that
/// either is or isn't there. `AppModel` owns the one real instance for the
/// app's process lifetime and hands it to every `SyncEngine` it constructs.
///
/// Every I/O failure -- can't create the directory, can't open the file,
/// can't rotate -- is swallowed. A logger that can crash the app it's
/// watching is worse than no logger at all.
/// `public`: `SyncEngine.init`'s `log:` parameter is public API, and Swift
/// requires a public signature's types to be at least as visible as the
/// signature itself. Nothing outside this module actually needs to construct
/// one -- `init`/`log(...)`/etc. below stay at their default (internal)
/// access level.
public struct DiagnosticLog: Sendable {
    let destinationURL: URL

    init(destinationURL: URL = DiagnosticLog.defaultURL) {
        self.destinationURL = destinationURL
    }

    /// `~/Library/Logs/Steno/steno.log`. Same convention as any other
    /// per-app log under `~/Library/Logs`.
    static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/Steno/steno.log")
    }()

    /// The file is rotated to `steno.log.1` once it exceeds this size, so a
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
    func log(
        _ event: String, _ pairs: KeyValuePairs<String, String> = [:], suffix: String? = nil
    ) {
        let line = Self.format(event: event, pairs: pairs, suffix: suffix)
        let url = destinationURL
        Task.detached(priority: .utility) {
            Self.append(line, to: url)
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
    /// works at "a few lines per 10 seconds" -- but the open MUST carry
    /// `O_APPEND`, and the write MUST go through the raw `write(2)` syscall
    /// rather than `FileHandle`.
    ///
    /// `FileHandle(forWritingTo:)` + `seekToEnd()` + `write(contentsOf:)` was
    /// the original implementation, and it is NOT atomic: seeking to the end
    /// and writing are two separate steps, so two callers can both resolve
    /// the same end offset and the second write overwrites (tears) the
    /// first's bytes on disk. A real capture from the live app showed exactly
    /// this -- the attach handler and the sync task both logged within a
    /// millisecond and one line's first ~40 characters were clobbered.
    /// `O_APPEND` makes the kernel perform the seek-to-end and the write as
    /// one atomic step per `write(2)` call, and that call is itself atomic
    /// for any single write under `PIPE_BUF` -- every line here is
    /// comfortably under that.
    static func append(_ line: String, to url: URL, cap: Int = rotationCapBytes) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return
        }
        rotateIfNeeded(url, cap: cap)

        let data = Data((line + "\n").utf8)
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }

        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(fd, base, buffer.count)
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
