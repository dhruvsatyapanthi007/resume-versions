# Resume Versions

A small native macOS app (SwiftUI + PDFKit, no dependencies) for browsing versioned resume snapshots.

The PDF and its `CHANGES.txt` are on the left; the version tree is in a sidebar on the right.

## What it does

- Scans `versions/` next to the app for folders named `vNN_YYYY-MM-DD_label`, each with a `CHANGES.txt` and one or more PDFs.
- Builds a version tree from the `Base: vNN` line in each `CHANGES.txt` (v01 is the root, v02 sits under v01, anything else without a Base line sits under v02). Folders that share a number are kept apart by their full folder name.
- Pins the current main resume (`Dhruv_Resume.pdf` in the root folder) at the top.
- Shows the selected PDF (zoomable) with its `CHANGES.txt` above it, and a 1-page / 2-page toggle when a version has both (any PDF whose name contains `2Page` counts as the 2-page one).
- Filters by company or label, moves with the arrow keys (↑/↓ move, ←/→ collapse/expand), and has **Show in Finder** / **Open in Preview** buttons.
- Watches the folder with FSEvents, so new or renamed versions appear without restarting.
- Reads files only; it never writes to `versions/`.

## Expected layout

```
Resume/
├── Resume Versions.app
├── Dhruv_Resume.pdf            # current main (pinned)
└── versions/
    ├── v01_2026-11-03_reviewer-feedback/
    │   ├── CHANGES.txt
    │   ├── Dhruv_Resume_1Page.pdf
    │   └── Dhruv_Satyapanthi_Resume_2Page.pdf
    └── v02_2026-11-03_final-before-tailoring/
        └── ...
```

The app looks for `versions/` beside itself first, then `~/Documents/Resume`. Pass `--root <folder>` to point it somewhere else.

## Build

Needs only the Xcode Command Line Tools (Swift 5.9+), macOS 14 or later.

```bash
./build.sh
```

This writes `~/Documents/Resume/Resume Versions.app` (ad-hoc signed). Edit `APP` in `build.sh` to put it somewhere else.

## Self-test

```bash
"Resume Versions.app/Contents/MacOS/ResumeVersions" --selftest
```

Prints the version tree, then selects every version and PDF and checks that the PDF view loaded the file from that version's own folder. Set `SNAPSHOT_DIR=/some/folder` to also save a PNG of the window for each step.

## Files

- `Sources/Scanner.swift`: read-only folder scan, parent resolution, PDF classification
- `Sources/Model.swift`: app state, FSEvents watcher, keyboard navigation, self-test
- `Sources/Views.swift`: SwiftUI UI and the PDFKit wrapper
