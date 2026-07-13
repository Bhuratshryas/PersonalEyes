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
    @State private var currentAimDirection: AimingGuidance.Direction = .searching
    @State private var isPreparingNextCapture = false
    /// First-launch guided practice until the user completes one identification.
    @State private var isPracticeSession = false

    @AppStorage("PersonalEyes.hasSeenTutorial") private var hasSeenTutorial: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    private let analyzer = ImageAnalysisService()
    private let summarizer = AISummarizer()
    @State private var aimingGuidance = AimingGuidance()
    private let centerHaptic = UIImpactFeedbackGenerator(style: .medium)

    private var preferences: AnalysisPreferences {
        preferenceStore.preferences
    }

    private var preferencesBinding: Binding<AnalysisPreferences> {
        $preferenceStore.preferences
    }

    var body: some View {
        rootContent
            .preferredColorScheme(.dark)
            .tint(Color.personalEyesAccent)
            .task {
                wireCameraIfNeeded()
                applyPreferencesToServices()
                centerHaptic.prepare()
                if !hasSeenTutorial {
                    isShowingTutorial = true
                } else {
                    await beginLiveCapture(announce: true)
                }
            }
            .modifier(ContentViewLifecycleModifier(
                onScenePhase: handleScenePhaseChange,
                onAimingMetricsChanged: updateAimingFeedback,
                onCameraState: handleStateChange,
                onPreferencesChanged: applyPreferencesToServices,
                onMasterMuteChanged: applyPreferencesToServices,
                onTutorial: handleTutorialChange,
                onResultAlert: handleResultAlertChange,
                onSettings: handleSettingsChange,
                onBeepError: { message in
                    alertMessage = message
                    UIAccessibility.post(notification: .announcement, argument: message)
                    beepEngine.clearStartError()
                },
                scenePhase: scenePhase,
                centeringDistance: camera.centeringDistance,
                hasSubject: camera.hasSubject,
                subjectOffsetX: camera.subjectOffsetX,
                subjectOffsetY: camera.subjectOffsetY,
                cameraState: camera.state,
                autoCaptureEnabled: preferenceStore.preferences.autoCaptureEnabled,
                soundEffectsEnabled: preferenceStore.preferences.soundEffectsEnabled,
                isMasterMuted: isMasterMuted,
                isShowingTutorial: isShowingTutorial,
                isShowingResultAlert: isShowingResultAlert,
                isShowingSettings: isShowingSettings,
                beepError: beepEngine.startErrorMessage
            ))
            .sheet(isPresented: $isShowingSettings) {
                settingsSheet
            }
            .sheet(isPresented: $isShowingTutorial) {
                TutorialView(isFirstLaunch: !hasSeenTutorial && !isPracticeSession) { action in
                    switch action {
                    case .startPractice:
                        isPracticeSession = true
                        isShowingTutorial = false
                    case .close:
                        isShowingTutorial = false
                    }
                }
            }
            .alert("Personal Eyes", isPresented: hasErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if camera.state == .unauthorized {
            UnauthorizedCameraView(onOpenSettings: openSystemSettings)
        } else if camera.state == .unavailable {
            UnavailableCameraView()
        } else {
            cameraScreen
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

            ObjectBoundingBoxOverlay(
                box: camera.subjectBox,
                isCentered: camera.isCenteredEnoughForCapture || currentAimDirection == .centered,
                isHolding: camera.state == .holding,
                isProcessing: camera.state == .idle
                    || camera.state == .processing
                    || camera.state == .capturing
                    || camera.state == .starting
                    || isPreparingNextCapture
            )

            VStack {
                if isPracticeSession {
                    practiceBanner
                }
                topBar
                Spacer()
                if camera.state != .processing, !isShowingResultAlert {
                    bottomBar
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)

            if camera.state == .processing {
                processingOverlay
            }

            if isShowingResultAlert, let result {
                ResultPanel(
                    title: isPracticeSession ? "Practice Result" : "Personal Eyes Result",
                    summary: result.spokenSummary,
                    note: result.usedAppleIntelligence ? nil : result.availabilityNote,
                    thumbnail: capturedImage,
                    usedAppleIntelligence: result.usedAppleIntelligence,
                    primaryButtonTitle: isPracticeSession ? "Finish practice" : "OK",
                    onHearAgain: { replaySpokenSummary(of: result) },
                    onDismiss: dismissResultAndScanAgain
                )
                .zIndex(20)
            }
        }
        .background(Color.black)
        .animation(.easeInOut(duration: 0.22), value: isShowingResultAlert)
        .animation(.easeInOut(duration: 0.22), value: camera.state == .processing)
    }

    private var practiceBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap.fill")
                .accessibilityHidden(true)
            Text("Practice: point at something nearby, center it, then tap shutter.")
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Practice mode. Point at something nearby, center it, then tap the shutter.")
        .padding(.bottom, 8)
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
                    ? "Restores aiming sounds and spoken answers based on Options"
                    : "Temporarily silences aiming sounds and spoken answers without changing Options"
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
                        || camera.state == .starting
                        || isPreparingNextCapture,
                    opensCamera: false,
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

                Text("Reading the photo…")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: 320)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reading the photo.")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    PreferenceToggle(
                        title: "Auto-capture",
                        subtitle: "Captures automatically when a subject is centered.",
                        isOn: preferencesBinding.autoCaptureEnabled
                    )
                    PreferenceToggle(
                        title: "Aiming sounds",
                        subtitle: "Geiger-style beep that speeds up as you center, with left/right stereo pan.",
                        isOn: preferencesBinding.soundEffectsEnabled
                    )
                    PreferenceToggle(
                        title: "Direction cues",
                        subtitle: "Speaks left, right, up, down, and centered while you aim.",
                        isOn: preferencesBinding.directionalGuidanceEnabled
                    )
                    PreferenceToggle(
                        title: "Spoken answer",
                        subtitle: "Reads the Apple Intelligence answer aloud after each capture.",
                        isOn: preferencesBinding.spokenSummaryEnabled
                    )
                } header: {
                    Text("Capture & Audio")
                } footer: {
                    Text("Directional speech and aiming sounds are the main guidance loop. The toolbar mute silences them temporarily without changing these Options.")
                }

                Section {
                    PreferenceToggle(
                        title: "Detailed description",
                        subtitle: "On: 1 to 2 sentences. Off: a fast 3-word reply.",
                        isOn: preferencesBinding.detailedDescription
                    )
                    PreferenceToggle(
                        title: "Read visible text",
                        subtitle: "When text is found (signs, labels, prices), mention it. If none, just describe the image.",
                        isOn: preferencesBinding.includeVisibleText
                    )
                } header: {
                    Text("What Personal Eyes Says")
                } footer: {
                    Text("Every capture describes what the photo shows — people, objects, or the scene. Text is spoken only when useful readable text is actually there.")
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
                    .accessibilityHint("Re-opens the guide that explains how to use Personal Eyes")
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
                    .accessibilityHint("Closes options and returns to capture.")
                }
            }
        }
        .tint(Color.personalEyesAccent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var isAnyAudioOn: Bool {
        !isMasterMuted && (
            preferences.soundEffectsEnabled
                || preferences.spokenSummaryEnabled
                || preferences.directionalGuidanceEnabled
        )
    }

    private var effectiveSoundEffectsEnabled: Bool {
        !isMasterMuted && preferences.soundEffectsEnabled
    }

    private var effectiveSpokenSummaryEnabled: Bool {
        !isMasterMuted && preferences.spokenSummaryEnabled
    }

    private var effectiveDirectionalGuidanceEnabled: Bool {
        !isMasterMuted && preferences.directionalGuidanceEnabled
    }

    private var hasErrorAlert: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    private var statusTitle: String {
        if isPreparingNextCapture { return "Getting ready" }
        if isPracticeSession, camera.state == .aligning || camera.state == .starting {
            return "Practice — find an object"
        }
        switch camera.state {
        case .idle: return "Starting camera"
        case .starting: return "Starting camera"
        case .unauthorized: return "Camera access needed"
        case .unavailable: return "Camera unavailable"
        case .aligning:
            switch currentAimDirection {
            case .searching: return "Looking for an object"
            case .left: return "Point left"
            case .right: return "Point right"
            case .up: return "Point up"
            case .down: return "Point down"
            case .centered:
                return preferences.autoCaptureEnabled ? "Object centered" : "Object centered — tap shutter"
            }
        case .holding: return "Stop. Hold still."
        case .capturing: return "Captured"
        case .processing: return "Reading the photo"
        case .showingResult: return "Result ready"
        }
    }

    private var statusSubtitle: String {
        if isPreparingNextCapture {
            return "Opening the camera for the next capture."
        }
        if isPracticeSession {
            switch camera.state {
            case .aligning, .starting, .idle:
                return "Practice: point at a nearby object, center it, then tap the shutter."
            case .showingResult:
                return "Listen to the answer, then finish practice."
            default:
                break
            }
        }
        switch camera.state {
        case .idle:
            return "Turning the camera on so you can start identifying."
        case .starting:
            return "Hold the phone upright."
        case .unauthorized: return "Open Settings to allow camera access."
        case .unavailable: return "This device does not have a usable camera."
        case .aligning:
            switch currentAimDirection {
            case .searching:
                return effectiveSoundEffectsEnabled
                    ? "Move slowly until the beep starts."
                    : "Move slowly until a subject is found."
            case .left, .right, .up, .down:
                return effectiveSoundEffectsEnabled
                    ? "Follow the cue. The beep speeds up as you center."
                    : "Follow the direction cue until centered."
            case .centered:
                return preferences.autoCaptureEnabled
                    ? "Hold steady — capturing soon."
                    : "Tap the shutter to capture."
            }
        case .holding: return "Capturing now."
        case .capturing: return "Photo saved. Preparing the answer."
        case .processing: return "One moment."
        case .showingResult:
            return isPracticeSession
                ? "Listen, then finish practice to keep using Personal Eyes."
                : "Listen, then tap OK to aim again."
        }
    }

    private var statusIcon: String {
        if isPreparingNextCapture { return "arrow.triangle.2.circlepath.camera" }
        switch camera.state {
        case .idle: return "camera.fill"
        case .holding: return "hand.raised.fill"
        case .processing: return "sparkles"
        case .capturing: return "camera.fill"
        case .showingResult: return "checkmark.seal.fill"
        case .unauthorized, .unavailable: return "exclamationmark.triangle.fill"
        case .aligning:
            switch currentAimDirection {
            case .left: return "arrow.left"
            case .right: return "arrow.right"
            case .up: return "arrow.up"
            case .down: return "arrow.down"
            case .centered: return "checkmark.circle"
            case .searching: return "viewfinder"
            }
        default: return "viewfinder"
        }
    }

    private var centeringHint: String {
        switch camera.state {
        case .holding: return "Hold still"
        case .aligning: return currentAimDirection.statusPhrase
        default: return ""
        }
    }

    private var showCenteringHint: Bool {
        camera.state == .aligning || camera.state == .holding
    }

    private func wireCameraIfNeeded() {
        guard !isCameraWired else { return }
        camera.onPhotoCaptured = { image, focusBox in
            Task { @MainActor in
                self.analysisTask?.cancel()
                self.analysisGeneration += 1
                let generation = self.analysisGeneration
                self.analysisTask = Task { @MainActor in
                    await self.handleCapturedImage(
                        image,
                        focusBox: focusBox,
                        generation: generation
                    )
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
        guard !isPreparingNextCapture else { return }
        switch camera.state {
        case .idle:
            Task { @MainActor in
                await beginLiveCapture(announce: false)
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

    /// Turns the camera on so the user can aim and identify immediately.
    @MainActor
    private func beginLiveCapture(announce: Bool) async {
        startAudioIfNeeded()
        switch camera.state {
        case .unauthorized, .unavailable, .aligning, .starting, .holding, .capturing, .processing:
            break
        case .idle, .showingResult:
            await camera.requestAccessAndStart()
        }

        guard announce else { return }
        guard camera.state == .aligning || camera.state == .starting else { return }

        let message: String
        if isPracticeSession {
            message = "Practice mode. Point at something nearby, center it, then tap the shutter."
        } else {
            message = "Camera on. Point at something to identify."
        }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: message)
        } else if effectiveDirectionalGuidanceEnabled || effectiveSpokenSummaryEnabled {
            speaker.speak(message, style: .cue)
        } else {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func cancelInFlightAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisGeneration += 1
    }

    private func updateAimingFeedback() {
        guard camera.state == .aligning else { return }
        guard !isShowingResultAlert, !speaker.isHoldingForAnswer else { return }

        let direction = aimingGuidance.direction(
            hasSubject: camera.hasSubject,
            offsetX: camera.subjectOffsetX,
            offsetY: camera.subjectOffsetY,
            distance: camera.centeringDistance,
            centeredThreshold: camera.centeredThreshold
        )
        currentAimDirection = direction

        // Beep only while an object box is tracked — silence when searching.
        if camera.hasSubject {
            beepEngine.updateCenteringBeep(
                distance: camera.centeringDistance,
                offsetX: camera.subjectOffsetX,
                hasSubject: true
            )
        } else {
            beepEngine.stopCenteringBeep()
        }

        if aimingGuidance.shouldPlayCenterHaptic(for: direction) {
            centerHaptic.impactOccurred()
        }

        if let cue = aimingGuidance.spokenCueIfNeeded(
            for: direction,
            speechEnabled: effectiveDirectionalGuidanceEnabled
        ) {
            // Prefer the clearer centered instruction when manual shutter is needed.
            if direction == .centered, !preferences.autoCaptureEnabled {
                announceAimingCue("Object centered. Tap shutter.")
            } else if direction == .centered, preferences.autoCaptureEnabled {
                announceAimingCue("Object centered.")
            } else {
                announceAimingCue(cue)
            }
        }
    }

    private func announceAimingCue(_ cue: String) {
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: cue)
        } else {
            speaker.speak(cue, style: .cue)
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            cancelInFlightAnalysis()
            isPreparingNextCapture = false
            speaker.stop()
            beepEngine.stop()
            hasStartedAudio = false
            aimingGuidance.reset()
            camera.stop()
        case .inactive:
            // System alerts briefly inactive the scene. Do NOT stop speech here
            // or the spoken result dies after capture.
            beepEngine.silenceAll()
        case .active:
            guard !isShowingTutorial, !isShowingResultAlert, !isShowingSettings else { return }
            Task { @MainActor in
                await beginLiveCapture(announce: false)
            }
        @unknown default:
            break
        }
    }

    @MainActor
    private func handleTutorialChange(isShowing: Bool) {
        if isShowing {
            cancelInFlightAnalysis()
            isPreparingNextCapture = false
            speaker.stop()
            beepEngine.silenceAll()
            aimingGuidance.reset()
            camera.stop()
        } else {
            Task { @MainActor in
                await beginLiveCapture(announce: true)
            }
        }
    }

    @MainActor
    private func handleSettingsChange(isShowing: Bool) {
        if isShowing {
            cancelInFlightAnalysis()
            isPreparingNextCapture = false
            speaker.stop()
            beepEngine.silenceAll()
            aimingGuidance.reset()
            camera.stop()
        } else {
            Task { @MainActor in
                await beginLiveCapture(announce: false)
            }
        }
    }

    @MainActor
    private func handleResultAlertChange(isShowing: Bool) {
        if isShowing {
            camera.enterShowingResult()
            beepEngine.silenceAll()
            aimingGuidance.reset()
        }
    }

    @MainActor
    private func handleStateChange(_ newState: CameraController.State) {
        switch newState {
        case .aligning:
            aimingGuidance.reset()
            updateAimingFeedback()
        case .holding:
            beepEngine.stopCenteringBeep()
            beepEngine.playHoldCue()
            let holdPhrase = "Stop. Stop. Stop."
            if effectiveSpokenSummaryEnabled || effectiveDirectionalGuidanceEnabled {
                if UIAccessibility.isVoiceOverRunning {
                    UIAccessibility.post(notification: .announcement, argument: holdPhrase)
                } else {
                    speaker.speak(holdPhrase, style: .cue)
                }
            } else {
                UIAccessibility.post(notification: .announcement, argument: holdPhrase)
            }
        case .capturing:
            // Stop all aiming beeps the instant the shutter fires.
            beepEngine.silenceAll()
            beepEngine.playConfirmation()
            UIAccessibility.post(notification: .announcement, argument: "Captured.")
        case .processing:
            // Stay silent so Apple Intelligence answers can be heard clearly.
            beepEngine.silenceAll()
        default:
            beepEngine.silenceAll()
        }
    }

    @MainActor
    private func handleCapturedImage(
        _ image: UIImage,
        focusBox: CGRect?,
        generation: Int
    ) async {
        guard generation == analysisGeneration else { return }
        capturedImage = image
        UIAccessibility.post(
            notification: .announcement,
            argument: "Image captured."
        )

        do {
            let enriched = try await withThrowingTaskGroup(of: ImageAnalysisResult.self) { group in
                group.addTask { @MainActor in
                    try await self.runAnalysisPipeline(
                        image: image,
                        focusBox: focusBox,
                        generation: generation
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 35_000_000_000)
                    throw AnalysisPipelineTimeout()
                }
                let value = try await group.next()!
                group.cancelAll()
                return value
            }

            guard generation == analysisGeneration else { return }

            beepEngine.silenceAll()
            result = enriched
            isShowingResultAlert = true
            // Don't rely only on SwiftUI onChange ordering.
            camera.enterShowingResult()

            if effectiveSpokenSummaryEnabled {
                let answer = enriched.spokenSummary
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard self.analysisGeneration == generation else { return }
                    beepEngine.silenceAll()
                    if UIAccessibility.isVoiceOverRunning {
                        UIAccessibility.post(notification: .announcement, argument: answer)
                    } else {
                        speaker.speak(answer, style: .answer)
                    }
                }
            }
        } catch is CancellationError {
            beepEngine.silenceAll()
            if generation == analysisGeneration, camera.state == .processing {
                await camera.prepareForNextCapture()
            }
        } catch is AnalysisPipelineTimeout {
            guard generation == analysisGeneration else { return }
            beepEngine.silenceAll()
            // Still return a usable Vision fallback so the loop never wedges.
            let fallback = ImageAnalysisResult(
                objectName: nil,
                confidence: nil,
                visibleText: [],
                aiSummary: "I could not finish reading that photo in time. Point again and tap the shutter.",
                usedAppleIntelligence: false,
                availabilityNote: "Analysis timed out, so Personal Eyes stopped waiting.",
                timestamp: Date()
            )
            result = fallback
            isShowingResultAlert = true
            camera.enterShowingResult()
            if effectiveSpokenSummaryEnabled {
                speaker.speak(fallback.spokenSummary, style: .answer)
            }
        } catch {
            guard generation == analysisGeneration else { return }
            beepEngine.silenceAll()
            alertMessage = error.localizedDescription
            await camera.prepareForNextCapture()
        }
    }

    @MainActor
    private func runAnalysisPipeline(
        image: UIImage,
        focusBox: CGRect?,
        generation: Int
    ) async throws -> ImageAnalysisResult {
        let analysis = try await analyzer.analyze(
            image,
            preferences: preferences,
            focusBox: focusBox
        )
        try Task.checkCancellation()
        guard generation == analysisGeneration else {
            throw CancellationError()
        }

        let summary = await summarizer.summarize(.init(
            image: image,
            visibleText: analysis.visibleText,
            classification: analysis.objectName,
            classificationConfidence: analysis.confidence,
            allLabels: analysis.labels,
            peopleCount: analysis.peopleCount,
            preferences: preferences,
            customQuestions: promptStore.enabledQuestions
        ))
        try Task.checkCancellation()
        guard generation == analysisGeneration else {
            throw CancellationError()
        }

        var enriched = analysis
        enriched.aiSummary = summary.summary
        enriched.usedAppleIntelligence = summary.usedAppleIntelligence
        enriched.availabilityNote = summary.availabilityNote
        return enriched
    }

    @MainActor
    private func replaySpokenSummary(of value: ImageAnalysisResult) {
        speaker.stop()
        beepEngine.silenceAll()
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: value.spokenSummary)
        } else if effectiveSpokenSummaryEnabled {
            speaker.speak(value.spokenSummary, style: .answer)
        }
        isShowingResultAlert = true
    }

    @MainActor
    private func dismissResultAndScanAgain() {
        speaker.resetForNextCapture()
        beepEngine.silenceAll()
        result = nil
        capturedImage = nil
        isShowingResultAlert = false
        aimingGuidance.reset()
        currentAimDirection = .searching

        let finishingPractice = isPracticeSession
        if finishingPractice {
            isPracticeSession = false
            hasSeenTutorial = true
        }

        if isPreparingNextCapture { return }
        isPreparingNextCapture = true
        Task { @MainActor in
            defer { isPreparingNextCapture = false }
            startAudioIfNeeded()
            beepEngine.start()
            await camera.prepareForNextCapture()

            if camera.state != .aligning,
               camera.state != .unauthorized,
               camera.state != .unavailable {
                // One more recovery attempt if restart failed silently.
                await camera.requestAccessAndStart()
            }
            guard camera.state == .aligning else { return }

            let ready: String
            if finishingPractice {
                ready = "Practice complete. Camera on. Point at something to identify."
            } else {
                ready = "Ready. Point at the next subject."
            }
            if effectiveDirectionalGuidanceEnabled || effectiveSpokenSummaryEnabled {
                if UIAccessibility.isVoiceOverRunning {
                    UIAccessibility.post(notification: .announcement, argument: ready)
                } else {
                    speaker.speak(ready, style: .cue)
                }
            } else {
                UIAccessibility.post(notification: .announcement, argument: ready)
            }
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

private struct AnalysisPipelineTimeout: Error {}

/// Breaks ContentView's modifier chain into a separate type so the compiler
/// can type-check the screen in reasonable time.
private struct ContentViewLifecycleModifier: ViewModifier {
    var onScenePhase: (ScenePhase) -> Void
    var onAimingMetricsChanged: () -> Void
    var onCameraState: (CameraController.State) -> Void
    var onPreferencesChanged: () -> Void
    var onMasterMuteChanged: () -> Void
    var onTutorial: (Bool) -> Void
    var onResultAlert: (Bool) -> Void
    var onSettings: (Bool) -> Void
    var onBeepError: (String) -> Void

    var scenePhase: ScenePhase
    var centeringDistance: Float
    var hasSubject: Bool
    var subjectOffsetX: Float
    var subjectOffsetY: Float
    var cameraState: CameraController.State
    var autoCaptureEnabled: Bool
    var soundEffectsEnabled: Bool
    var isMasterMuted: Bool
    var isShowingTutorial: Bool
    var isShowingResultAlert: Bool
    var isShowingSettings: Bool
    var beepError: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, newPhase in onScenePhase(newPhase) }
            .onChange(of: centeringDistance) { _, _ in onAimingMetricsChanged() }
            .onChange(of: hasSubject) { _, _ in onAimingMetricsChanged() }
            .onChange(of: subjectOffsetX) { _, _ in onAimingMetricsChanged() }
            .onChange(of: subjectOffsetY) { _, _ in onAimingMetricsChanged() }
            .onChange(of: cameraState) { _, newState in onCameraState(newState) }
            .onChange(of: autoCaptureEnabled) { _, _ in onPreferencesChanged() }
            .onChange(of: soundEffectsEnabled) { _, _ in onPreferencesChanged() }
            .onChange(of: isMasterMuted) { _, _ in onMasterMuteChanged() }
            .onChange(of: isShowingTutorial) { _, isShowing in onTutorial(isShowing) }
            .onChange(of: isShowingResultAlert) { _, isShowing in onResultAlert(isShowing) }
            .onChange(of: isShowingSettings) { _, isShowing in onSettings(isShowing) }
            .onChange(of: beepError) { _, message in
                guard let message else { return }
                onBeepError(message)
            }
    }
}
