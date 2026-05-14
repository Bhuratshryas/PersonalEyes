import SwiftUI

struct CenteringReticleView: View {
    var distance: Float
    var hasSubject: Bool
    var isHolding: Bool
    var isProcessing: Bool

    var body: some View {
        ZStack {
            outerRing
                .stroke(reticleColor.opacity(hasSubject ? 0.95 : 0.45), lineWidth: isHolding ? 4 : 2.5)
                .frame(width: 230, height: 230)

            outerRing
                .stroke(reticleColor.opacity(isHolding ? 0.32 : 0.18), lineWidth: isHolding ? 22 : 16)
                .frame(width: 230, height: 230)
                .blur(radius: isHolding ? 4 : 8)

            innerCrosshair
                .stroke(reticleColor.opacity(0.85), lineWidth: 2)
                .frame(width: 36, height: 36)

            Circle()
                .fill(reticleColor.opacity(0.85))
                .frame(width: 6, height: 6)
        }
        .compositingGroup()
        .opacity(isProcessing ? 0.0 : 1.0)
        .scaleEffect(isHolding ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: distance)
        .animation(.easeInOut(duration: 0.25), value: hasSubject)
        .animation(.easeInOut(duration: 0.25), value: isProcessing)
        .animation(.easeOut(duration: 0.4), value: isHolding)
        .accessibilityHidden(true)
    }

    private var reticleColor: Color {
        // Pure monochrome reticle: brighter white when the subject is found,
        // softer when nothing is detected.
        if !hasSubject { return Color.white.opacity(0.55) }
        let clamped = max(0, min(1, Double(distance)))
        return Color.white.opacity(1.0 - clamped * 0.35)
    }

    private var outerRing: some Shape {
        Circle()
    }

    private var innerCrosshair: some Shape {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 18))
            path.addLine(to: CGPoint(x: 36, y: 18))
            path.move(to: CGPoint(x: 18, y: 0))
            path.addLine(to: CGPoint(x: 18, y: 36))
        }
    }
}

struct StatusBanner: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.personalEyesAccent)
                .frame(width: 36, height: 36)
                .background(Color.personalEyesAccent.opacity(0.18), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color.black.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ShutterButton: View {
    var isProcessing: Bool
    /// When true, the next tap starts the camera instead of taking a photo.
    var opensCamera: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 4)
                    .frame(width: 78, height: 78)

                Circle()
                    .fill(isProcessing ? Color.white.opacity(0.5) : Color.white)
                    .frame(width: 64, height: 64)

                if isProcessing {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.personalEyesAccent)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint(accessibilityDetail)
    }

    private var accessibilityTitle: String {
        if isProcessing { return "Analyzing" }
        return opensCamera ? "Open camera" : "Capture image"
    }

    private var accessibilityDetail: String {
        if isProcessing {
            return "Personal Eyes is reading the photo."
        }
        if opensCamera {
            return "Turns on the camera. Tap again when you are ready to take the picture."
        }
        return "Takes a picture and reads what it sees aloud."
    }
}

struct UnauthorizedCameraView: View {
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.personalEyesAccent)
                .accessibilityHidden(true)

            Text("Camera access needed")
                .font(.title2.bold())

            Text("Personal Eyes needs the camera to describe what is in front of you. Enable Camera in Settings to continue.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.personalEyesAccent)
                .foregroundStyle(Color(.systemBackground))
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .contain)
    }
}
