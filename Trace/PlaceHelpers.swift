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
    case "office": return .blue
    case "airport": return .cyan
    case "medical": return .mint
    case "park": return Color(red: 0.2, green: 0.6, blue: 0.15)
    case "grocery": return Color(red: 0.8, green: 0.45, blue: 0.0)
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
    case "office": return "building.2"
    case "airport": return "airplane"
    case "medical": return "stethoscope"
    case "park": return "leaf"
    case "grocery": return "cart"
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
