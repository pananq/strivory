import Foundation
import HealthKit

enum HealthKitServiceError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: L.text("health.unavailable")
        }
    }
}

@MainActor
final class HealthKitService {
    private let store = HKHealthStore()

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitServiceError.unavailable }
        try await store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType()])
    }

    func fetchWorkouts() async throws -> [WorkoutRecord] {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitServiceError.unavailable }
        let type = HKObjectType.workoutType()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let workouts = (samples as? [HKWorkout] ?? []).compactMap { workout -> WorkoutRecord? in
                    let duration = workout.duration
                    guard duration >= 600 else { return nil }
                    let energy = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0
                    return WorkoutRecord(id: workout.uuid, startDate: workout.startDate, category: Self.category(for: workout.workoutActivityType), duration: duration, activeEnergy: energy, source: .healthKit)
                }
                continuation.resume(returning: Self.deduplicated(workouts))
            }
            self.store.execute(query)
        }
    }

    nonisolated private static func category(for type: HKWorkoutActivityType) -> WorkoutCategory {
        switch type {
        case .traditionalStrengthTraining, .functionalStrengthTraining, .highIntensityIntervalTraining, .crossTraining, .coreTraining, .mixedCardio:
            return .strength
        case .running, .wheelchairRunPace:
            return .running
        case .cycling, .handCycling:
            return .cycling
        case .swimming, .waterFitness:
            return .swimming
        case .americanFootball, .australianFootball, .badminton, .baseball, .basketball, .cricket, .handball, .hockey, .lacrosse, .pickleball, .racquetball, .rugby, .soccer, .softball, .squash, .tableTennis, .tennis, .volleyball, .waterPolo:
            return .ballSports
        case .skatingSports, .surfingSports, .snowboarding:
            return .boardSports
        case .hiking, .walking, .climbing, .crossCountrySkiing, .downhillSkiing, .snowSports, .paddleSports, .sailing, .wheelchairWalkPace:
            return .outdoors
        case .yoga, .pilates, .taiChi, .mindAndBody, .barre, .flexibility:
            return .mindBody
        case .dance, .danceInspiredTraining, .cardioDance, .socialDance:
            return .dance
        case .boxing, .martialArts, .kickboxing, .wrestling, .fencing:
            return .combat
        case .rowing:
            return .rowing
        default:
            return .other
        }
    }

    nonisolated private static func deduplicated(_ records: [WorkoutRecord]) -> [WorkoutRecord] {
        records.sorted { $0.startDate < $1.startDate }.reduce(into: [WorkoutRecord]()) { accepted, candidate in
            let duplicate = accepted.contains { existing in
                existing.category == candidate.category &&
                abs(existing.startDate.timeIntervalSince(candidate.startDate)) <= 120 &&
                abs(existing.duration - candidate.duration) <= 300
            }
            if !duplicate { accepted.append(candidate) }
        }
    }
}
