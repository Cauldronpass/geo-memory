import Combine
import HealthKit
import SwiftUI

/// Reads today's Apple Watch activity summary (Move / Exercise / Stand) from HealthKit.
/// Updates on app launch, foreground, and every 15 minutes via HomeView's timer.
class HealthKitService: ObservableObject {

    static let shared = HealthKitService()

    // MARK: - Published state

    @Published var moveCalories: Double?      // active energy burned today (kcal)
    @Published var moveGoal: Double?          // daily move goal (kcal)
    @Published var exerciseMinutes: Double?   // apple exercise time (min)
    @Published var exerciseGoal: Double?      // exercise goal (min, default 30)
    @Published var standHours: Double?        // stand hours today
    @Published var standGoal: Double?         // stand goal (hrs, default 12)
    @Published var isAvailable: Bool = HKHealthStore.isHealthDataAvailable()

    // MARK: - Private

    private let store = HKHealthStore()
    private var authorized = false

    // MARK: - Public API

    func requestAuthorizationAndFetch() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard !authorized else { await fetchToday(); return }

        let readTypes: Set<HKObjectType> = [HKObjectType.activitySummaryType()]

        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            authorized = true
            await fetchToday()
        } catch {
            print("[HealthKitService] Auth error: \(error)")
        }
    }

    func fetchToday() async {
        guard HKHealthStore.isHealthDataAvailable(), authorized else { return }

        var comps = Calendar.current.dateComponents([.year, .month, .day, .era, .calendar], from: Date())
        comps.calendar = Calendar.current

        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: comps, end: comps)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let query = HKActivitySummaryQuery(predicate: predicate) { [weak self] _, summaries, error in
                defer { continuation.resume() }
                guard let self, let summary = summaries?.first, error == nil else { return }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.moveCalories    = summary.activeEnergyBurned.doubleValue(for: .kilocalorie())
                    self.moveGoal        = summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())
                    self.exerciseMinutes = summary.appleExerciseTime.doubleValue(for: .minute())
                    self.exerciseGoal    = summary.appleExerciseTimeGoal.doubleValue(for: .minute())
                    self.standHours      = summary.appleStandHours.doubleValue(for: .count())
                    self.standGoal       = summary.appleStandHoursGoal.doubleValue(for: .count())
                }
            }
            store.execute(query)
        }
    }

    // MARK: - Helpers

    /// 0.0 → 1.0+ progress for a ring. Returns nil if no data.
    func moveProgress() -> Double? {
        guard let v = moveCalories, let g = moveGoal, g > 0 else { return nil }
        return v / g
    }

    func exerciseProgress() -> Double? {
        guard let v = exerciseMinutes, let g = exerciseGoal, g > 0 else { return nil }
        return v / g
    }

    func standProgress() -> Double? {
        guard let v = standHours, let g = standGoal, g > 0 else { return nil }
        return v / g
    }
}
