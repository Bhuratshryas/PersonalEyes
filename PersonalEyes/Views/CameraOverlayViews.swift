import SwiftUI
import UIKit

/// Creative bounding box that tracks the detected object (YOLO-style overlay).
/// Vision boxes use a bottom-left origin; SwiftUI uses top-left, so Y is flipped.
struct ObjectBoundingBoxOverlay: View {
    var box: CGRect?
    var isCentered: Bool
    var isHolding: Bool
    var isProcessing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Soft vignette toward the tracked subject.
                if let box {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: isCentered
                                    ? [Color.white, Color.white.opacity(0.55)]
                                    : [Color.white.opacity(0.85), Color.white.opacity(0.25)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: isHolding ? 3.5 : 2.2, lineJoin: .round)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(isCentered ? 0.10 : 0.04))
                        )
                        .frame(width: boxWidth(in: geo.size), height: boxHeight(in: geo.size))
                        .position(boxCenter(in: geo.size))
                        .shadow(color: .white.opacity(isCentered ? 0.35 : 0.12), radius: isCentered ? 16 : 8)

                    // Corner brackets for a "creative box" look.
                    CornerBrackets(isCentered: isCentered)
                        .frame(width: boxWidth(in: geo.size), height: boxHeight(in: geo.size))
                        .position(boxCenter(in: geo.size))
                }

                // Fixed frame center crosshair — the target the box must enter.
                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .opacity(isProcessing ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: box)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isCentered)
        .accessibilityHidden(true)
    }

    private func boxCenter(in size: CGSize) -> CGPoint {
        guard let box else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        return CGPoint(
            x: box.midX * size.width,
            y: (1 - box.midY) * size.height
        )
    }

    private func boxWidth(in size: CGSize) -> CGFloat {
        guard let box else { return 0 }
        return max(48, box.width * size.width)
    }

    private func boxHeight(in size: CGSize) -> CGFloat {
        guard let box else { return 0 }
        return max(48, box.height * size.height)
    }
}

private struct CornerBrackets: View {
    var isCentered: Bool

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 6
            let arm: CGFloat = min(size.width, size.height) * 0.18
            let color = Color.white.opacity(isCentered ? 0.95 : 0.7)
            var path = Path()
            // Top-left
            path.move(to: CGPoint(x: inset, y: inset + arm))
            path.addLine(to: CGPoint(x: inset, y: inset))
            path.addLine(to: CGPoint(x: inset + arm, y: inset))
            // Top-right
            path.move(to: CGPoint(x: size.width - inset - arm, y: inset))
            path.addLine(to: CGPoint(x: size.width - inset, y: inset))
            path.addLine(to: CGPoint(x: size.width - inset, y: inset + arm))
            // Bottom-left
            path.move(to: CGPoint(x: inset, y: size.height - inset - arm))
            path.addLine(to: CGPoint(x: inset, y: size.height - inset))
            path.addLine(to: CGPoint(x: inset + arm, y: size.height - inset))
            // Bottom-right
            path.move(to: CGPoint(x: size.width - inset - arm, y: size.height - inset))
            path.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
            path.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset - arm))
            context.stroke(path, with: .color(color), lineWidth: 2.5)
        }
    }
}

struct CenteringReticleView: View {
    var distance: Float
    var hasSubject: Bool
    var isHolding: Bool
    var isProcessing: Bool

    var body: some View {
        // Retained for compatibility; live framing now uses ObjectBoundingBoxOverlay.
        Color.clear
            .opacity(isProcessing ? 0 : 0)
            .accessibilityHidden(true)
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
        .accessibilityLabel("\(title). \(subtitle)")
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

struct UnavailableCameraView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.personalEyesAccent)
                .accessibilityHidden(true)

            Text("Camera unavailable")
                .font(.title2.bold())

            Text("Personal Eyes could not find a usable camera on this device. Try again on an iPhone with a working rear camera.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Camera unavailable. Personal Eyes could not find a usable camera on this device.")
    }
}

/// In-camera result panel — replaces the system alert so the answer matches the dark capture UI.
struct ResultPanel: View {
    let title: String
    let summary: String
    let note: String?
    let thumbnail: UIImage?
    let usedAppleIntelligence: Bool
    let primaryButtonTitle: String
    let onHearAgain: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 148)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                            }
                            .accessibilityHidden(true)
                    }

                    ScrollView {
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 220)

                    if let note, !note.isEmpty {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 10) {
                        Button(action: onHearAgain) {
                            Label("Hear Again", systemImage: "speaker.wave.2.fill")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                        .accessibilityHint("Reads the description aloud again")

                        Button(action: onDismiss) {
                            Text(primaryButtonTitle)
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityHint(
                            primaryButtonTitle == "Finish practice"
                                ? "Ends practice and keeps the camera ready"
                                : "Dismisses the result and aims for the next photo"
                        )
                    }
                }
                .padding(22)
                .frame(maxWidth: 380)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 24)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: usedAppleIntelligence ? "sparkles" : "eye.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.personalEyesAccent)
                .frame(width: 40, height: 40)
                .background(Color.personalEyesAccent.opacity(0.18), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(usedAppleIntelligence ? "Apple Intelligence" : "On-device Vision")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title). \(usedAppleIntelligence ? "Apple Intelligence" : "On-device Vision")"
        )
        .accessibilityAddTraits(.isHeader)
    }
}
