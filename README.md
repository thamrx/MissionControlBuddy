# MissionControlBuddy

**Enhances the *native* macOS Mission Control** (Control+Up / three finger swipe up) by
overlaying each window thumbnail with its **app icon, app name, and window
title** — so you can find the window you want at a glance.

This is **not** a Mission Control clone. It watches for the real, Apple-provided
Mission Control and draws labels on top of the actual thumbnails.


Download: <https://github.com/namchind/MissionControlBuddy/releases/download/1.0.2/MissionControlBuddy-v1.0.2-Installer.dmg>

---

## Features

- 🪟 Icon + app name + window title chip on every Mission Control thumbnail
- 🎯 Correctly resolves apps even with truncated / decorated titles (incl. Chrome)
- 🎛️ **Preferences**: chip size, background color, opacity, long-text wrap/cut, max title length
- 🚀 **Launch at login** (when installed as an app bundle)
- ⚡ Smart show/hide: appears only when Mission Control is fully open & settled,
  stays hidden during partial swipes and open/close animations
- 🖱️ Click-through overlays — Mission Control keeps working normally

---

## Requirements

- macOS 13 (Ventura) or later
- Swift 6 toolchain (Xcode 16 / Command Line Tools) to build
- **Accessibility permission** (required — that's how we read the thumbnails)

---

## Installation

### Option A — Install as an app (recommended)

This gives you a stable Accessibility entry and enables **Launch at Login**.

```bash
cd MissionControlBuddy
./build_app.sh --install
```

Then:
1. Open **MissionControlBuddy** from `/Applications` (or Spotlight).
2. When prompted, grant **Accessibility**:
   System Settings → Privacy & Security → Accessibility → enable
   **MissionControlBuddy**.
3. Quit and relaunch once so the permission takes effect.
4. Trigger Mission Control (Control+Up or three finger swipe up) — the chips appear. 🎉

To build the app without installing, just run `./build_app.sh`
(output lands in `dist/MissionControlBuddy.app`).

### Option B — Run from source (quick dev loop)

```bash
cd MissionControlBuddy
swift run
```

Grant Accessibility to your **terminal** (System Settings → Privacy & Security →
Accessibility) and relaunch. Note: "Launch at Login" does **not** work in this
mode — use Option A for that.

---

## Usage

- The app lives in the **menu bar** (no Dock icon).
- Click the menu bar icon for:
  - **Enable / Disable Overlays**
  - **Preferences…** (⌘,)
  - **Launch at Login**
  - **Hide Menu Bar Icon**
  - **About**, **Quit**

If you hide the menu bar icon, open MissionControlBuddy again from Spotlight /
Applications to bring back the **Preferences** window (control surface).

### Preferences

| Setting | What it does |
|---------|--------------|
| **Chip size** | Scales icon + text + padding (60%–180%) |
| **Background** | Chip background color (color picker) |
| **Opacity** | Chip background opacity (0–100%) |
| **Long text** | `Cut with …` (truncate) or `Wrap (2 lines)` |
| **Enable overlays** | Runtime on/off switch for Mission Control chips |
| **Launch at login** | Start automatically at login (app bundle only) |
| **Show menu bar icon** | Show/hide status item; when hidden, relaunch app to open Preferences |
| **Restore Defaults** | Reset all settings back to defaults |
| **Quit button** | Stop the app even when menu bar icon is hidden |

Changes apply live to the next Mission Control open.

---

## How it works

Two diagnostic probes established what's possible:

- `MissionControlProbe.swift` — proved thumbnails are **not** separate windows
  in the public window list (they're painted inside one big Dock window).
- `MissionControlAXProbe.swift` / `MissionControlAttrProbe.swift` /
  `AppWindowTitlesProbe.swift` — proved the Dock exposes every thumbnail as an
  `AXButton` (rect + title) under an `AXGroup` titled `"Mission Control"`, and
  showed how titles are truncated/decorated (the key to app resolution).

So the app:

1. Polls the Dock's Accessibility tree (~16 Hz).
2. When the `"Mission Control"` group appears **and the layout is stable and
   grid-like**, reads all thumbnail buttons (rect + title).
3. Resolves each title → owning app → **icon + name** by matching against each
   running app's AX window titles (exact, middle-ellipsis, and prefix matching).
4. Parks a **borderless, click-through** overlay chip on each thumbnail at a
   high window level so it floats above Mission Control.
5. Tears the overlays down the instant the layout changes (dismiss / swipe /
   animation).

---

## ⚠️ Experimental caveats

- Floating above Mission Control uses a high window level
  (`.assistiveTechHighWindow`). See `ThumbnailOverlay.swift` to tweak.
- Relies on the Dock's Accessibility structure, which Apple can change between
  macOS releases.
- Ad-hoc signed / personal-use utility.

---

## Project layout

| File | Role |
|------|------|
| `DockAXReader.swift` | Reads MC thumbnails from the Dock AX tree |
| `IconResolver.swift` | Maps thumbnail title → app icon + name |
| `ThumbnailOverlay.swift` | Borderless click-through chip window + styling |
| `MissionControlEnhancer.swift` | Watcher, stability/render gate, coord flip |
| `Preferences.swift` | UserDefaults-backed settings + color helpers |
| `PreferencesWindowController.swift` | Settings UI window |
| `LoginItem.swift` | Launch-at-login via SMAppService |
| `StatusBarController.swift` | Menu bar UI |
| `AppDelegate.swift` | Startup + Accessibility prompt |
| `build_app.sh` | Builds/install the `.app` bundle |
| `make_icon.swift` | Generates `Resources/AppIcon.icns` |
| `*Probe.swift` | Diagnostics used to reverse-engineer MC |

---

## Release Notes

### 1.0.2

- **Fixed: secondary-monitor windows had no chips**  
  Regression from 1.0.1. The empty-title fix added a `minY >= 0` guard to the
  Dock AX reader to drop off-screen chrome. But on a multi-monitor setup, any
  display placed **above/left** of the primary reports thumbnails at **negative**
  AX coordinates — so that guard silently discarded every window on secondary
  monitors. The guard was also redundant: the add-desktop button lives *inside*
  the `"Spaces Bar"` group, which we already skip. Removed the guard; all
  monitors get chips again. (Coordinate flip already anchors to the primary
  screen, so negative AX Y maps correctly across displays.)

### 1.0.1

- **TablePlus / untitled windows now get chips**  
  Mission Control thumbnails whose AX button has an empty title (e.g. some
  TablePlus windows) are no longer ignored. We now:
  - keep empty-title thumbnail buttons in the Dock AX reader, and
  - resolve their owning app by matching the thumbnail's aspect ratio against
    real app windows via Accessibility.
  Result: even title-less windows get a proper app icon + name chip.

- **Preferences window chip shows the correct icon**  
  `IconResolver.refresh()` now includes our own process even though it's a
  `.accessory` app (menu bar utility), so the Mission Control thumbnail for the
  **MissionControlBuddy Preferences** window shows the MissionControlBuddy app
  icon instead of being blank.

- **Single-instance behavior**  
  On launch, MissionControlBuddy now detects and terminates any older running
  instance (by bundle identifier / executable), so you never end up with two
  menu bar puppies fighting over Mission Control.

- **Clearer Close vs Quit in Preferences**  
  The bottom-right buttons are now:
  - **Close (keep running)** — green checkmark; closes Preferences only.
  - **Quit App** — red x-mark; terminates MissionControlBuddy entirely.  
  This makes "keep running" vs "actually quit" visually obvious.

### 1.0.0

- Initial public release.
- Mission Control thumbnail chips with app icon + name + window title.
- Preferences UI, launch-at-login support, and basic stability heuristics.
