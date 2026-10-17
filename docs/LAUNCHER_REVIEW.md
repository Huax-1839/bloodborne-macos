# Launcher "Hunter's Lantern": code review 2026-10-18

Review of everything under `launcher/` (LanternCore, the SwiftUI app, packaging) and
`.github/workflows/`, at commit `648ac34`. Plan and decisions: `docs/LAUNCHER_PLAN.md`.

How to use this file:
- Each finding has an id (R1–R20), the place (file, symbol, line at `648ac34`; lines drift, the
  symbol does not), what goes wrong, the fix and the test that proves it.
- Fix in the batch order below. Tick the box in the checklist when the fix is committed (with the
  commit), and keep the finding text as the record.
- Verified: R1 and R2 were reproduced with small drivers compiled against the real sources (see
  each finding). The others are from reading the code.

## Checklist

Batch A, data safety (first, each with a test):
- [ ] R1 backup restore deletes the backup it restores
- [ ] R2 a missing JSON field loses profiles, games and settings
- [ ] R5 orphaned multi-GB folders in the data folder
- [ ] R18 automatic backups rotate even when nothing changed

Batch B, correctness and UX:
- [ ] R3 PKG tool run on every redraw, on the main thread
- [ ] R11 Stop does not stop a launch that is preparing
- [ ] R10 a removed game comes back after its thorough check
- [ ] R12 "Add game folder" does not find the app folder inside the chosen one
- [ ] R14 stale import progress updates
- [ ] R13 `FileHandle.write(_:)` crashes on a write error
- [ ] R15 pipe handlers spin at end of output
- [ ] R9 profile ini keys carry over to the next profile

Batch C, hardening before the first release tag:
- [ ] R4 imported profiles can set any environment variable
- [ ] R6 the one-game lock is taken too late
- [ ] R7 quitting the launcher while the game runs
- [ ] R8 no license texts in the app and the DMG
- [ ] R20 CI hardening, no Sparkle deltas

Cleanup:
- [ ] R16 English-only and raw error texts
- [ ] R17 deleting a profile with own saves hides them
- [ ] R19 two sources for the launch environment

Ruled out during the review (no action):
- ZIP path traversal in mod and save imports: `ditto -x -k` keeps `../` entries inside the target
  folder and writes symlink entries as regular files (tested with crafted archives).

## High

### R1 Restoring the oldest automatic backup deletes it, then the restore fails

- Where: `LanternCore/BackupStore.swift`, `restore(_:userRoot:)` (l. 45–57), which calls
  `backUpBeforeLaunch` (l. 48) → `prune()` (l. 80).
- What: the safety backup taken before the restore trims the automatic backups to 10. With 10
  already there, the oldest is deleted; when that is the one being restored, `cloneTree` then
  fails. The UI promises "you can undo this".
- Reproduced: 10 automatic backups, restore the oldest → `NSPOSIXErrorDomain Code=2 "No such file
  or directory"`, the backup folder is gone.
- Fix: clone the chosen backup into the staging folder first; then take the safety backup with a
  prune that never removes `backup.url` (e.g. `prune(keeping:)`); then swap staging into place.
- Test (`BackupStoreTests`): 10 automatic backups with distinct contents, restore the oldest →
  the save holds the oldest contents and the restored backup still exists.

## Medium

### R2 A missing JSON field loses profiles, games and settings

- Where: `Profile` (`LanternCore/Profile.swift` l. 34), `LauncherState` (`LauncherState.swift`
  l. 15), `LauncherSettings` (`LaunchSpec.swift` l. 5), `Game`/`Game.ThoroughCheck`/`GameCheck`
  (`GameLibrary.swift`, `Pipeline.swift`); loaders `ProfileStore.init` (l. 11),
  `LauncherState.load` (l. 15), `GameLibrary.init` (l. 52); `AppModel.state` didSet (l. 17).
- What: synthesized `Decodable` requires every non-optional key, default values or not.
  - `ProfileStore` drops a profile that fails to decode (`compactMap { try? }`): it vanishes
    from the list.
  - `launcher.json` and `games.json` fall back to empty; the next save overwrites the file, so
    the game list and the settings are lost.
  - Triggers: the first update that adds a non-optional field, a downgrade, importing a profile
    exported by another version, a hand-edited file.
