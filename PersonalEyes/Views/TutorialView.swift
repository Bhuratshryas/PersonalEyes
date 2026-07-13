import SwiftUI

enum TutorialDismissal {
    /// First-launch user is ready to practice with the live camera.
    case startPractice
    /// Returning user closed the how-to sheet.
    case close
}

struct TutorialView: View {
    let isFirstLaunch: Bool
    let onDismiss: (TutorialDismissal) -> Void

    private var steps: [TutorialStep] {
        if isFirstLaunch {
            return practiceSteps
        }
        return referenceSteps
    }

    private let practiceSteps: [TutorialStep] = [
        TutorialStep(
            number: 1,
            systemImage: "hand.wave.fill",
            title: "Welcome",
            body: "Personal Eyes describes what your camera sees, on your iPhone. Next you’ll practice with a real object nearby."
        ),
        TutorialStep(
            number: 2,
            systemImage: "camera.fill",
            title: "Camera turns on for you",
            body: "After this screen, the camera opens automatically. Hold the phone upright and point it at something on a table, like a cup, book, or remote."
        ),
        TutorialStep(
            number: 3,
            systemImage: "viewfinder.rectangular",
            title: "Center the object",
            body: "Listen for Left, Right, Up, or Down. When you hear \"Object centered,\" tap the round shutter button to take the picture."
        ),
        TutorialStep(
            number: 4,
            systemImage: "ear.fill",
            title: "Hear the answer",
            body: "Personal Eyes describes what the photo shows. That practice capture finishes the tutorial."
        )
    ]

    private let referenceSteps: [TutorialStep] = [
        TutorialStep(
            number: 1,
            systemImage: "camera.fill",
            title: "Camera stays ready",
            body: "When you open Personal Eyes, the camera turns on so you can aim right away. Tap the shutter when an object is centered."
        ),
        TutorialStep(
            number: 2,
            systemImage: "viewfinder.rectangular",
            title: "Follow the object box",
            body: "A box tracks the main object. Beeps get faster as it nears the center. Direction cues say Left, Right, Up, Down, then Object centered."
        ),
        TutorialStep(
            number: 3,
            systemImage: "sparkles",
            title: "Hear the description",
            body: "Each capture describes what the photo shows. Press OK to aim again."
        ),
        TutorialStep(
            number: 4,
            systemImage: "slider.horizontal.3",
            title: "Options",
            body: "In Options you can turn on Auto-capture, change aiming sounds, and add extra questions."
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
                        Button("Done") {
                            onDismiss(.close)
                        }
                        .fontWeight(.semibold)
                        .accessibilityHint("Closes the tutorial and returns to the camera")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        onDismiss(isFirstLaunch ? .startPractice : .close)
                    } label: {
                        Text(isFirstLaunch ? "Start practice" : "Close Tutorial")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.personalEyesAccent)
                    .foregroundStyle(Color(.systemBackground))
                    .accessibilityLabel(isFirstLaunch ? "Start practice" : "Close tutorial")
                    .accessibilityHint(
                        isFirstLaunch
                            ? "Turns on the camera so you can practice identifying an object"
                            : "Returns to the live camera"
                    )
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
            Text(
                isFirstLaunch
                    ? "Let’s practice identifying something with your camera."
                    : "Local AI for blind users. Aim, listen, and capture."
            )
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
