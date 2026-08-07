import AVFoundation
import Foundation
import Observation

/// Playback for one recording at a time, with a time signal fine enough to
/// follow a transcript.
///
/// `AVPlayer`, not `AVAudioPlayer`: only `AVPlayer` offers
/// `addPeriodicTimeObserver`, and following playback needs the player to tell
/// us where it is rather than being polled on a timer.
@MainActor
@Observable
public final class AudioPlayer {
    public private(set) var currentTime: Double = 0
    public private(set) var isPlaying = false
    public private(set) var duration: Double = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    /// The URL the current `player` was built from, so a second `load(_:)`
    /// for that same URL can be recognized as redundant rather than tearing
    /// down and rebuilding playback state that a caller may have just set up
    /// (see `load(_:)`).
    @ObservationIgnored private var loadedURL: URL?
    /// Watches the loading item for `.failed`, so a load that never becomes
    /// playable does not permanently wedge `loadedURL` (see `load(_:)`).
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?

    /// The playback speed the user chose, never zero.
    ///
    /// Distinct from `AVPlayer.rate`, which is this value while playing and 0
    /// while paused — one property carrying two meanings. Keeping the choice
    /// here is what lets `pause()` stop playback without forgetting the
    /// speed, and `play()` resume at it rather than at 1x.
    public private(set) var rate: Double

    @ObservationIgnored private let defaults: UserDefaults
    private static let rateKey = "playbackRate"

