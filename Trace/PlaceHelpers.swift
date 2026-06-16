import SwiftUI

func placeColor(for category: String) -> Color {
    switch category.lowercased() {
    case "restaurant": return .orange
    case "bar": return .purple
    case "cafe": return .brown
    case "hotel": return .teal
    case "shop": return .pink
    case "attraction": return .red
    case "venue": return .indigo
    case "house": return .yellow
    case "temp": return .gray
    case "fitness": return .green
    default: return .gray
    }
}

func placeIcon(for category: String) -> String {
    switch category.lowercased() {
    case "restaurant": return "fork.knife"
    case "bar": return "wineglass"
    case "cafe": return "cup.and.saucer"
    case "hotel": return "bed.double"
    case "shop": return "bag"
    case "attraction": return "star"
    case "venue": return "music.mic"
    case "house": return "house"
    case "temp": return "clock"
    case "fitness": return "figure.run"
    default: return "mappin"
    }
}

// MARK: - Place pin

struct PlacePin: View {
    let place: Place

    var body: some View {
        ZStack {
            Circle()
                .fill(place.flagged ? Color.yellow : placeColor(for: place.category))
                .frame(width: 32, height: 32)
            Image(systemName: placeIcon(for: place.category))
                .font(.system(size: 14))
                .foregroundStyle(.white)
        }
        .shadow(radius: 3)
    }
}
