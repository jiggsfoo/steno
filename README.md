# hidock-mac

Native macOS menubar app for the HiDock P1 voice recorder. Replaces the
hinotes.hidock.com web app for device sync.

## Credits

The Jensen wire protocol was reverse-engineered by the community. This project
is an original Swift implementation written against those published findings:

- [sgeraldes/hidock-next](https://github.com/sgeraldes/hidock-next) (MIT)
- [ghecko/OpenHiNotes](https://github.com/ghecko/OpenHiNotes) (MIT)

Not affiliated with or endorsed by HiDock.

## Build

    swift build
    swift test
    swift run hidock-cli probe