- Reproduced: a `Profile` JSON without `ownSaves` → `DecodingError.keyNotFound`.
- Fix: hand-written `init(from:)` with `decodeIfPresent(...) ?? default` for every field with a
  default (or one small `@Default` property wrapper). A file that cannot be decoded is renamed to
  `<file>.unreadable-<date>` and reported, never overwritten.
- Test: decode `{"id":"x","name":"y"}` as a `Profile`; decode a `games.json` entry without
  `managed`; a corrupt `games.json` is kept aside, not overwritten.

### R3 The PKG sheet runs the PKG tool on every redraw, on the main thread

- Where: `HuntersLantern/Views/GameView.swift` `PKGSheet.tool` (l. 334, used l. 327, 342, 352)
  → `AppModel.pkgToolDescription`/`pkgTool` (`AppModel.swift` l. 103–111) →
  `PkgTool.validate` → `helpText` (`LanternCore/PkgTool.swift` l. 186–217).
- What: with a chosen tool (`state.pkgToolPath`), every evaluation spawns `<tool> --help` (and
  maybe `-h`) and polls with `Thread.sleep` for up to 5 s each. Three evaluations per redraw, and
  the sheet redraws on any `AppModel` change. Without a chosen tool, `PkgTool.detect()` scans
  PATH and /Applications on each evaluation. `choosePKGTool` also validates on the main thread.
- Fix: validate once, off the main actor; keep `@Published var pkgTool: PkgTool?` in `AppModel`,
  refreshed when the sheet opens and when a tool is chosen. Make `helpText` async on
  `ProcessRunner` with a timeout instead of the sleep loop.
- Test: unit test for the async `validate` with a script that sleeps past the timeout
  (`PkgToolTests`); UI: the sheet opens and redraws without spawning processes (check with
  `log stream` or a counter in a debug build).

### R4 Imported profiles can set any environment variable

- Where: `ProfileStore.importProfile` (`ProfileStore.swift` l. 52); applied unfiltered in
  `LaunchSpec.make` (`LaunchSpecBuilder.swift` l. 38), `BB_PROBE` picks the executable (l. 115);
  the name check exists only in the UI (`AdvancedView.swift` `ExpertVariables.validName`, l. 127).
- What: profiles are made to be shared (Export/Import). An imported profile can set
  `DYLD_INSERT_LIBRARIES` (the game app has no hardened runtime, D14), `BB_PROBE` (any program
  is started on Play), `BB_CONFIG` (where the game writes its ini) or `BB_USER_DIR`.
- Fix: one validator in LanternCore (`BB_`/`MVK_`/`ROSETTA_`, capitals, digits, `_`), used by
  the Advanced page, by import and by `LaunchSpec.make`. On import, show the profile's expert
  variables and ask; refuse `BB_PROBE`, `BB_CONFIG`, `BB_USER_DIR`, `BB_GPU_USER_DIR` from an
  imported file.
- Test: importing a profile with `DYLD_INSERT_LIBRARIES` and `BB_PROBE` → neither reaches
  `LaunchSpec.environment` nor the executable (`LaunchSpecTests`, `ProfileTests`).

### R5 Orphaned multi-GB folders in the data folder

- Where:
  - path (b) `AppModel.importBaseAndUpdate` (`AppModel.swift` l. 70–85): the check after the
    merge can throw or be cancelled; the merged folder stays, unregistered (on another volume a
    full ~30 GB copy);
  - `GameImporter.importPKGs` (`PkgTool.swift` l. 309–310): the hidden `games/.import-<uuid>`
    (~30 GB) is removed only by `defer`, so a crash or force-quit leaves it;
  - `importPKGs` without an update (API only, l. 314–319): a failing check leaves the moved
    folder, and the folder is named `<title>-1.09` although it is a base game;
  - `AppModel.removeGame` (l. 185): `prepared/<title>-<hash>/` is never removed.
- Fix: in path (b) remove the destination when the check throws or is cancelled (as the PKG path
  does). On app start, delete leftover `games/.import-*`, `mods/.import-*`,
  `<user root>/.save-import-*`, `.savedata-restore`, `.savedata-migrate`. Removing a game also
  removes its prepared folder when no other registered game has the same title and hash.
- Test: `GameImporterTests` with a failing pipeline check → no folder left in `gamesDir`; a
  cleanup function test with planted leftovers.

### R6 The one-game lock is taken too late

- Where: `Launcher.launch` (`Launcher.swift` l. 62–102): backup, `bbport.ini` write,
  `patches.json`, mod overlay and prepare all run before `GameProcess.start()` takes the lock
  (`GameProcess.swift` l. 130).
