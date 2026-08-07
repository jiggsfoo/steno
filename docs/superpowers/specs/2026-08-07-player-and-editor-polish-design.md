# Spec 5 — the player transport and inline editing

A real playback transport at the bottom of the library window, and an editor
that stops being a modal.

## Why now

Spec 4 shipped and the window works. Two things in it read as unfinished the
first time a person used them.

The transport is the spec's literal minimum: play/pause, a bare `Slider`,
elapsed/total. There is no way to change speed, no way to skip back over a
sentence you missed, and no sense of how much is left. For 50–66 minute
meetings that is the difference between a control and a placeholder.

The editor is an unstyled `Form` whose Topic field and "Existing topics" picker
set the same value — two controls for one thing, which is why it reads as a
debug panel rather than a Mac dialog.

Neither is a defect. Both are polish, and they are grouped here because they
are the same kind of work on the same window.

## Decisions

### Anything that moves the playhead re-attaches following

The follow-and-detach rule from spec 4 gains one line rather than a new
concept:

```
hand scroll        -> detach
click a line       -> re-attach   (spec 4)
scrub              -> re-attach   (spec 4)
±10s skip          -> re-attach   (new)
speed change       -> no effect   (new)
play / pause       -> no effect
```

A skip moves the playhead, so the transcript should follow you there. Speed
changes nothing about position, so it has no business yanking a view you are
reading.

This makes `TranscriptPane.followsAfterPlayheadMove()` load-bearing. Spec 4's
final review flagged it as "documentation wearing a function signature" — it
takes no arguments and returns a literal `true`, and reverting its call sites
to an inline assignment left the whole suite green. A third caller does not fix
that on its own, but the rule it encodes now spans four call sites and one
deliberate exclusion, which is worth naming once rather than four times.

### Speed is one app-wide preference that survives quit

Angelo listens to hours of his own meetings. The speed preference is about how
he listens, not about a particular file — so it is a single `UserDefaults` key
beside the library root, not per-recording state and nothing new in the
sidecar.

Choices are 0.75×, 1×, 1.25×, 1.5×, 1.75×, 2×.

**`AudioPlayer` owns the reconciliation, not the view.** `AVPlayer.rate` is
the playback speed while playing and `0` while paused, so "the rate" and "the
speed" are the same property with two meanings. Left to the view, pausing
would read as 0× and resuming would lose the setting. `AudioPlayer` gains a
`rate` property that is the *chosen* speed, applied to `AVPlayer` on `play()`
and on change while playing, and never clobbered by `pause()`.

### Two rows, so the scrubber is full width

The scrubber gets its own line with elapsed under its left end and remaining
under its right; the controls sit centred below with the speed menu pinned
right.

The one-row alternative squeezes the scrubber into whatever horizontal space
the controls and labels leave. At 66 minutes that is roughly a fifth of the
pixels-per-minute, and seek precision is the thing that actually matters at
this length. The extra ~30pt of height is cheap in a window this size.

A toolbar placement was considered and rejected: the toolbar already carries
the title and the search field, and a cramped scrubber is worse than no
scrubber for a recording this long.

### The right-hand label toggles remaining and total

Click it to swap. Elapsed on the left never changes. That is how Music behaves
and it is how both numbers fit without a third label.

### The editor becomes the header

`RecordingEditor` stops being a sheet. Title and topic edit in place in
`TranscriptPane`'s header, which is where they are already displayed.

Inline rename is the dominant macOS pattern for naming things in a list —
Finder, Photos albums, Reminders lists, Xcode's navigator — and it removes a
modal from the common case entirely.

**Hover reveals the affordance.** Static text that is secretly clickable is the
weak point of inline editing, so both fields pick up a subtle rounded
background on hover. Without it the control is invisible.

**The topic's editing control is a combo box**, text field plus chevron, with
a menu of existing topics and a "None — unfile this" item. The chevron is not
optional: a dropdown that does not advertise itself will never be found, and
discovering existing topics is the entire reason this is a combo box rather
than a text field.

Topic stays a single value. Multi-tag was considered and deferred — see Scope.

### Refusals stay in edit mode, with the reason underneath

`TopicName.sanitised` rejects a bad folder name rather than repairing it, so
`updateRecording` can return `.rejectedTopic`. The sheet had a caption line for
that and for `.busy`; inline editing needs an equivalent or the field simply
appears not to work.

The field keeps focus and keeps what was typed, and the reason appears below
it. A refusal is not transient — it is a thing to act on, and it should sit
still while you act on it. `.busy` stays visually distinct from a failure,
because something else legitimately writing the recording is not an error.

## Architecture

No new files. Three existing ones change, and the write path underneath does
not change at all.

```
AudioPlayer.swift      gains `rate`, and the play/pause reconciliation.
TranscriptPane.swift   the two-row transport; hosts the header editor.
RecordingEditor.swift  becomes the inline header editor rather than a sheet's
                       content; keeps save(), its outcome handling, and both
                       pure decisions.
```

**`RecordingEditor` survives as a type, and stays the thing that saves.** What
changes is where it is presented: `TranscriptPane`'s header embeds it directly
instead of `.sheet(isPresented:)` presenting it. Keeping the save path inside
one view — rather than scattering `updateRecording` calls into
`TranscriptPane` — is what makes "the write path is untouched" true rather than
aspirational.

**`AppModel.updateRecording` is untouched.** The `sidecarsInFlight` guard, the
stale-snapshot re-read added in spec 4's final wave, `index.upsert`,
`Filer.removeNote`/`write`, and `onSaved` triggering the window reload all stay
exactly as reviewed. This spec changes what you click, not what happens when
you commit. A change to that path is out of scope by construction.

