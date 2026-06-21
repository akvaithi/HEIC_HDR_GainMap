# HEIC HDR Gain Map — Lightroom Classic Export Plugin (engine-updated build)

A Lightroom Classic plugin that exports **Gain Map HDR HEIF** images, bundled together
with the **conversion engine** in a single repository.

Lightroom Classic 14.0+ can export HDR HEIC, but it does **not** write a gain map, which
causes compatibility problems on Android and other non-Apple viewers. This plugin fixes
that by post-processing the exported file through the `toGainMapHDR` engine to produce a
proper Apple gain map HDR HEIC.

> **Note:** macOS only. Built and tested against Lightroom Classic 14.0+ / macOS 15.

---

## What this repo is

This is a **combined** repository that merges two upstream projects:

| Component | Upstream | Role |
|-----------|----------|------|
| Lightroom plugin (`export_heic.lrdevplugin/`, `Makefile`) | [fengshenx/LR_GainMap_HDR_Export_Plugin](https://github.com/fengshenx/LR_GainMap_HDR_Export_Plugin) | The LRC export service plugin (Lua) |
| Conversion engine (`main.swift`, `CustomFilter/`, `Resource/`) | [chemharuka/toGainMapHDR](https://github.com/chemharuka/toGainMapHDR) | The `toGainMapHDR` command-line converter |

The plugin bundles a compiled copy of the engine. The original plugin shipped an engine
snapshot from **September 2025**; this repository updates that engine to
**chemharuka/toGainMapHDR v3.3.1 (June 2026)**, which includes:

- a reworked Apple gain map algorithm (luminance-based, gamma-encoded gain map);
- the new RGB / ISO gain map path and `RGBGainMapKernel`;
- the XMP gain-map metadata system (`Resource/Metadata.swift`);
- the subsampled (`-H`) ISO gain map channel-metadata fix;
- minimum macOS bumped in line with upstream.

The plugin invokes the engine as `toGainMapHDR <src> <dst> -q <quality> -d 10`, which
produces a **10-bit (HEVC Main 10) base image** with a full-resolution **ISO 21496-1
adaptive gain map** (`urn:iso:std:iso-ts:21496:-1:gainmap`) — the modern standard used by
Apple's native pipeline since iOS 18 / macOS Sequoia. Earlier builds used `-g` (Apple's
proprietary `MakerApple` gain map, 8-bit); see the project history for that change.

---

## Repository layout

```
.
├── main.swift                       # engine entry point (chemharuka 3.3.1)
├── CustomFilter/                    # CoreImage gain map kernels + filters
│   ├── GainMapFilter.swift
│   ├── GainMapKernel.ci.metal
│   ├── RGBGainMapFilter.swift
│   └── RGBGainMapKernel.ci.metal
├── Resource/
│   └── Metadata.swift               # XMP gain-map metadata templates
├── export_heic.lrdevplugin/         # the Lightroom plugin (this is what you install)
│   ├── ExportServiceProvider.lua
│   ├── Info.lua
│   ├── toGainMapHDR                 # compiled universal (arm64 + x86_64) engine
│   ├── GainMapKernel.ci.metallib
│   └── RGBGainMapKernel.ci.metallib
├── Makefile
└── LICENSE                          # MIT (from chemharuka/toGainMapHDR)
```

---

## Install the plugin in Lightroom Classic

1. Open **File ▸ Plug-in Manager** in Lightroom Classic.
2. Click **Add**.
3. Select `export_heic.lrdevplugin` from this repository.

## How to use

1. Select your photo(s) and open the **Export** window.
2. At the top, choose **"Export to HEIC"**.
3. Export.

The plugin **auto-configures the intermediary** (16-bit, ProPhoto RGB, lossless TIFF, HDR
output on) so you don't have to touch the File Settings section — it forces the format the
HDR pipeline needs on every export. A runtime guard still warns if anything ends up wrong.

### Export dialog options

- **Image Quality** (default **85**) — the HEVC quality of the final HEIC. 85 is the HDR
  sweet spot; lower values introduce visible banding/blocking in highlights.
- **Encoder**:
  - *Gain Map HDR (recommended)* — the full pipeline: 10-bit HEIC with an ISO 21496-1 gain map.
  - *Plain HEIC – no HDR (macOS sips)* — a quick `sips` conversion with **no** gain map and
    **no** HDR. Only for when you want a plain SDR HEIC.
- **Apple Photos** — tick *Add exported HEIC to album* and name an album to import each result
  straight into Photos (the album is created if missing). macOS asks for permission to control
  Photos the first time; allow it under **System Settings ▸ Privacy & Security ▸ Automation**.

### Output format

Each exported file is a **10-bit (HEVC Main 10)** HEIC carrying a full-resolution
**ISO 21496-1 adaptive gain map** — the modern standard read natively on iOS 18 /
macOS 15 (Sequoia) and later. On older Apple systems and on Android (which only reads
HDR gain maps from UltraHDR JPEG, never HEIC), the file gracefully falls back to its
SDR base image.

---

## Build from source

The Swift engine builds with the command-line toolchain; compiling the CoreImage
`.metal` shaders additionally requires the **Metal Toolchain** Xcode component:

```sh
xcodebuild -downloadComponent MetalToolchain   # one-time, needs admin
make                                            # builds universal binary + metallibs into the plugin
make install                                    # optional: copy plugin into LRC Modules dir
```

If the Metal Toolchain is unavailable, the prebuilt `.metallib` shader libraries that
ship in `export_heic.lrdevplugin/` (taken from chemharuka/toGainMapHDR v3.3.1, matching
the `.metal` sources here) can be reused as-is; `make` will still recompile the Swift
binary from source.

The `Makefile` also provides `dmg`, `dist`, `adhoc`, `notarize`, `staple`, and `release`
targets — run `make help` for details.

---

## Credits & license

- Conversion engine: **Luyao Peng** — [chemharuka/toGainMapHDR](https://github.com/chemharuka/toGainMapHDR)
- Lightroom plugin: **@fengshenx** — [LR_GainMap_HDR_Export_Plugin](https://github.com/fengshenx/LR_GainMap_HDR_Export_Plugin)
- ISO gain map channel-metadata fix: @vastunghia (upstream PR #11)

Distributed under the MIT License (see [LICENSE](LICENSE)). This is an independent
combined build that is **not** affiliated with or endorsed by the upstream authors.
