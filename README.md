# Personal Eyes

Native iOS app for blind and low-vision users: **local AI** describes what the camera sees. Processing stays on device (Vision OCR and classification, optional Apple Intelligence summaries).

## Features

- **Camera-on by default:** opening the app turns the camera on so you can aim immediately.
- **First-launch practice:** a short tutorial ends with a real practice capture before the app is marked ready.
- **Directional aiming cues:** detects an object box, draws it on screen, and guides with Left / Right / Up / Down until the box is centered — then announces tap-shutter or auto-captures.
- **Spoken answers:** each capture describes what the photo shows via Apple Intelligence when available.
- **Accessibility:** VoiceOver-friendly labels and hints; aiming sounds, direction cues, and spoken answers can be controlled independently.
- **First-launch tutorial** includes a practice capture; camera starts after the tutorial (and on later launches).

## How it works

1. The camera starts when you open the app (after the first-launch practice tutorial). Aim, then tap the shutter to capture (unless auto-capture is enabled).
2. Vision runs OCR, classification, and objectness-based saliency for framing.
3. `AISummarizer` describes the overall image with Apple Intelligence when available, otherwise a deterministic on-device summary.
4. Results appear in a system alert with **Hear Again** and **OK**; after OK the camera starts again for the next picture.

## Privacy

- All vision and language processing happen on device.
- No images are uploaded to our servers.
- **Camera** is the only privacy-sensitive permission the app requests.

## Requirements

- Xcode 26+ recommended; iOS 17+ deployment target (Apple Intelligence APIs gated at runtime where needed).
- Physical iPhone recommended for real camera behavior.

## Setup

1. Open `PersonalEyes.xcodeproj` in Xcode.
2. Select the **Personal Eyes** scheme.
3. Set your development team under Signing & Capabilities.
4. Build and run on a device.

## Project Structure

- `PersonalEyes/PersonalEyesApp.swift` and `ContentView.swift` — App entry and the camera-first home screen.
- `PersonalEyes/Services/CameraController.swift` — Live capture, frame analysis, and auto-capture state machine.
- `PersonalEyes/Services/CenteringDetector.swift` — Vision saliency-based centering distance metric.
- `PersonalEyes/Services/ObjectBoxDetector.swift` — YOLO-style detect → track box → center distance (Vision objectness boxes today; Core ML YOLO plug-in ready).
- `PersonalEyes/Services/AimingGuidance.swift` — Throttled left/right/up/down/centered speech cues.
- `PersonalEyes/Services/BeepEngine.swift` — Geiger-style tones with stereo pan for aiming.
- `PersonalEyes/Services/ImageAnalysisService.swift` — Vision OCR + classification.
- `PersonalEyes/Services/AISummarizer.swift` — Apple Intelligence summary with deterministic fallback.
- `PersonalEyes/Services/SpeechAnnouncer.swift` — Speech synthesis and VoiceOver announcements with `isSpeaking` state.
- `PersonalEyes/Views` — `CameraPreviewView`, `CameraOverlayViews` (reticle, status banner, shutter, unauthorized/unavailable states), `Components`, `TutorialView`.
- `PersonalEyes/Models` — Analysis preferences (persisted), custom prompts, and the structured result.
- `PersonalEyes/Assets.xcassets` — App icon (1024 by 1024) and accent color.
