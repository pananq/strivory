import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var healthRecords: [WorkoutRecord] = []
    @Published private(set) var importBatches: [CSVImportBatch] = []
    @Published private(set) var isLoadingHealth = false
    @Published var healthMessage: String?
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.storageKey) }
    }
    @Published var userName: String {
        didSet { UserDefaults.standard.set(userName, forKey: Self.userNameKey) }
    }

    private let healthKit = HealthKitService()
    private static let batchesKey = "strivory.csv.batches"
    private static let userNameKey = "strivory.user.name"

    init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? "") ?? .simplifiedChinese
        userName = UserDefaults.standard.string(forKey: Self.userNameKey) ?? L.text("export.defaultName")
        loadBatches()
    }

    func requestHealthAccessAndRefresh() async {
        guard !isLoadingHealth else { return }
        isLoadingHealth = true
        defer { isLoadingHealth = false }
        do {
            try await healthKit.requestAuthorization()
            healthRecords = try await healthKit.fetchWorkouts()
            healthMessage = healthRecords.isEmpty
                ? L.text("health.empty")
                : L.text("health.updated", healthRecords.count)
        } catch {
            healthMessage = error.localizedDescription
        }
    }

    func importCSV(_ result: CSVParseResult, strategy: CSVImportStrategy) {
        let batchID = UUID()
        let records = result.records.map {
            WorkoutRecord(id: $0.id, startDate: $0.startDate, category: $0.category, duration: $0.duration, activeEnergy: 0, source: .csv, batchID: batchID)
        }
        guard !records.isEmpty else { return }
        importBatches.append(CSVImportBatch(id: batchID, name: result.fileName, createdAt: .now, strategy: strategy, records: records))
        saveBatches()
    }

    func deleteBatch(_ batch: CSVImportBatch) {
        importBatches.removeAll { $0.id == batch.id }
        saveBatches()
    }

    func summary(for year: Int) -> YearSummary {
        let calendar = CalendarSupport.mondayCalendar
        var healthByDay: [Date: [WorkoutRecord]] = [:]
        for record in healthRecords where calendar.component(.year, from: record.startDate) == year {
            healthByDay[CalendarSupport.startOfDay(record.startDate), default: []].append(record)
        }

        var importedByDay: [Date: [(record: WorkoutRecord, batch: CSVImportBatch)]] = [:]
        for batch in importBatches {
            for record in batch.records where calendar.component(.year, from: record.startDate) == year {
                importedByDay[CalendarSupport.startOfDay(record.startDate), default: []].append((record, batch))
            }
        }

        let allDays = Set(healthByDay.keys).union(importedByDay.keys)
        var dailyActivities: [Date: DailyActivity] = [:]
        for day in allDays {
            let health = healthByDay[day] ?? []
            let imports = (importedByDay[day] ?? []).sorted { $0.batch.createdAt > $1.batch.createdAt }
            if let override = imports.first(where: { $0.batch.strategy == .override }) {
                dailyActivities[day] = DailyActivity(date: day, category: override.record.category, source: .csv, records: [override.record])
                continue
            }
            if !health.isEmpty, let primary = primaryHealthActivity(on: day, records: health) {
                dailyActivities[day] = primary
                continue
            }
            if let imported = imports.first {
                dailyActivities[day] = DailyActivity(date: day, category: imported.record.category, source: .csv, records: [imported.record])
            }
        }

        let counts = dailyActivities.values.reduce(into: [WorkoutCategory: Int]()) { partial, activity in
            partial[activity.category, default: 0] += 1
        }
        let top = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
        }.prefix(4).map(\.key)
        return YearSummary(year: year, dailyActivities: dailyActivities, categoryCounts: counts, topCategories: top)
    }

    var availableYears: [Int] {
        let years = Set(healthRecords.map { CalendarSupport.year(for: $0.startDate) })
            .union(importBatches.flatMap { $0.records.map { CalendarSupport.year(for: $0.startDate) } })
        let current = CalendarSupport.year(for: .now)
        return Array(years.union([current])).sorted(by: >)
    }

    var exportName: String {
        let cleaned = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "的"))
        return cleaned.isEmpty ? L.text("export.defaultName") : cleaned
    }

    private func primaryHealthActivity(on day: Date, records: [WorkoutRecord]) -> DailyActivity? {
        let grouped = Dictionary(grouping: records, by: \.category)
        guard let best = grouped.max(by: { lhs, rhs in
            let leftDuration = lhs.value.reduce(0) { $0 + $1.duration }
            let rightDuration = rhs.value.reduce(0) { $0 + $1.duration }
            if leftDuration == rightDuration {
                let leftEnergy = lhs.value.reduce(0) { $0 + $1.activeEnergy }
                let rightEnergy = rhs.value.reduce(0) { $0 + $1.activeEnergy }
                return leftEnergy < rightEnergy
            }
            return leftDuration < rightDuration
        }) else { return nil }
        return DailyActivity(date: day, category: best.key, source: .healthKit, records: best.value)
    }

    private func saveBatches() {
        if let data = try? JSONEncoder().encode(importBatches) {
            UserDefaults.standard.set(data, forKey: Self.batchesKey)
        }
    }

    private func loadBatches() {
        guard let data = UserDefaults.standard.data(forKey: Self.batchesKey),
              let decoded = try? JSONDecoder().decode([CSVImportBatch].self, from: data) else { return }
        importBatches = decoded
    }
}
