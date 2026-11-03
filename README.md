<p align="center"><img src="docs/images/icon.png" width="160" alt="Steno app icon"></p>

# Steno

A menu bar companion for the HiDock P1. Native macOS, syncs recordings off the
device without the hinotes.hidock.com web app.

## Credits

The Jensen wire protocol was reverse-engineered by the community. This project
is an original Swift implementation written against those published findings:

- [sgeraldes/hidock-next](https://github.com/sgeraldes/hidock-next) (MIT)
- [ghecko/OpenHiNotes](https://github.com/ghecko/OpenHiNotes) (MIT)

Steno is an independent third-party app. It is not affiliated with, endorsed
by, or sponsored by HiDock Technology. "HiDock" and "HiDock P1" name the
hardware Steno talks to, nothing more.

## Build

    swift build
    swift test
    swift run steno probe

`./Scripts/make-app.sh release` produces `build/Steno.app`.
