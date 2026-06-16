import SwiftUI

struct ContentView: View {
    @State private var showingActionSheet = false
    @State private var selectedTab = 0
    @State private var showingCheckIn = false
    @State private var showingAddPlace = false
    @State private var showingAddCapture = false
    @State private var showingDrawer = false
    @State private var showingAddPhoto = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedTab) {
                MapView()
                    .tabItem { Label("Map", systemImage: "map.fill") }
                    .tag(0)
                NearbyView()
                    .tabItem { Label("Nearby", systemImage: "location.fill") }
                    .tag(1)
                DiscoverView()
                    .tabItem { Label("Discover", systemImage: "magnifyingglass") }
                    .tag(2)
                VisitsView()
                    .tabItem { Label("Visits", systemImage: "clock.arrow.circlepath") }
                    .tag(3)
                FlaggedView()
                    .tabItem { Label("Pinned", systemImage: "pin.fill") }
            }

            Button(action: { showingActionSheet = true }) {
                Image(systemName: "plus")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 80)
            .confirmationDialog("What would you like to do?", isPresented: $showingActionSheet,
                titleVisibility: .visible) {
                Button("Check In") { showingCheckIn = true }
                Button("Add Place") { showingAddPlace = true }
                Button("Add Note") { showingAddCapture = true }
                Button("Add Photo") { showingAddPhoto = true }
                Button("Cancel", role: .cancel) { }
            }
        }
        .sheet(isPresented: $showingCheckIn) {
            CheckInView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingAddPlace) {
            AddPlaceView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingAddCapture) {
            AddCaptureView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingAddPhoto) {
            AddPhotoView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .overlay {
            ZStack {
                if showingDrawer {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.3)) { showingDrawer = false }
                        }
                    HStack(spacing: 0) {
                        Spacer()
                        CapturesDrawerView(isShowing: $showingDrawer)
                            .environment(NotionService.shared)
                            .frame(width: UIScreen.main.bounds.width * 0.85)
                            .background(Color(UIColor.systemBackground))
                            .ignoresSafeArea()
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showingDrawer)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .local)
                        .onEnded { value in
                            if value.translation.width < -10 {
                                withAnimation(.easeInOut(duration: 0.3)) { showingDrawer = true }
                            }
                        }
                )
        }
    }
}

#Preview {
    ContentView()
}

