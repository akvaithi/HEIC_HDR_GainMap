# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [2.0.0] — 2026-06-21

First release as a proper, combined plugin. Forked from
[fengshenx/LR_GainMap_HDR_Export_Plugin](https://github.com/fengshenx/LR_GainMap_HDR_Export_Plugin)
(plugin) and [chemharuka/toGainMapHDR](https://github.com/chemharuka/toGainMapHDR) (engine).

### Packaging
- Renamed the bundle from `export_heic.lrdevplugin` to **`HEIC_HDR_GainMap.lrplugin`**
  (released extension instead of the dev one).
- Rebranded `Info.lua`: name *HEIC HDR Gain Map Exporter*, identifier
  `com.akvaithi.heichdrgainmap`, version 2.0.0, info URL set.
- Added `CLAUDE.md`, `CHANGELOG.md`; build artifacts (`*.dmg`, `*.zip`) now git-ignored;
  added a `make zip` target.

### Engine
- Updated the bundled engine from its Sep-2025 snapshot to **toGainMapHDR v3.3.1**
  (reworked luminance/gamma gain-map algorithm, RGB/ISO gain-map path, XMP metadata
  system, subsampled-`-H` channel-metadata fix).
- Rebuilt the universal (arm64 + x86_64) binary and both `.metallib` shaders **from source**.

### Output format
- Switched the export from Apple's proprietary `-g` gain map (8-bit) to **ISO 21496-1**,
  **10-bit (HEVC Main 10)**, full-resolution RGB gain map (`-d 10`). This is the native
  modern standard on iOS 18 / macOS 15+. Older Apple devices fall back to the SDR base.

### Workflow
- Auto-configures the intermediary on every export: **TIFF, 16-bit, HDR Output on,
  Maximize Compatibility off**. **Color Space (gamut) stays user-selectable.**
- Added an in-dialog reminder note (Lightroom does not let plugins redraw the built-in
  File Settings widgets, so they may look unset even though the export uses the forced
  values).
- Raised default Image Quality from 70 to **85** (HDR-highlight sweet spot).
- Removed the **SIPS** encoder option — this is a true HDR-only workflow.

### Apple Photos
- New option to **import each exported HEIC into a Photos album** (created if missing),
  batched into a single import (one Automation prompt).
- After a successful import, the export-folder copy is **deleted**; kept if the import
  fails so nothing is lost.

### Docs
- Rewrote the README for the combined project, attribution, build, and usage.
