import SwiftUI

@main
struct TraceApp: App {
    @State private var notionService = NotionService.shared
    @State private var locationManager = LocationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(notionService)
                .environment(locationManager)
                .task {
                    await notionService.fetchPlaces()
                    await notionService.fetchVisits()
                    await notionService.fetchCaptures()
                }
        }
    }
}
