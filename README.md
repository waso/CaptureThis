<p align="center">
  <img src="CaptureThis/CaptureThis/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="CaptureThis Logo" width="128" height="128">
</p>

<h1 align="center">CaptureThis</h1>

<p align="center">
  <strong>Professional screen recording & video editing for macOS</strong>
</p>

<p align="center">
  <a href="https://capturethis.dev">Website</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#installation">Installation</a> &bull;
  <a href="#usage">Usage</a> &bull;
  <a href="#building-from-source">Build</a> &bull;
  <a href="#license">License</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026.0%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-6-orange?style=flat-square" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/resolution-4K%2060fps-purple?style=flat-square" alt="4K 60fps">
</p>

---

CaptureThis is a native macOS screen recording application built for creators who need more than just a screen capture. Record your screen in **4K at 60fps**, overlay your **selfie camera**, **annotate on-screen** while recording, track every **mouse click** with intelligent zoom, and edit everything in a built-in **timeline editor** -- all without leaving the app.

Whether you're making tutorials, product demos, bug reports, or presentations, CaptureThis gives you a polished result straight out of the box.

## Features

### Screen Recording

- **4K 60fps capture** -- Record your entire display or a specific window at 3840x2160 resolution
- **Full-screen or window recording** -- Capture everything, or pick a single window with the Mission Control-style window selector
- **Multi-display support** -- Choose which monitor to record when using multiple displays
- **System audio capture** -- Record application audio alongside your microphone
- **Pause & resume** -- Pause recording at any time and pick up right where you left off
- **Floating recording controls** -- A minimal, draggable control panel stays on screen showing elapsed time with pause, stop, and mic toggle buttons

### Selfie Camera Overlay

- **Picture-in-picture webcam** -- Overlay your face on the recording using any connected camera
- **Camera selection** -- Switch between built-in and external cameras
- **Mirror toggle** -- Flip the selfie feed horizontally for a natural look
- **Drag & resize** -- Position and size the selfie overlay exactly where you want it
- **Composited into final video** -- The selfie overlay is rendered directly into the exported file

### Cursor Tracking

- **Three zoom modes:**
  - **No Zoom** -- Standard recording, no cursor tracking
  - **Zoom on Click** -- Automatically zooms into the area around each mouse click, then zooms back out
  - **Follow Mouse** -- The viewport dynamically follows your cursor with a smooth zoom
- **Click detection** -- Every left and right mouse click is captured with frame-accurate timestamps and used to drive zoom behavior
- **Click markers on timeline** -- Click events are displayed on the editor timeline so you can see exactly when clicks occurred

### On-Screen Drawing

- **Draw while recording** -- Hold the **Control** key and drag to draw directly on the screen with a red pen
- **Instant annotations** -- Highlight important areas, circle UI elements, or draw arrows in real-time
- **Clear with Escape** -- Press Escape to wipe the canvas and start fresh
- **Crosshair cursor** -- The cursor switches to a crosshair when drawing mode is active

### Built-In Video Editor

- **Timeline editor** -- A full timeline view with segment management for trimming your recording
- **Blade tool** -- Add cut points anywhere on the timeline to split your video into segments
- **Segment deletion** -- Remove unwanted sections with a click
- **Frame-accurate seeking** -- Scrub through your recording with precision
- **Real-time preview** -- See your edits applied instantly in the video player

### Post-Processing & Export

- **Custom backgrounds** -- Choose from 12 preset colors or pick your own, or use a background image
- **Border & framing** -- Add a configurable border (1-20pt) around your recording
- **Audio muting** -- Strip audio from the export with a single toggle
- **H.264 MP4 export** -- Industry-standard video format with configurable quality
- **Export progress indicator** -- Track encoding progress in real-time

### Preferences & Persistence

All your settings are saved automatically between sessions:
- Recording mode (full-screen vs. window)
- Selected display
- Zoom mode
- Selfie camera on/off, camera selection, and mirror setting
- Microphone on/off and device selection

## Installation

### Download

