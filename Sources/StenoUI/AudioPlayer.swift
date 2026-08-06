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

    public init() {}

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

    public func load(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        currentTime = 0
        duration = 0

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

    public func play() {
        player?.play()
        isPlaying = true
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    public func stop() {
        pause()
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player = nil
        currentTime = 0
        duration = 0
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