- What: a second running copy of the app (one from the DMG, one from /Applications) can rewrite
  the shared ini and the prepared folder while the first one's game runs. Its start is then
  refused, but the first instance may take the second's keys into its profile as "changed in
  game" (D7). Between restarts the lock is also briefly free.
- Fix: take the lock at the start of `launch()` and hold it across the restart loop; give
  `GameProcess` the held lock (or an option that it is already held).
- Test: two `Launcher`s on one data dir with a stub pipeline; the second fails before touching
  the ini (`LauncherTests`).

### R7 Quitting the launcher while the game runs is not handled

- Where: `HuntersLanternApp.swift` (no app delegate), `Updater.swift` l. 21
  (`updaterDelegate: nil`).
- What: on Cmd-Q the game keeps running without its launcher: the in-game setting changes are
  not taken into the profile, the outcome card is lost. Sparkle may install an update on quit
  into the bundle the game runs from, and a scheduled update check can bring up its dialog during
  play.
- Fix: `@NSApplicationDelegateAdaptor` with `applicationShouldTerminate`: while `isBusy`, ask
  "Stop the game and quit" / "Keep running". A Sparkle updater delegate that refuses scheduled
  checks and installs while a game runs.
- Test: manual (start the game, Cmd-Q the launcher); Sparkle: a local appcast as in L6 while the
  game runs → no dialog until it ends.

### R8 No license texts in the app and the DMG

- Where: `launcher/build.sh`, `launcher/package.sh`, `launcher/packaging/fetch-python.sh`
  (prunes `share/`), About page (`AboutView.swift`).
- What: the bundle ships Sparkle (MIT), MoltenVK (Apache-2.0), SDL3 (zlib), CPython (PSF, plus
  the libraries python-build-standalone links) and our GPL-2.0-or-later code, but no license
  text. GPL §1 and the MIT/Apache terms ask for the texts with the binaries.
- Fix: copy `LICENSE` and the third-party license files into
  `Contents/Resources/Licenses/` and the DMG; a "Licenses" button on the About page. Do this
  before the first tag `v0.9.0`.
- Test: `build.sh --bundle` fails when a license file is missing (like the German-strings check).

## Low

### R9 Profile ini keys carry over to the next profile

- Where: `Launcher.launch` (`Launcher.swift` l. 78–81), `Profile.iniKeys` (`Profile.swift`
  l. 71), presets l. 82–123.
- What: `iniValues` a profile writes stay in the shared `bbport.ini` for the next profile that
  does not set them. After Max, Vanilla starts with `preset=0` and `upscaler=metalfx`: not "the
  defaults" (D16), and a profile is not the complete package D7 describes. ("Keep the game's
  setting" for unset keys is intended for user profiles; the presets are the problem.)
- Fix: built-in presets set every display key they depend on (Vanilla: the game's default
  upscaler and preset). Optionally store the keys the last launch wrote in `launcher.json` and
  remove the ones the new profile does not set.
- Test: `LauncherTests`: launch Max, then Vanilla with a stub pipeline → the ini has Vanilla's
  values.

### R10 A removed game comes back after its thorough check

- Where: `AppModel.runThoroughCheck` (`AppModel.swift` l. 122–134) → `GameLibrary.update`
  (`GameLibrary.swift` l. 68, falls back to `add`); Remove button `GameView.swift` l. 83.
- Fix: at the end, update only when the library still has the game with the same path; disable
  Remove for the game under check.

### R11 Stop does not stop a launch that is preparing

- Where: `Launcher.cancel` (`Launcher.swift` l. 53–60), `launch` l. 98–103; `AppModel.stop`
  (l. 271), the launch `Task` in `play()` is not kept.
- What: `cancel()` only sets a flag while pipeline steps run, so they run to the end. A Stop
  between `process.start()` and `current = process` is lost (the game keeps running).
- Fix: keep the launch `Task` in `AppModel` and cancel it in `stop()` (`ProcessRunner` already
  terminates the running step); in `launch`, check `isCancelled` right after setting `current`
  and cancel the process.

### R12 "Add game folder" does not find the app folder inside the chosen one

- Where: `AppModel.importFolder` (`AppModel.swift` l. 50–55).
- What: path (b) uses `GameFolder.locate`, path (a) does not: choosing the folder that holds
  `CUSA03173/` fails with "not a PS4 game".
- Fix: `GameFolder.locate(url) ?? url`.