Visit **[capturethis.dev](https://capturethis.dev)** to download the latest release.

### Building from Source

**Requirements:**
- macOS 26.0 or later
- Xcode 26+

```bash
git clone https://github.com/waso/CaptureThis.git
cd CaptureThis/CaptureThis
open CaptureThis.xcodeproj
```

Select the **CaptureThis** scheme in Xcode and press **Cmd+R** to build and run.

## Usage

### Getting Started

1. **Launch CaptureThis** -- A floating control panel appears on screen
2. **Grant permissions** when prompted (see [Permissions](#permissions) below)
3. **Choose your recording mode:**
   - Click the **Screen** button to record a full display
   - Click the **Window** button to pick a specific window from the Mission Control selector
4. **Configure options:**
   - Toggle the **selfie camera** and select your preferred camera
   - Toggle the **microphone** and select your audio input device
   - Choose a **zoom mode** (No Zoom, Zoom on Click, Follow Mouse)
5. **Hit Record** and start capturing

### During Recording

| Action | How |
|---|---|
| Pause / Resume | Click the pause button on the floating indicator |
| Stop recording | Click the stop button on the floating indicator |
| Toggle microphone | Click the mic button on the floating indicator |
| Draw on screen | Hold **Control** + drag mouse |
| Clear drawings | Press **Escape** |
| Minimize controls | Click the minimize button on the floating indicator |

### After Recording

The built-in editor opens automatically where you can:

1. **Preview** your recording with the video player
2. **Trim** using the timeline -- add cut points and delete unwanted segments
3. **Customize** the look -- set background color/image, add borders, adjust selfie overlay
4. **Export** to MP4 -- choose your save location and watch the progress bar

## Permissions

CaptureThis requires the following macOS permissions to function:

| Permission | Why |
|---|---|
| **Screen Recording** | To capture your display content |
| **Microphone** | To record your voice |
| **Camera** | To capture selfie camera footage for picture-in-picture |
| **Accessibility** | To detect mouse clicks for zoom-on-click tracking |

You will be prompted to grant each permission on first use. You can manage these in **System Settings > Privacy & Security**.

## Architecture

CaptureThis is built entirely in **Swift** using native macOS frameworks:

| Component | Technology |
|---|---|
| Screen capture | [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) (SCStream) |
| Video encoding | [AVFoundation](https://developer.apple.com/documentation/avfoundation) (AVAssetWriter) |
| Video editing | AVFoundation (AVMutableComposition) |
| Camera capture | AVFoundation (AVCaptureSession) |
| Click tracking | CoreGraphics (CGEventTap) |
| UI | AppKit (NSViewController, NSView) |

### Project Structure

```
CaptureThis/
├── AppDelegate.swift                  # App entry point, floating control panel
├── MainViewController.swift           # Recording state machine & controls
├── EditorViewController.swift         # Video editing UI & composition
├── ScreenRecorderNew.swift            # ScreenCaptureKit integration
├── VideoProcessor.swift               # Video composition & effects rendering
├── TimelineView.swift                 # Timeline editor component
├── MissionControlWindowSelector.swift # Window picker UI
├── SelfieCameraController.swift       # Webcam capture & preview
├── ClickTrackerNew.swift              # Mouse click event detection
├── CursorTrackerNew.swift             # Cursor position sampling
├── DrawingOverlay.swift               # On-screen annotation canvas
├── FloatingRecordingIndicator.swift   # Recording timer & controls
└── WindowSelector.swift               # Window hover selection
```

### How Recording Works

1. **ScreenCaptureKit** delivers video frames at 60fps via `SCStream`
2. Each frame triggers synchronized **cursor position** and **click event** sampling
3. **AVAssetWriter** encodes frames to H.264 with separate audio tracks for system audio and microphone
4. On stop, **VideoProcessor** composites everything into the final video: zoom effects, selfie overlay, background, and borders

## System Requirements

- **OS:** macOS 26.0 (Tahoe) or later
- **Processor:** Apple Silicon or Intel
- **RAM:** 4 GB minimum, 8 GB recommended for 4K recording
- **Storage:** SSD recommended for smooth capture at 60fps
- **Optional:** Built-in or external webcam for selfie overlay

## Privacy

CaptureThis respects your privacy:

- **No telemetry** -- Analytics are completely disabled
- **No cloud sync** -- All recordings stay on your Mac
- **No network requests** -- The app works entirely offline
- **Open source** -- Inspect every line of code yourself

## Contributing

Contributions are welcome! Feel free to:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the **MIT License** -- see the [LICENSE](LICENSE) file for details.

Copyright (c) 2026 Waldemar Sojka

---

<p align="center">
  <a href="https://capturethis.dev">capturethis.dev</a>
</p>
