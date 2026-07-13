import SwiftUI

struct TutorialView: View {
    let isFirstLaunch: Bool
    let onDone: () -> Void

    private let steps: [TutorialStep] = [
        TutorialStep(
            number: 1,
            systemImage: "viewfinder",
            title: "Open the camera, then aim",
            body: "On the main screen, tap the shutter once to turn on the camera. Hold the phone upright and point it at what you want to know about. Tap the shutter again to take the picture when you are ready."
        ),
        TutorialStep(
            number: 2,
            systemImage: "speaker.wave.3.fill",
            title: "Optional framing sounds",
            body: "If Sound effects is on in Options, a beep gets faster as an object enters the view. With sound off, use the status message and move slowly until something is detected."
        ),
        TutorialStep(
            number: 3,
            systemImage: "hand.raised.fill",
            title: "Hold still on cue",
            body: "With Auto-capture on, Personal Eyes says \"Stop. Stop. Stop.\" when an object is ready, then captures after a brief hold. With Auto-capture off, tap the shutter whenever you are ready."
        ),
        TutorialStep(
            number: 4,
            systemImage: "sparkles",
            title: "Hear the response",
            body: "Personal Eyes reads a clear, short on-device description by default. A pop-up shows the full text — press OK when you are done. Turn off \"Detailed description\" in Options if you prefer a quick three-word reply."
        ),
        TutorialStep(
            number: 5,
            systemImage: "questionmark.bubble",
            title: "Ask your own questions",
            body: "Open Options to add questions like \"What color is this?\" or \"What does the sign say?\". When Apple Intelligence is available, Personal Eyes answers them with every capture."
        )
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    headline
                    ForEach(steps) { step in
                        TutorialStepRow(step: step)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isFirstLaunch ? "Welcome" : "How it Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isFirstLaunch {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done", action: onDone)
                            .fontWeight(.semibold)
                            .accessibilityHint("Closes the tutorial")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        onDone()
                    } label: {
                        Text(isFirstLaunch ? "Get Started" : "Close Tutorial")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.personalEyesAccent)
                    .foregroundStyle(Color(.systemBackground))
                    .accessibilityLabel(isFirstLaunch ? "Get started" : "Close tutorial")
                    .accessibilityHint("Returns to the main screen. The camera stays off until you tap the shutter.")
                }
            }
        }
        .tint(Color.personalEyesAccent)
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(isFirstLaunch)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Personal Eyes")
                .font(.largeTitle.bold())
            Text("Local AI for blind users. Aim, listen, and capture.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct TutorialStep: Identifiable {
    let id = UUID()
    let number: Int
    let systemImage: String
    let title: String
    let body: String
}

private struct TutorialStepRow: View {
    let step: TutorialStep

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.personalEyesAccent.opacity(0.18))

                Image(systemName: step.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.personalEyesAccent)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Step \(step.number). \(step.title)")
                    .font(.headline)
                Text(step.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.24), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.number). \(step.title). \(step.body)")
    }
}
