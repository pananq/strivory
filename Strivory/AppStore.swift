import Foundation
import Combine
import CloudKit

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var healthRecords: [WorkoutRecord] = []
    @Published private(set) var healthArchive: [WorkoutRecord] = []
    @Published private(set) var importBatches: [CSVImportBatch] = []
    @Published private(set) var isLoadingHealth = false
    @Published private(set) var isSyncingICloud = false
    @Published private(set) var iCloudBackupState: ICloudBackupState = .checking
    @Published private(set) var hasICloudBackup = false
    @Published var iCloudRestoreAvailable = false
    @Published var healthMessage: String?
    @Published private(set) var iCloudErrorMessage: String?
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.storageKey) }
    }
    @Published var userName: String {
        didSet {
            guard !isApplyingBackupSnapshot else { return }
            UserDefaults.standard.set(userName, forKey: Self.userNameKey)
            userNameUpdatedAt = .now
            UserDefaults.standard.set(userNameUpdatedAt, forKey: Self.userNameUpdatedAtKey)
            scheduleICloudSync()
        }
    }
    @Published var iCloudBackupEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudBackupEnabled, forKey: Self.iCloudBackupEnabledKey)
            if iCloudBackupEnabled { scheduleICloudSync() }
            else { iCloudBackupState = .disabled }
        }
    }

    private let healthKit = HealthKitService()
    private let cloudBackup = CloudBackupService()
    private static let batchesKey = "strivory.csv.batches"
    private static let healthArchiveKey = "strivory.health.archive"
    private static let healthAnchorKey = "strivory.health.anchor"
    private static let deletedBatchDatesKey = "strivory.csv.deleted-batches"
    private static let userNameKey = "strivory.user.name"
    private static let userNameUpdatedAtKey = "strivory.user.name.updated-at"
    private static let iCloudBackupEnabledKey = "strivory.icloud-backup.enabled"
    private static let lastAutomaticICloudBackupKey = "strivory.icloud-backup.last-automatic"
    private var deletedBatchDates: [String: Date] = [:]
    private var healthAnchorData: Data?
    private var userNameUpdatedAt: Date
    private var isApplyingBackupSnapshot = false

    init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? "") ?? .simplifiedChinese
        userName = UserDefaults.standard.string(forKey: Self.userNameKey) ?? L.text("export.defaultName")
        userNameUpdatedAt = UserDefaults.standard.object(forKey: Self.userNameUpdatedAtKey) as? Date ?? .now
        iCloudBackupEnabled = UserDefaults.standard.bool(forKey: Self.iCloudBackupEnabledKey)
        loadBatches()
        loadHealthArchive()
        loadHealthAnchor()
        loadDeletedBatchDates()
        Task { await prepareICloudBackup() }
    }

    func requestHealthAccessAndRefresh() async {
        guard !isLoadingHealth else { return }
        isLoadingHealth = true
        defer { isLoadingHealth = false }
        do {
            try await healthKit.requestAuthorization()
            let result = try await healthKit.fetchWorkouts(anchorData: healthAnchorData)
            if healthAnchorData == nil {
                replaceHealthArchive(with: result.workouts)
            } else {
                applyHealthChanges(result.workouts, deletedIDs: result.deletedWorkoutIDs)
            }
            healthAnchorData = result.anchorData
            UserDefaults.standard.set(result.anchorData, forKey: Self.healthAnchorKey)
            healthRecords = healthArchive
            healthMessage = healthRecords.isEmpty
                ? L.text("health.empty")
                : L.text("health.updated", healthRecords.count)
            scheduleICloudSync()
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
        scheduleICloudSync()
    }

    func deleteBatch(_ batch: CSVImportBatch) {
        importBatches.removeAll { $0.id == batch.id }
        deletedBatchDates[batch.id.uuidString] = .now
        saveBatches()
        saveDeletedBatchDates()
        scheduleICloudSync()
    }

    func summary(for year: Int) -> YearSummary {
        let calendar = CalendarSupport.mondayCalendar
        var healthByDay: [Date: [WorkoutRecord]] = [:]
        for record in calendarRecords where calendar.component(.year, from: record.startDate) == year {
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
        let years = Set(calendarRecords.map { CalendarSupport.year(for: $0.startDate) })
            .union(importBatches.flatMap { $0.records.map { CalendarSupport.year(for: $0.startDate) } })
        let current = CalendarSupport.year(for: .now)
        return Array(years.union([current])).sorted(by: >)
    }

    var exportName: String {
        let cleaned = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "的"))
        return cleaned.isEmpty ? L.text("export.defaultName") : cleaned
    }

    var iCloudBackupStatusText: String {
        switch iCloudBackupState {
        case .checking: return L.text("icloud.status.checking")
        case .disabled: return L.text("icloud.status.disabled")
        case .ready(let date):
            return date.map { L.text("icloud.status.ready", CalendarSupport.dateText($0, style: .short)) }
                ?? L.text("icloud.status.readyWithoutDate")
        case .unavailable: return L.text("icloud.status.unavailable")
        case .failed: return iCloudErrorMessage ?? L.text("icloud.status.failed")
        }
    }

    func prepareICloudBackup() async {
        iCloudBackupState = .checking
        iCloudErrorMessage = nil
        guard await cloudBackup.isAccountAvailable() else {
            iCloudBackupState = .unavailable
            return
        }
        do {
            let remote = try await cloudBackup.load()
            hasICloudBackup = remote != nil
            if let remote, importBatches.isEmpty, healthArchive.isEmpty {
                iCloudRestoreAvailable = !remote.healthArchive.isEmpty || !remote.importBatches.isEmpty
            }
            iCloudBackupState = iCloudBackupEnabled
                ? .ready(lastBackup: remote?.updatedAt)
                : .disabled
        } catch {
            iCloudBackupState = .failed
            recordICloudFailure(error)
        }
    }

    func syncICloudBackup() async {
        await syncICloudBackup(force: true)
    }

    /// Automatic backups run at most once per local calendar day. The manual
    /// action bypasses this limit so users can protect a change immediately.
    func syncICloudBackup(force: Bool) async {
        guard iCloudBackupEnabled, !isSyncingICloud else { return }
        guard force || isAutomaticICloudBackupDue else { return }
        isSyncingICloud = true
        defer { isSyncingICloud = false }
        do {
            let merged = try await cloudBackup.sync(local: backupSnapshot())
            applyBackupSnapshot(merged)
            hasICloudBackup = true
            iCloudBackupState = .ready(lastBackup: merged.updatedAt)
            iCloudErrorMessage = nil
            if !force {
                UserDefaults.standard.set(Date.now, forKey: Self.lastAutomaticICloudBackupKey)
            }
        } catch let error as ICloudBackupError where error == .accountUnavailable {
            iCloudBackupState = .unavailable
            recordICloudFailure(error)
        } catch {
            iCloudBackupState = .failed
            recordICloudFailure(error)
        }
    }

    func restoreICloudBackup() async {
        guard !isSyncingICloud else { return }
        isSyncingICloud = true
        defer { isSyncingICloud = false }
        do {
            guard let remote = try await cloudBackup.load() else {
                throw ICloudBackupError.malformedBackup
            }
            applyBackupSnapshot(remote)
            hasICloudBackup = true
            iCloudRestoreAvailable = false
            iCloudBackupEnabled = true
            iCloudBackupState = .ready(lastBackup: remote.updatedAt)
            healthMessage = L.text("icloud.restore.success", remote.healthArchive.count, remote.importBatches.count)
            iCloudErrorMessage = nil
        } catch let error as ICloudBackupError where error == .accountUnavailable {
            iCloudBackupState = .unavailable
            recordICloudFailure(error)
        } catch {
            iCloudBackupState = .failed
            recordICloudFailure(error)
        }
    }

    func dismissICloudRestorePrompt() {
        iCloudRestoreAvailable = false
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

    private var calendarRecords: [WorkoutRecord] {
        var byID = Dictionary(uniqueKeysWithValues: healthArchive.map { ($0.id, $0) })
        for record in healthRecords { byID[record.id] = record }
        return byID.values.sorted { $0.startDate < $1.startDate }
    }

    private func replaceHealthArchive(with records: [WorkoutRecord]) {
        healthArchive = records.sorted { $0.startDate < $1.startDate }
        saveHealthArchive()
    }

    private func applyHealthChanges(_ records: [WorkoutRecord], deletedIDs: Set<UUID>) {
        var byID = Dictionary(uniqueKeysWithValues: healthArchive.map { ($0.id, $0) })
        for id in deletedIDs { byID.removeValue(forKey: id) }
        for record in records { byID[record.id] = record }
        healthArchive = byID.values.sorted { $0.startDate < $1.startDate }
        saveHealthArchive()
    }

    private func saveHealthArchive() {
        if let data = try? JSONEncoder().encode(healthArchive) {
            UserDefaults.standard.set(data, forKey: Self.healthArchiveKey)
        }
    }

    private func loadHealthArchive() {
        guard let data = UserDefaults.standard.data(forKey: Self.healthArchiveKey),
              let decoded = try? JSONDecoder().decode([WorkoutRecord].self, from: data) else { return }
        healthArchive = decoded
        healthRecords = decoded
    }

    private func loadHealthAnchor() {
        healthAnchorData = UserDefaults.standard.data(forKey: Self.healthAnchorKey)
    }

    private func saveDeletedBatchDates() {
        if let data = try? JSONEncoder().encode(deletedBatchDates) {
            UserDefaults.standard.set(data, forKey: Self.deletedBatchDatesKey)
        }
    }

    private func loadDeletedBatchDates() {
        guard let data = UserDefaults.standard.data(forKey: Self.deletedBatchDatesKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        deletedBatchDates = decoded
    }

    private func backupSnapshot() -> ICloudBackupSnapshot {
        ICloudBackupSnapshot(
            updatedAt: .now,
            healthArchive: calendarRecords,
            importBatches: importBatches,
            deletedBatchDates: deletedBatchDates,
            displayName: userName,
            displayNameUpdatedAt: userNameUpdatedAt
        )
    }

    private func applyBackupSnapshot(_ snapshot: ICloudBackupSnapshot) {
        healthArchive = snapshot.healthArchive
        healthRecords = snapshot.healthArchive
        importBatches = snapshot.importBatches
        deletedBatchDates = snapshot.deletedBatchDates
        isApplyingBackupSnapshot = true
        userName = snapshot.displayName
        isApplyingBackupSnapshot = false
        UserDefaults.standard.set(userName, forKey: Self.userNameKey)
        userNameUpdatedAt = snapshot.displayNameUpdatedAt
        UserDefaults.standard.set(userNameUpdatedAt, forKey: Self.userNameUpdatedAtKey)
        saveBatches()
        saveHealthArchive()
        saveDeletedBatchDates()
    }

    private func scheduleICloudSync() {
        guard iCloudBackupEnabled else { return }
        Task { await syncICloudBackup(force: false) }
    }

    private var isAutomaticICloudBackupDue: Bool {
        guard let lastBackup = UserDefaults.standard.object(forKey: Self.lastAutomaticICloudBackupKey) as? Date else {
            return true
        }
        return !Calendar.autoupdatingCurrent.isDate(lastBackup, inSameDayAs: .now)
    }

    private func iCloudFailureMessage(_ error: Error) -> String {
        if let backupError = error as? ICloudBackupError {
            return backupError.localizedDescription
        }
        guard let cloudError = error as? CKError else {
            return L.text("icloud.error.genericDiagnostic", error.localizedDescription)
        }
        switch cloudError.code {
        case .notAuthenticated:
            return L.text("icloud.error.account")
        case .permissionFailure, .missingEntitlement:
            return L.text("icloud.error.permission")
        case .badContainer:
            return L.text("icloud.error.container")
        case .badDatabase:
            return L.text("icloud.error.configuration")
        case .invalidArguments, .serverRejectedRequest:
            return detailedCloudErrorMessage(cloudError)
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable:
            return L.text("icloud.error.network")
        default:
            return L.text("icloud.error.genericDiagnostic", String(describing: cloudError.code))
        }
    }

    private func recordICloudFailure(_ error: Error) {
        let message = iCloudFailureMessage(error)
        iCloudErrorMessage = message
        healthMessage = message
    }

    private func detailedCloudErrorMessage(_ error: CKError) -> String {
        let serverDescription = error.userInfo["CKErrorServerDescription"] as? String
        let underlyingDescription = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
        let description = serverDescription ?? underlyingDescription ?? error.localizedDescription
        return L.text("icloud.error.serverDiagnostic", description, String(error.code.rawValue))
    }
}