New pure functions, matching the existing `nonisolated static` precedent in
`TranscriptPane` (`scrubber`, `elapsed`, `transportDuration`, `remainsFollowing`):

```swift
/// Time left, formatted with a leading minus.
///
/// A zero duration means "not known yet" here, exactly as it does in
/// `scrubber` and `elapsed` — those already resolve the observed and sidecar
/// durations to one number via `transportDuration`, and this must read the
/// same number so the bar and the two labels cannot disagree.
nonisolated static func remaining(currentTime: Double, duration: Double) -> String

/// Where a skip lands, clamped at both ends.
///
/// Skipping back at 0:03 lands at 0:00, not -7. Skipping forward near the end
/// lands at the end, not past it. A zero duration clamps to 0.
nonisolated static func skipTarget(from currentTime: Double,
                                   by delta: Double,
                                   duration: Double) -> Double

/// The speed menu's choices, slowest first. Which one is current is
/// `AudioPlayer.rate`, not a return value — one source of truth.
nonisolated static func speedChoices() -> [Double]
```

The remaining/total toggle is `@State` on `TranscriptPane`, not persisted: it
is a glance, not a preference, and it resets per recording along with the rest
of the pane's state when `.id(recording.id)` changes.

`RecordingEditor` keeps `topicChoices(from:)` and `message(for:)` unchanged —
both are already pure and already tested, and the inline form needs exactly the
same two answers the sheet did.

## Data flow

### Speed

```
menu selection -> AudioPlayer.rate = chosen
                  -> if isPlaying, AVPlayer.rate = chosen
                  -> UserDefaults, one key
play()         -> AVPlayer.rate = AudioPlayer.rate   (not 1.0)
pause()        -> AVPlayer.rate = 0, AudioPlayer.rate untouched
```

### Skipping

```
±10s -> skipTarget(from: currentTime, by: ±10, duration:)
     -> AudioPlayer.seek(to:)        already exact, zero tolerances
     -> isFollowing = followsAfterPlayheadMove()
```

### Editing

```
hover        -> affordance
click        -> TextField (title) or combo box (topic), current value selected
Return       -> save() as today: updateRecording, guard, re-read, onSaved
Esc          -> restore the previous value, leave edit mode
.updated     -> leave edit mode
.rejectedTopic / .failed / .busy
             -> STAY in edit mode, keep what was typed, reason underneath
```

## Traps specific to this codebase

**`AVPlayer.rate` is two things.** Reading it to learn the speed gives `0`
whenever playback is paused. Every speed decision must read `AudioPlayer.rate`,
never the AVPlayer's.

**The periodic observer writes `currentTime` four times a second.** It already
coexists with scrubbing; it now also coexists with skipping. A skip is a single
seek, so this is not new — but any test asserting on position after a skip must
not race the observer.

**Inline text fields swallow keys.** This is why keyboard shortcuts are out of
scope: Space-for-play-pause collides with typing a title the moment the header
is in edit mode, and resolving that properly is its own set of decisions.

**`ImageRenderer` draws nothing inside a `ScrollView`.** Spec 4 discovered this;
`LibraryLayoutTests.hostedInkBands` exists because of it. Any layout assertion
about the transport must use that helper, and must respect its documented
one-sided ~0.5pt bias — it is not a drop-in for `inkBands`.

**Editing lives in the header, above the `ScrollView`,** so the transport-mount
test (`theTransportRowIsMountedBelowARuleAtTheBottomOfThePane`) and the
identity guard (`selectingARecordingGivesTheDetailPaneAFreshIdentity`) both
still apply and must both still discriminate afterwards.

## Testing

The pure functions carry it, as in spec 4: `remaining` at zero, mid-way, and at
the end; `skipTarget` clamped at both ends, from 0, and with an unknown
duration; the speed reconciliation across play, pause, change-while-paused and
change-while-playing.

The inline editor's outcome handling reuses `message(for:)`'s existing tests
and adds the one thing that is genuinely new: that a refusal leaves edit mode
**on**, and a success leaves it off.

Layout assertions use `hostedInkBands`, rendering both unconstrained and inside
a deliberately short container, asserting on spacing rather than band count.

**No test may** write to `~/Recordings/Steno/`, `~/Library/Logs/Steno/`, or
`~/Library/Application Support/Steno/`, touch the real `deepgram-api-key`
Keychain item, or require a P1, network, Apple Intelligence, or a downloaded
model. Constructing `AppModel()` is established precedent; calling through it to
a write path is not — `libraryRoot`'s setter rebuilds a hardcoded index and
starts a real transcription task.

**What no test can reach**, to be recorded as human checks rather than
pretended at: that a speed change is audible, that a drag feels smooth against
the observer, and that hover reveals the affordance.

## Scope

**Out:** keyboard shortcuts; multi-tag topics; waveform display; chapter marks;
any change to `AppModel.updateRecording` or the filing model.

**Multi-tag topics deserve a note rather than a line.** Finder Tags is the right
reference, and the reason they work is that Finder separates *location* from
*tags*: a file lives in one place and carries many. Steno's `topic` currently
does both jobs — it is the organising metadata *and* the folder the note is
written into. Making it many-valued forks the filing model: `Sidecar.topic`
becomes an array and the 11 existing sidecars need migrating, `Filer.write`
writes N notes or notes move somewhere neutral with tags in front matter,
`removeNote` reconciles a set rather than removing one, "File this under X"
needs a meaning when there are three, and the sidebar shows one recording in
several groups.

That is a better end state and it is a spec of its own, with a migration. It is
not a polish pass. The single-topic combo box here is deliberately shaped so
that going multi later changes the model and barely touches the UI.
