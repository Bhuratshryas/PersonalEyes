# Personal Eyes

Native iOS app for blind and low-vision users: **local AI** describes what the camera sees. Processing stays on device (Vision OCR and classification, optional Apple Intelligence summaries). The interaction takes inspiration from [Bhuratshryas/od_prj](https://github.com/Bhuratshryas/od_prj).

## Features

- **Shutter-first camera:** the capture session starts when you choose to scan; it turns off after each result, in the tutorial, and while Options are open.
- **Centering feedback:** optional procedural beeps that speed up as the main subject nears the frame center; optional auto-capture with a short “hold still” cue before capture.
- **Spoken summaries:** detailed description by default; optional short three-word mode; custom questions in Options.
- **Accessibility:** VoiceOver-friendly labels and hints; spoken summary can be muted independently from sound effects.
- **First-launch tutorial** explains the flow without turning the camera on.

## How it works

1. Tap the shutter to open the camera, aim, then tap again to capture (unless auto-capture is enabled).
2. Vision runs `VNRecognizeTextRequest`, `VNClassifyImageRequest`, and objectness-based saliency for framing.
3. `AISummarizer` uses Apple Intelligence (`FoundationModels` / `LanguageModelSession`) when available, otherwise a deterministic on-device summary.
4. Results appear in a system alert with **Hear Again** and **OK**; `AVSpeechSynthesizer` can read the summary when VoiceOver is off.

## Privacy

- All vision and language processing happen on device.
- No images are uploaded to our servers.
- **Camera** (and photo library if you add import later) are the permissions surfaced in the app.

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
- `PersonalEyes/Services/BeepEngine.swift` — Procedural sine-wave tones for centering, capture confirmation, and processing feedback.
- `PersonalEyes/Services/ImageAnalysisService.swift` — Vision OCR + classification.
- `PersonalEyes/Services/AISummarizer.swift` — Apple Intelligence summary with deterministic fallback.
- `PersonalEyes/Services/SpeechAnnouncer.swift` — Speech synthesis and VoiceOver announcements with `isSpeaking` state.
- `PersonalEyes/Views` — `CameraPreviewView`, `CameraOverlayViews` (reticle, status banner, shutter, unauthorized state), `Components`, `TutorialView`.
- `PersonalEyes/Models` — Analysis preferences and the structured result.
- `PersonalEyes/Assets.xcassets` — App icon (1024 by 1024) and accent color.
