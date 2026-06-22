import SwiftUI

// MARK: - Flow Layout (wrapping chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews: subviews, in: proposal.replacingUnspecifiedDimensions().width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, in: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private struct LayoutResult {
        var frames: [CGRect]
        var size: CGSize
    }

    private func layout(subviews: Subviews, in maxWidth: CGFloat) -> LayoutResult {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
        return LayoutResult(frames: frames, size: CGSize(width: maxWidth, height: y + lineHeight))
    }
}

// MARK: - Place colors

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

// MARK: - Super-category system (4 groups for calendar display)

func superCategoryColor(for category: String) -> Color {
    switch category.lowercased() {
    case "restaurant", "cafe", "bar", "grocery": return .orange
    case "fitness", "park", "medical":            return .green
    case "attraction", "venue", "hotel", "airport": return .indigo
    default: return Color(.systemGray)  // house, office, shop, temp, uncategorized
    }
}

func superCategoryName(for category: String) -> String {
    switch category.lowercased() {
    case "restaurant", "cafe", "bar", "grocery":    return "Food & Drink"
    case "fitness", "park", "medical":              return "Active & Health"
    case "attraction", "venue", "hotel", "airport": return "Out & About"
    default:                                         return "Everyday"
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