    /// - Parameter defaults: injectable so tests never write the user's real
    ///   preference domain. `AppModel` has no equivalent seam, which is why
    ///   no test can drive its write paths; this one is cheap, so it exists.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.rateKey)
        // `double(forKey:)` returns 0 for a missing key, which `clampedRate`
        // already maps to 1 — so a fresh install and a corrupt value take the
        // same safe path without a separate existence check.
        self.rate = Self.clampedRate(stored)
    }

    /// Sets the speed, applies it if playback is under way, and remembers it.
    public func setRate(_ newRate: Double) {
        rate = Self.clampedRate(newRate)
        defaults.set(rate, forKey: Self.rateKey)
        if isPlaying { player?.rate = Float(rate) }
    }

    /// A speed, or 1 for anything that is not one.
    ///
    /// PURE. Zero and negatives are stopped/reversed players rather than
    /// speeds, and a NaN reaching `AVPlayer.rate` is undefined.
    nonisolated static func clampedRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }

    /// What `AVPlayer.rate` should be, given the chosen speed and whether
    /// playback is under way.
    ///
    /// PURE, and the whole two-meanings reconciliation in one line.
    nonisolated static func appliedRate(chosen: Double, isPlaying: Bool) -> Float {
        isPlaying ? Float(clampedRate(chosen)) : 0
    }

    // The observer token is typed `Any`, which can never be proven
    // `Sendable` — so a plain `nonisolated deinit` (the default) cannot
    // legally touch it, regardless of how carefully access is actually
    // synchronized. `isolated deinit` (SE-0371) makes this deinit genuinely
    // isolated to the main actor instead of merely asserting past the
    // check: it hops to the main actor if invoked off it, or runs
    // synchronously if already there. That turns the read below into an
    // ordinary same-actor access, so the Sendable-crossing check never
    // fires — the access is proven safe, not just asserted safe.
    isolated deinit {
        // The observer holds the player; without this the pair outlives the
        // window and keeps ticking.
        if let observer, let player { player.removeTimeObserver(observer) }
    }

    /// A second `load(_:)` for the URL already loaded is a no-op — unless
    /// the first attempt failed.
    ///
    /// Without the no-op guard, two callers that both react to the same
    /// selection change — the `.onChange(of: store.selection)` that owns
    /// loading, and a moment's "play" action which sets that same selection
    /// and then wants to seek immediately — race to rebuild `player` for the
    /// same file. Whichever runs second would tear down the just-built
    /// player, reset `currentTime` to 0, and drop the rate back to 0 —
    /// silently undoing a seek and pause that already landed. Guarding by
    /// URL makes the redundant call inert instead of destructive, without
    /// either caller needing to know about the other.
    ///
    /// But committing `loadedURL` unconditionally would wedge a *failed*
    /// load (missing file, unsupported format, ...) as "loaded" forever:
    /// every later click on a moment in that recording would silently do
    /// nothing, with no way to retry short of loading a different recording
    /// first. `statusObserver` watches for `.failed` and frees `loadedURL`
    /// when it happens, so the next `load(_:)` for that URL is a real retry
    /// rather than another no-op. It re-checks `loadedURL == url` before
    /// clearing, so a stale failure notification from a since-superseded
    /// item can't clobber a newer, successful load. Deferring the
    /// `loadedURL` commit until the item is confirmed good, instead, was
    /// not an option: readiness is inherently asynchronous — it can never
    /// resolve within the same synchronous turn `load(_:)` runs in — so the
    /// redundant call above would always land in the "not yet committed"
    /// window and reopen the exact race this guard exists to close.
    public func load(_ url: URL) {
        guard url != loadedURL else { return }
        stop()
        loadedURL = url
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        currentTime = 0
        duration = 0

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.loadedURL == url else { return }
                self.loadedURL = nil
            }
        }

        // Four times a second: fine enough that a highlight lands on the right
        // line, coarse enough not to churn the view for a text list.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            // Load-bearing, not decorative: this closure is only ever invoked
            // on `.main` because the observer above was registered with
            // `queue: .main`. That is what makes the assumption legal.
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
                if let seconds = self?.player?.currentItem?.duration.seconds,
                   seconds.isFinite {
                    self?.duration = seconds
                }
            }
        }
    }

    /// Starts playback, and reports `isPlaying` only if there is something to
    /// play.
    ///
    /// The guard is an honesty fix, not a safety one — `player?.play()` on nil
    /// was already harmless. `isPlaying` is a CLAIM about the world, and the
    /// transport's button renders it directly: setting it unconditionally
    /// meant that with no loaded player the icon flipped to Pause over
    /// silence, which is the reason the reopened-window bug was invisible
    /// rather than obvious. Refusing costs nothing — every real caller loads
    /// first — and it turns a silent lie into a button that visibly does not
    /// latch.
    ///
    /// `pause()` needs no equivalent: reporting "not playing" when there is no
    /// player is true.
    public func play() {
        guard let player else { return }
        player.rate = Self.appliedRate(chosen: rate, isPlaying: true)
        isPlaying = true
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Seeks EXACTLY, not to the nearest sync sample.
    ///
    /// `AVPlayer.seek(to:)` without tolerances defaults both to
    /// `.positiveInfinity`, which lets it land on whatever sync sample is
    /// nearest — so a scrubber thumb dropped at 41:00 could resume somewhere
    /// else, and clicking a transcript line could start mid-way through the
    /// previous one. Naming zero tolerances makes "seeks where you dropped it"
    /// true in code instead of something a human has to go and check.
    ///
    /// Affordable here specifically because the library is MP3
    /// (`FileInfo.preferredExtension`): its frames are ~26ms and near-enough
    /// independently decodable, so an exact seek decodes a handful of frames
    /// rather than a long GOP. And a drag issuing several seeks a second is
    /// not a pile-up — `AVPlayer` cancels a pending seek when a new one
    /// arrives.
    public func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    public func stop() {
        pause()
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        statusObserver = nil
        player = nil
        currentTime = 0
        duration = 0
        loadedURL = nil
    }

    /// Which segment is being spoken at `time`, or nil in a gap.
    ///
    /// PURE, and therefore the testable part — the `AVPlayer` above cannot be
    /// exercised without audio hardware. A segment owns its own start instant:
    /// seeking to a line's start must highlight that line, not the one before.
    nonisolated static func currentSegmentIndex(at time: Double, in segments: [Segment]) -> Int? {
        segments.firstIndex { time >= $0.start && time < $0.end }
    }
}
