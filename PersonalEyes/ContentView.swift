import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var speaker = SpeechAnnouncer()
    @StateObject private var beepEngine = BeepEngine()
    @StateObject private var promptStore = PromptStore()
    @StateObject private var preferenceStore = PreferenceStore()

    @State private var result: ImageAnalysisResult?
    @State private var capturedImage: UIImage?
    @State private var isShowingResultAlert = false
    @State private var isShowingSettings = false
    @State private var isShowingTutorial = false
    @State private var alertMessage: String?
    @State private var hasStartedAudio = false
    @State private var isCameraWired = false
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisGeneration = 0
    /// Toolbar master mute overlays Options without overwriting independent prefs.
    @State private var isMasterMuted = false

    @AppStorage("PersonalEyes.hasSeenTutorial") private var hasSeenTutorial: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    private let analyzer = ImageAnalysisService()
    private let summarizer = AISummarizer()

    private var preferences: AnalysisPreferences {
        preferenceStore.preferences
    }

    private var preferencesBinding: Binding<AnalysisPreferences> {
        $preferenceStore.preferences
    }

    var body: some View {
        Group {
            if camera.state == .unauthorized {
                UnauthorizedCameraView(onOpenSettings: openSystemSettings)
            } else if camera.state == .unavailable {
                UnavailableCameraView()
            } else {
                cameraScreen
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color.personalEyesAccent)
        .task {
            wireCameraIfNeeded()
            applyPreferencesToServices()
            if !hasSeenTutorial {
                // First launch: tutorial first; camera stays off until the user
                // taps the shutter to take a picture.
                isShowingTutorial = true
            } else {
                startAudioIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onChange(of: camera.centeringDistance) { _, distance in
            guard camera.state == .aligning else { return }
            beepEngine.updateCenteringBeep(distance: distance)
        }
        .onChange(of: camera.state) { _, newState in
            handleStateChange(newState)
        }
        .onChange(of: preferenceStore.preferences.autoCaptureEnabled) { _, _ in
            applyPreferencesToServices()
        }
        .onChange(of: preferenceStore.preferences.soundEffectsEnabled) { _, _ in
            applyPreferencesToServices()
        }
        .onChange(of: isMasterMuted) { _, _ in
            applyPreferencesToServices()
        }
        .onChange(of: isShowingTutorial) { _, isShowing in
            handleTutorialChange(isShowing: isShowing)
        }
        .onChange(of: isShowingResultAlert) { _, isShowing in
            handleResultAlertChange(isShowing: isShowing)
        }
        .onChange(of: isShowingSettings) { _, isShowing in
            handleSettingsChange(isShowing: isShowing)
        }
        .onChange(of: beepEngine.startErrorMessage) { _, message in
            guard let message else { return }
            alertMessage = message
            UIAccessibility.post(notification: .announcement, argument: message)
            beepEngine.clearStartError()
        }
        .alert(
            "Personal Eyes Result",
            isPresented: $isShowingResultAlert,
            presenting: result
        ) { value in
            Button("Hear Again") {
                replaySpokenSummary(of: value)
            }
            Button("OK", role: .cancel) {
                dismissResultAndScanAgain()
            }
        } message: { value in
            Text(value.spokenSummary)
        }
        .sheet(isPresented: $isShowingSettings) {
            settingsSheet
        }
        .sheet(isPresented: $isShowingTutorial) {
            TutorialView(isFirstLaunch: !hasSeenTutorial) {
                hasSeenTutorial = true
                isShowingTutorial = false
            }
        }
        .alert("Personal Eyes", isPresented: hasErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var cameraScreen: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            LinearGradient(
                colors: [
                    .black.opacity(0.55),
                    .clear,
                    .clear,
                    .black.opacity(0.65)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)

            CenteringReticleView(
                distance: camera.centeringDistance,
                hasSubject: camera.hasSubject,
                isHolding: camera.state == .holding,
                isProcessing: camera.state == .idle
                    || camera.state == .processing
                    || camera.state == .capturing
            )

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)

            if camera.state == .processing {
                processingOverlay
            }
        }
        .background(Color.black)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Personal Eyes")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Local AI for blind users")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Personal Eyes. Local AI for blind users.")
            .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                isMasterMuted.toggle()
                speaker.stop()
                UIAccessibility.post(
                    notification: .announcement,
                    argument: isMasterMuted ? "Audio muted" : "Audio unmuted"
                )
            } label: {
                Image(systemName: isAnyAudioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(isMasterMuted ? "Unmute audio" : "Mute audio")
            .accessibilityHint(
                isMasterMuted
                    ? "Restores sound effects and spoken summary based on Options"
                    : "Temporarily silences sound effects and the spoken summary without changing Options"
            )

            Button {
                isShowingTutorial = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("How it works")
            .accessibilityHint("Opens the tutorial")

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Options")
            .accessibilityHint("Opens settings. The camera turns off while this screen is open.")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            StatusBanner(
                title: statusTitle,
                subtitle: statusSubtitle,
                systemImage: statusIcon
            )

            HStack(alignment: .center) {
                Spacer()
                ShutterButton(
                    isProcessing: camera.state == .processing
                        || camera.state == .capturing
                        || camera.state == .starting,
                    opensCamera: camera.state == .idle,
                    action: shutterTapped
                )
                Spacer()
            }
            .overlay {
                Text(centeringHint)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                    .offset(y: 60)
                    .opacity(showCenteringHint ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.white)

                Text("Analyzing image…")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("Reading text and creating a spoken summary.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: 320)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analyzing image. Reading text and creating a spoken summary.")
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    PreferenceToggle(
                        title: "Auto-capture",
                        subtitle: "Captures automatically when an object is in the frame.",
                        isOn: preferencesBinding.autoCaptureEnabled
                    )
                    PreferenceToggle(
                        title: "Sound effects",
                        subtitle: "Centering beep, hold cue, capture chime, and processing tone.",
                        isOn: preferencesBinding.soundEffectsEnabled
                    )
                    PreferenceToggle(
                        title: "Spoken summary",
                        subtitle: "Reads the result aloud after each capture.",
                        isOn: preferencesBinding.spokenSummaryEnabled
                    )
                } header: {
                    Text("Capture & Audio")
                } footer: {
                    Text("With auto-capture off, the round shutter button captures on demand. Sound effects and the spoken summary can be muted independently in Options. The toolbar mute button silences both temporarily.")
                }

                Section {
                    PreferenceToggle(
                        title: "Detailed description",
                        subtitle: "On: 1 to 2 sentences with context. Off: a fast 3-word reply.",
                        isOn: preferencesBinding.detailedDescription
                    )
                    PreferenceToggle(
                        title: "Read visible text",
                        subtitle: "Includes useful labels, signs, prices, and packaging text in the response.",
                        isOn: preferencesBinding.includeVisibleText
                    )
                } header: {
                    Text("What Personal Eyes Says")
                } footer: {
                    Text("Personal Eyes works on anything you point it at — products, signs, food, books, scenes. By default you get a short spoken paragraph; turn this off for a fast three-word reply.")
                }

                CustomPromptsEditor(store: promptStore)

                Section {
                    Button {
                        isShowingSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            isShowingTutorial = true
                        }
                    } label: {
                        Label("Show Tutorial", systemImage: "graduationcap")
                    }
                    .accessibilityHint("Re-opens the tutorial that explains how to use Personal Eyes")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Color.personalEyesAccent)
                                .accessibilityHidden(true)
                            Text("Personal Eyes")
                                .font(.headline)
                        }
                        Text("Local AI for blind users")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(Color.personalEyesAccent)
                                .accessibilityHidden(true)
                            Text("All processing happens on device.")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Personal Eyes. Local AI for blind users. All processing happens on device.")
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isShowingSettings = false
                    }
                    .fontWeight(.semibold)
                    .accessibilityHint("Closes options. Tap the shutter when you are ready to open the camera.")
                }
            }
        }
        .tint(Color.personalEyesAccent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var isAnyAudioOn: Bool {
        !isMasterMuted && (preferences.soundEffectsEnabled || preferences.spokenSummaryEnabled)
    }

    private var effectiveSoundEffectsEnabled: Bool {
        !isMasterMuted && preferences.soundEffectsEnabled
    }

    private var effectiveSpokenSummaryEnabled: Bool {
        !isMasterMuted && preferences.spokenSummaryEnabled
    }

    private var hasErrorAlert: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    private var statusTitle: String {
        switch camera.state {
        case .idle: return "Ready to scan"
        case .starting: return "Starting camera"
        case .unauthorized: return "Camera access needed"
        case .unavailable: return "Camera unavailable"
        case .aligning:
            if !camera.hasSubject { return "Looking for an object" }
            if camera.centeringDistance < camera.centeredThreshold {
                return preferences.autoCaptureEnabled ? "Object found" : "Object found, tap shutter"
            }
            return "Object detected"
        case .holding: return "Stop. Hold still."
        case .capturing: return "Captured"
        case .processing: return "Analyzing image"
        case .showingResult: return "Result ready"
        }
    }

    private var statusSubtitle: String {
        switch camera.state {
        case .idle:
            return "Tap the shutter to open the camera. Tap again when you want the picture."
        case .starting:
            return "Hold the phone upright."
        case .unauthorized: return "Open Settings to allow camera access."
        case .unavailable: return "This device does not have a usable camera."
        case .aligning:
            if !camera.hasSubject {
                return effectiveSoundEffectsEnabled
                    ? "Move slowly until you hear a beep."
                    : "Move slowly until something is in view."
            }
            if camera.centeringDistance < camera.centeredThreshold {
                return preferences.autoCaptureEnabled
                    ? "Capturing in a moment."
                    : "Tap the shutter button to capture."
            }
            return effectiveSoundEffectsEnabled
                ? "The beep gets faster as the object centers."
                : "Move slowly to bring the object into view."
        case .holding: return "Capturing now."
        case .capturing: return "Reading the image."
        case .processing: return "Reading text and writing a spoken summary."
        case .showingResult: return "Listen, then press OK. Tap the shutter when you want another picture."
        }
    }

    private var statusIcon: String {
        switch camera.state {
        case .idle: return "camera.fill"
        case .holding: return "hand.raised.fill"
        case .processing: return "waveform"
        case .capturing: return "camera.fill"
        case .showingResult: return "checkmark.seal.fill"
        case .unauthorized, .unavailable: return "exclamationmark.triangle.fill"
        default: return "viewfinder"
        }
    }

    private var centeringHint: String {
        switch camera.state {
        case .holding: return "Hold still"
        case .aligning:
            guard camera.hasSubject else { return "Move slowly to find an object" }
            if camera.centeringDistance < camera.centeredThreshold {
                return preferences.autoCaptureEnabled ? "Get ready" : "Tap shutter"
            }
            return "Bring the object into view"
        default:
            return ""
        }
    }

    private var showCenteringHint: Bool {
        camera.state == .aligning || camera.state == .holding
    }

    private func wireCameraIfNeeded() {
        guard !isCameraWired else { return }
        camera.onPhotoCaptured = { image in
            Task { @MainActor in
                self.analysisTask?.cancel()
                self.analysisGeneration += 1
                let generation = self.analysisGeneration
                self.analysisTask = Task { @MainActor in
                    await self.handleCapturedImage(image, generation: generation)
                }
            }
        }
        camera.onError = { message in
            Task { @MainActor in
                self.alertMessage = message
            }
        }
        isCameraWired = true
    }

    private func applyPreferencesToServices() {
        camera.isAutoCaptureEnabled = preferences.autoCaptureEnabled
        beepEngine.isMuted = !effectiveSoundEffectsEnabled
    }

    private func shutterTapped() {
        switch camera.state {
        case .idle:
            Task { @MainActor in
                await camera.requestAccessAndStart()
            }
        case .aligning, .holding:
            camera.captureNow()
        case .starting, .capturing, .processing, .unauthorized, .unavailable, .showingResult:
            break
        }
    }

    private func startAudioIfNeeded() {
        guard !hasStartedAudio else { return }
        beepEngine.start()
        hasStartedAudio = true
    }

    private func cancelInFlightAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisGeneration += 1
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background, .inactive:
            // Stop talking and beeping the moment the user returns to home
            // screen, locks the device, or backgrounds the app for any reason.
            cancelInFlightAnalysis()
            speaker.stop()
            beepEngine.stop()
            hasStartedAudio = false
            camera.stop()
        case .active:
            // Don't resume audio if a sheet or tutorial still has focus.
            guard !isShowingTutorial, !isShowingResultAlert, !isShowingSettings else { return }
            startAudioIfNeeded()
        @unknown default:
            break
        }
    }

    @MainActor
    private func handleTutorialChange(isShowing: Bool) {
        if isShowing {
            // Camera and audio are paused while the user reads the tutorial.
            cancelInFlightAnalysis()
            speaker.stop()
            beepEngine.stopCenteringBeep()
            beepEngine.stopProcessingTone()
            camera.stop()
        } else {
            startAudioIfNeeded()
        }
    }

    @MainActor
    private func handleSettingsChange(isShowing: Bool) {
        guard isShowing else { return }
        cancelInFlightAnalysis()
        speaker.stop()
        beepEngine.stopCenteringBeep()
        beepEngine.stopProcessingTone()
        camera.stop()
    }

    @MainActor
    private func handleResultAlertChange(isShowing: Bool) {
        if isShowing {
            // Pause the camera while the user is reading or listening to the
            // result. The session stays off until the next shutter tap.
            camera.enterShowingResult()
            beepEngine.stopCenteringBeep()
            beepEngine.stopProcessingTone()
        }
    }

    @MainActor
    private func handleStateChange(_ newState: CameraController.State) {
        switch newState {
        case .aligning:
            beepEngine.updateCenteringBeep(distance: camera.centeringDistance)
        case .holding:
            // Hold cue must reach blind users even when sound effects are off.
            beepEngine.stopCenteringBeep()
            beepEngine.playHoldCue()
            let holdPhrase = "Stop. Stop. Stop."
            if effectiveSpokenSummaryEnabled, !UIAccessibility.isVoiceOverRunning {
                speaker.speak(holdPhrase)
            } else {
                UIAccessibility.post(notification: .announcement, argument: holdPhrase)
            }
        case .capturing:
            beepEngine.stopCenteringBeep()
            beepEngine.playConfirmation()
            UIAccessibility.post(notification: .announcement, argument: "Captured.")
        case .processing:
            beepEngine.startProcessingTone()
        default:
            beepEngine.stopCenteringBeep()
            beepEngine.stopProcessingTone()
        }
    }

    @MainActor
    private func handleCapturedImage(_ image: UIImage, generation: Int) async {
        guard generation == analysisGeneration else { return }
        capturedImage = image
        UIAccessibility.post(notification: .announcement, argument: "Image captured. Analyzing.")

        do {
            let analysis = try await analyzer.analyze(image, preferences: preferences)
            try Task.checkCancellation()
            guard generation == analysisGeneration else { return }

            let summary = await summarizer.summarize(.init(
                visibleText: analysis.visibleText,
                classification: analysis.objectName,
                preferences: preferences,
                customQuestions: promptStore.enabledQuestions
            ))
            try Task.checkCancellation()
            guard generation == analysisGeneration else { return }

            var enriched = analysis
            enriched.aiSummary = summary.summary
            enriched.usedAppleIntelligence = summary.usedAppleIntelligence

            beepEngine.stopProcessingTone()
            result = enriched
            isShowingResultAlert = true

            // Speak the summary unless the user disabled spoken playback or
            // VoiceOver is running (in which case VoiceOver reads the alert).
            if effectiveSpokenSummaryEnabled, !UIAccessibility.isVoiceOverRunning {
                speaker.speak(enriched.spokenSummary)
            }
        } catch is CancellationError {
            beepEngine.stopProcessingTone()
        } catch {
            guard generation == analysisGeneration else { return }
            beepEngine.stopProcessingTone()
            alertMessage = error.localizedDescription
            camera.stop()
        }
    }

    @MainActor
    private func replaySpokenSummary(of value: ImageAnalysisResult) {
        speaker.stop()
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: value.spokenSummary)
        } else if effectiveSpokenSummaryEnabled {
            speaker.speak(value.spokenSummary)
        }
        // Keep the result alert up; do not dismiss and re-present (that
        // steals VoiceOver focus).
        isShowingResultAlert = true
    }

    @MainActor
    private func dismissResultAndScanAgain() {
        speaker.stop()
        result = nil
        capturedImage = nil
        isShowingResultAlert = false
        camera.stop()
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
