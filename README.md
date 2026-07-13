# Personal Eyes

Native iOS app for blind and low-vision users: **on-device AI** describes what the camera sees. Vision and optional Apple Intelligence stay on the device — nothing is uploaded to our servers.

## Features

- **Camera-on by default** — Opening the app turns the camera on so you can aim right away.
- **First-launch practice** — A short tutorial ends with a real practice capture before the app is marked ready.
- **Object-box aiming** — Detects a subject box, draws it on screen, and guides with Left / Right / Up / Down (plus optional Geiger beeps) until centered, then tap shutter or auto-capture.
- **Spoken image descriptions** — Each capture describes what the photo shows: people, objects, animals, or the scene. Readable text is mentioned only when useful text is actually found.
- **Apple Intelligence when available** — Guided on-device summaries with a Vision-only fallback if Intelligence is off or unavailable.
- **In-app result panel** — Photo thumbnail, spoken answer, **Hear Again**, and **OK** (replaces a plain system alert).
- **Reliable multi-capture** — Camera session stays warm between photos; analysis and speech have timeouts so the loop does not hang after a few captures.
- **Accessibility** — VoiceOver-friendly labels and hints; aiming sounds, direction cues, and spoken answers can be controlled independently (plus a toolbar mute).

## How it works

1. After the first-launch tutorial (or immediately on later launches), the camera starts. Aim with the object box, then tap the shutter (or use auto-capture).
2. Vision classifies the photo (and the aimed region when available), detects people/animals when present, and optionally runs OCR.
3. `AISummarizer` asks Apple Intelligence to describe the image for listening — no chatty follow-ups or “what do you see?” prompts. If Intelligence fails, a deterministic Vision summary is spoken instead.
4. Results show in the in-app result panel. Press **OK** to aim again; the camera stays ready for the next capture.

## Options

In **Options** you can toggle:

| Setting | Purpose |
| --- | --- |
| Auto-capture | Capture automatically when centered |
| Aiming sounds | Geiger-style beep with stereo pan |
| Direction cues | Spoken Left / Right / Up / Down / Centered |
| Spoken summary | TTS after each capture |
| Detailed description | 1–2 sentences vs a short 3-word reply |
| Read visible text | Mention signs/labels/prices only when text is found |
| Custom questions | Extra questions answered after the description when Apple Intelligence is available |

## Privacy

- All vision and language processing happen on device.
- No images are uploaded to our servers.
- **Camera** is the only privacy-sensitive permission the app requests.

## Requirements

- Xcode 26+ recommended; deployment target **iOS 17+** (Apple Intelligence APIs are gated at runtime).
- Physical iPhone recommended for real camera behavior (Simulator can launch the UI but has no useful camera feed).

## Setup

1. Open `PersonalEyes.xcodeproj` in Xcode.
2. Select the **Personal Eyes** scheme.
3. Set your development team under Signing & Capabilities.
4. Build and run on a device.

## Project structure

| Path | Role |
| --- | --- |
| `PersonalEyes/PersonalEyesApp.swift`, `ContentView.swift` | App entry and camera-first home screen |
| `Services/CameraController.swift` | Live capture, framing metrics, capture state machine |
| `Services/ObjectBoxDetector.swift` | Detect → track box → center distance (Vision objectness; Core ML YOLO plug-in ready) |
| `Services/CenteringDetector.swift` | Legacy saliency centering helper |
| `Services/AimingGuidance.swift` | Throttled direction speech cues |
| `Services/BeepEngine.swift` | Soft aiming tones with stereo pan |
| `Services/ImageAnalysisService.swift` | Vision OCR, classification, people/animals, subject crop |
| `Services/AISummarizer.swift` | Apple Intelligence description + Vision fallback |
| `Services/SpeechAnnouncer.swift` | TTS / VoiceOver with answer-hold and synthesizer refresh |
| `Views/` | Preview, object-box overlay, status banner, shutter, **ResultPanel**, tutorial, options |
| `Models/` | Preferences, custom prompts, analysis result |
| `Assets.xcassets` | App icon and accent color |

## Repo

- GitHub: [Bhuratshryas/PersonalEyes](https://github.com/Bhuratshryas/PersonalEyes)
