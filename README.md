# bsideyou — native macOS companion desktop

A curated source-only package of a local macOS companion-desktop project: independent music, notch controls, a local media library and explicit playback/state boundaries. This is not an official BSide product and includes no official media, artwork, app binaries or user runtime state.

## Build and check

Requirements: macOS 13+ and a compatible Swift 5.9+ toolchain. The Swift package declares no external package dependencies. Source gates (run from this directory):

```sh
swift build
scripts/run_tests.sh
scripts/check_architecture.sh
```

Tests use an in-house runner under `Sources/BSideTestRunner`, plus the control executable's explicit `--verify-control-state` verification mode; the script isolates test preferences/logs in a temporary support directory. It does not install or normally launch an app. Optional real-catalog acceptance requires separately provided local evidence and is skipped when its documented environment input is absent. Empty `Tests/` is retained for the existing architecture script's search boundary.

Four boundaries remain: pure `BSideCore`, macOS `BSidePlatform`, restartable `BSideWallpaperAgent`, and state-owning `BSideControlApp`. Playback/media stay in the execution/platform layers; versioned newline-delimited JSON carries IPC. Preferences are local. No new architecture is introduced by this export.

## Media and packaging limitations

Users must lawfully possess and explicitly select their own compatible media. Media, upstream reference clones, the unlicensed local notch artwork, screenshots and personal state are excluded. The required bundled performance catalog contains metadata only; see THIRD_PARTY_NOTICES.md for its precise scope and rights limitation. Missing media fails validation; the export does not fabricate playable assets.

This package supports source builds/checks, not a prebuilt/notarized application or an app-installation recipe. Canonical packaging scripts that depend on external artwork and local installation state are deliberately excluded. The accepted daily source includes Home navigation and the reproduced notch hover-retraction fix; this export has not been installed or physically reaccepted. Cancelled spatial-desktop experiments are not a new delivery. No performance-improvement or universal hardware/OS acceptance claim is made.

## Source and licensing status

The implementation source corresponds to accepted runtime commit `27c1584ac7273413555ddb546c116375c3add7e7`, taken from documentation-only successor `e3b399ac46aa1d4db02297afe578ab9569da4b6e`. Local private handoffs, operation history and Git history are not included. EXPORT_MANIFEST.json records explicit included files, hashes and the export-only synthetic HOME fixture substitution.

No license for original project code has been selected. Code availability is not a grant of open-source rights. Actual Atoll-derived portions retain their complete MIT attribution/notice; that notice does not license the whole project or BSide media. Repository: https://github.com/myconstance1999-pixel/bsideyou.
