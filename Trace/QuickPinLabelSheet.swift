import SwiftUI
import CoreLocation

struct QuickPinLabelSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let coord: CLLocationCoordinate2D

    @State private var countdown = 4
    @State private var isSaving = false
    @State private var countdownTimer: Timer?

    private struct PinLabel {
        let label: String?   // nil = time-only
        let emoji: String?   // prepended to capture name; nil = no emoji
        let icon: String
        var display: String { label ?? "Time only" }
    }

    private let pinLabels: [PinLabel] = [
        .init(label: "Photo Spot", emoji: "📸", icon: "camera.fill"),
        .init(label: "Scenic",     emoji: "🌄", icon: "eye.fill"),
        .init(label: "Notable",    emoji: "⭐",  icon: "star.fill"),
        .init(label: "Parked",     emoji: "🚗", icon: "car.fill"),
        .init(label: "Address",    emoji: "📍", icon: "mappin"),
        .init(label: nil,          emoji: nil,  icon: "clock")
    ]

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Quick Pin")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    countdownTimer?.invalidate()
                    dismiss()
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 20)

            // 3×2 grid of label buttons
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                ForEach(pinLabels, id: \.display) { pin in
                    let isTimeOnly = pin.label == nil
                    Button {
                        save(label: pin.label, emoji: pin.emoji)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: pin.icon)
                                .font(.title2)
                            if isTimeOnly {
                                Text(countdown > 0 ? "(\(countdown)s)" : "Time only")
                                    .font(.caption)
                                    .foregroundStyle(countdown > 0 ? Color.orange : Color.primary)
                            } else {
                                Text(pin.display)
                                    .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            isTimeOnly && countdown > 0
                                ? Color.orange.opacity(0.15)
                                : Color.secondary.opacity(0.1)
                        )
                        .foregroundStyle(
                            isTimeOnly && countdown > 0 ? Color.orange : Color.primary
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                }
            }
            .padding(.horizontal)

            if isSaving {
                ProgressView("Saving…")
                    .padding(.top, 4)
            }

            Spacer(minLength: 8)
        }
        .padding(.bottom, 20)
        .onAppear { startCountdown() }
        .onDisappear { countdownTimer?.invalidate() }
    }

    // MARK: - Countdown

    private func startCountdown() {
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countdown > 1 {
                countdown -= 1
            } else {
                t.invalidate()
                save(label: nil, emoji: nil)   // auto-fire time-only
            }
        }
    }

    // MARK: - Save

    private func save(label: String?, emoji: String? = nil) {
        countdownTimer?.invalidate()
        guard !isSaving else { return }
        isSaving = true

        Task {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            let timeStr = formatter.string(from: Date())
            let captureName: String
            if let label {
                let prefix = emoji.map { "\($0) " } ?? ""
                captureName = "\(prefix)\(label) · \(timeStr)"
            } else {
                captureName = timeStr
            }

            // Use fresh location if available, fall back to coord passed at open time
            let saveCoord = LocationManager.shared.location?.coordinate ?? coord

            // Auto-link to nearest Trace place within 500 m
            let pinLoc = CLLocation(latitude: saveCoord.latitude, longitude: saveCoord.longitude)
            let nearbyPlace = notion.places.filter { p in
                CLLocation(latitude: p.latitude, longitude: p.longitude).distance(from: pinLoc) <= 500
            }.min { a, b in
                CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: pinLoc)
                    < CLLocation(latitude: b.latitude, longitude: b.longitude).distance(from: pinLoc)
            }

            try? await notion.saveCapture(
                notes: captureName,
                placeID: nearbyPlace?.id,
                placeName: captureName,
                lat: saveCoord.latitude,
                lon: saveCoord.longitude,
                photoURL: nil
            )
            await notion.fetchCaptures()
            dismiss()
        }
    }
}