### R13 `FileHandle.write(_:)` crashes on a write error

- Where: `OutputCollector.add` (`PythonPipeline.swift` l. 145), `Launcher.prepare`
  (`Launcher.swift` l. 160).
- What: the old API raises an Objective-C exception (disk full, closed handle): the app crashes
  instead of reporting an error.
- Fix: `try? handle.write(contentsOf:)` (or `try` where the error should surface).

### R14 Stale import progress updates

- Where: `AppModel.importBaseAndUpdate` (l. 80), `importPKGs` (l. 96).
- What: progress arrives as unordered `Task { @MainActor … }` without a guard and can overwrite
  "Checking the game…" or set a status after the import ended. `runThoroughCheck` already guards
  (`if self.thoroughProgress != nil`).
- Fix: the same guard (or a generation counter per import).

### R15 Pipe handlers spin at end of output

- Where: `ProcessRunner.run` (`PythonPipeline.swift` l. 102–103).
- What: at EOF the `readabilityHandler` is called again and again with empty data until the
  termination handler clears it.
- Fix: in the handler, `if data.isEmpty { handle.readabilityHandler = nil }`.

### R16 English-only and raw error texts

- Where: `GameProcessError`, `LaunchError`, `PipelineError`, `Runtime.LocateError`, the
  Gatekeeper hint (`PythonPipeline.swift` l. 73); `AppModel.play` (l. 265) and
  `showRuntimeError` (l. 317) use `String(describing:)`.
- What: German users get English texts for the most important first-start error ("Open
  Anyway"); other errors show raw `NSError` dumps.
- Fix: make them `LocalizedError` with String Catalog entries like `ImportError`; use
  `localizedDescription` everywhere.

### R17 Deleting a profile with own saves hides them

- Where: `AppModel.deleteProfile` (l. 210), dialog `ProfilesView.swift` l. 31.
- What: `profile-users/<id>` and `backups/<id>` stay in the data folder, unreachable from the
  app; the dialog says only "This cannot be undone".
- Fix: for an own-saves profile, say where the saves stay, or offer export / move to Trash.

### R18 Automatic backups rotate even when nothing changed

- Where: `BackupStore.backUpBeforeLaunch` (`BackupStore.swift` l. 30).
- What: 10 quick launches (e.g. while chasing a crash) push the last good state out.
- Fix: skip the backup when the save tree's fingerprint (paths, sizes, mtimes) equals the newest
  automatic backup's; optionally keep one per day for a week on top of the last 10.
- Test: two launches without a save change → one backup.

### R19 Two sources for the launch environment

- Where: `GameProcess.start` (`GameProcess.swift` l. 148) passes the launcher's whole
  environment; `Launcher.launch` calls `LaunchSpec.make(inputs)` with an empty
  `baseEnvironment` (`Launcher.swift` l. 97).
- What: `BB_*` variables in the launcher's environment reach the game but not the spec's
  decisions (e.g. the `patches.py` arguments): against D5's one contract. Variables the spec
  removes (`BB_AUTO_RENDER_RES` and friends) come back from the inherited environment.
- Fix: pass `ProcessInfo.processInfo.environment` as `baseEnvironment`, or strip
  `BB_`/`MVK_`/`ROSETTA_` from what `GameProcess` and the pipeline inherit.

### R20 CI hardening, no Sparkle deltas

- Where: `.github/workflows/release.yml`, `ci.yml`, `launcher/packaging/appcast.sh` l. 24.
- What: actions pinned by tag, not commit SHA, in the job that holds `SPARKLE_ED_KEY` and
  `contents: write`; `ci.yml` has no `permissions` block; the appcast is built from the new DMG
  only, so there are no deltas although D13 promises them.
- Fix: pin by SHA, `permissions: contents: read` in `ci.yml`; deltas: give `generate_appcast`
  the previous release's DMG, or drop the promise from D13.

## Smaller improvements (not bugs)

- Reuse the stored quick check while `eboot.bin`'s size and mtime are unchanged: saves a Python
  start and an eboot hash per launch (`Launcher.launch` l. 67).
- `Window` instead of `WindowGroup` (`HuntersLanternApp.swift`): Cmd-N opens a second window
  with duplicate polling tasks.
- Turning on "Own saves" for a profile starts with an empty save: offer to copy the shared saves.
- `build.sh --bundle` builds the runtime only when `macos/out/bb-probe` is missing: a stale
  local `macos/out` gets packaged (CI is fresh).
