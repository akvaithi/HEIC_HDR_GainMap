# CLAUDE.md

Guidance for AI coding assistants working in this repository.

## What this is

A macOS-only **Lightroom Classic export plugin** that produces **HDR HEIC** images with a
gain map. It is a *combined* repo merging two upstreams:

- **Engine** — `chemharuka/toGainMapHDR` (Swift CLI, the gain-map converter). Lives at repo
  root: `main.swift`, `CustomFilter/`, `Resource/`. Currently synced to upstream **v3.3.1**.
- **Plugin** — `fengshenx/LR_GainMap_HDR_Export_Plugin` (the Lua export service). Lives in
  `HEIC_HDR_GainMap.lrplugin/`.

The `.lrplugin` bundle ships a **compiled** copy of the engine (`toGainMapHDR` universal
binary + two `.metallib` shaders). The plugin invokes it once per photo via
`LrTasks.execute`.

## Architecture / data flow

1. Lightroom renders each photo to a **16-bit, HDR, lossless TIFF** intermediary (forced by
   the plugin — see below).
2. The plugin calls `toGainMapHDR <tiff> <destFolder> -q <quality> -d 10`.
3. The engine writes a **10-bit (HEVC Main 10) HEIC** with a full-resolution **ISO 21496-1**
   adaptive gain map (the engine's *default* path; `-d 10` selects 10-bit).
4. The plugin deletes the TIFF; optionally imports the HEIC into Apple Photos and then
   deletes the export-folder copy.

The engine's `-g` flag (Apple proprietary `MakerApple` gain map) is **not** used — we
deliberately ship ISO 21496-1. See CHANGELOG for the rationale.

## Build

Requires Xcode + the **Metal Toolchain** component (`xcodebuild -downloadComponent
MetalToolchain`, needs admin). Then:

```sh
make              # compiles shaders + universal Swift binary into the .lrplugin
make SIGN_ID=- …  # ad-hoc sign (use for local installs)
make dmg / zip    # package; make install -> copy into LRC Modules dir
make help         # all targets
```

`swiftc` builds without the Metal Toolchain; only the `.metal` -> `.metallib` step needs it.
If unavailable, the committed `.metallib`s (matching the `.metal` sources) can be reused.

## Conventions & gotchas

- **Lua syntax check** (no Lightroom needed): `luajit -bl HEIC_HDR_GainMap.lrplugin/ExportServiceProvider.lua /dev/null`
- **Forced export settings:** `ExportServiceProvider.lua` → `updateExportSettings` forces
  `LR_format=TIFF`, `LR_export_bitDepth=16`, `LR_export_useHDR=true`,
  `LR_export_maximizeCompatibility=false`. **Color space is intentionally NOT forced** (user
  picks the gamut). Verified key names via a runtime dump.
- **You cannot drive Lightroom's built-in File Settings widgets from a plugin.** Attempts to
  set/observe `LR_*` keys to visually "lock" the controls do nothing in the UI — that's why
  the dialog shows an explanatory note instead. The export still uses the forced values.
- **Engine flags the plugin relies on:** only `-q` (quality 0–1) and `-d 10`. Both are stable
  across engine versions. Other flags (`-g`, `-m`, `-H`, `-R`, `-r`, `-b`, `-p`, `-h`) exist
  but are unused by the plugin.
- **Apple Photos import** uses `osascript` (AppleScript). Needs Automation permission
  (System Settings → Privacy & Security → Automation). User strings are escaped for both
  AppleScript and the shell.
- **Platform reality:** Android cannot display HEIC gain maps (only Ultra HDR JPEG / AVIF);
  pre-Sequoia Apple devices fall back to the SDR base. This is a decoder limitation, not a
  bug. Don't "fix" it by switching formats without discussing the trade-offs.

## Verifying output

Inspect a produced HEIC with `libheif` (`brew install libheif`):
```sh
heif-info out.heic          # bit depth, chroma (expect 10-bit, 4:2:0)
```
Or check the auxiliary gain map type via ImageIO (`kCGImageAuxiliaryDataTypeISOGainMap`).

## Releasing

Bump `VERSION` in `HEIC_HDR_GainMap.lrplugin/Info.lua`, update `CHANGELOG.md`, then
`make dmg` / `make zip`. DMG/zip are git-ignored build artifacts.
