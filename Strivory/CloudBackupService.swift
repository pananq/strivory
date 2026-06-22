import CloudKit
import Foundation

enum ICloudBackupError: LocalizedError, Equatable {
    case accountUnavailable
    case malformedBackup

    var errorDescription: String? {
        switch self {
        case .accountUnavailable: return L.text("icloud.error.account")
        case .malformedBackup: return L.text("icloud.error.malformed")
        }
    }
}

/// CloudKit private-database storage for the user's complete Strivory archive.
/// A private database is scoped to the signed-in iCloud account and is never a
/// shared/public app database.
actor CloudBackupService {
    static let containerIdentifier = "iCloud.com.pananq.strivory"

    private let container = CKContainer(identifier: containerIdentifier)
    private let recordID = CKRecord.ID(recordName: "strivory-backup-v1")
    private let recordType = "StrivoryBackup"
    private let payloadField = "payload"

    func isAccountAvailable() async -> Bool {
        do {
            return try await container.accountStatus() == .available
        } catch {
            return false
        }
    }

    func load() async throws -> ICloudBackupSnapshot? {
        guard try await container.accountStatus() == .available else {
            throw ICloudBackupError.accountUnavailable
        }

        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            guard let asset = record[payloadField] as? CKAsset,
                  let fileURL = asset.fileURL else {
                throw ICloudBackupError.malformedBackup
            }
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(ICloudBackupSnapshot.self, from: data)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func sync(local: ICloudBackupSnapshot) async throws -> ICloudBackupSnapshot {
        guard try await container.accountStatus() == .available else {
            throw ICloudBackupError.accountUnavailable
        }

        let merged = Self.merge(local: local, remote: try await load())
        do {
            try await save(merged)
            return merged
        } catch let error as CKError where error.code == .serverRecordChanged {
            // A second device wrote during this sync. Merge the newest server
            // snapshot once more instead of discarding either device's data.
            let retry = Self.merge(local: merged, remote: try await load())
            try await save(retry)
            return retry
        }
    }

    func save(_ snapshot: ICloudBackupSnapshot) async throws {
        guard try await container.accountStatus() == .available else {
            throw ICloudBackupError.accountUnavailable
        }

        let data = try JSONEncoder().encode(snapshot)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strivory-cloud-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        try data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let record: CKRecord
        do {
            // Reuse the server record so its change tag is retained on updates.
            record = try await container.privateCloudDatabase.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        record[payloadField] = CKAsset(fileURL: fileURL)
        record["updatedAt"] = snapshot.updatedAt as NSDate
        record["schemaVersion"] = snapshot.schemaVersion as NSNumber
        _ = try await container.privateCloudDatabase.save(record)
    }

    private static func merge(local: ICloudBackupSnapshot, remote: ICloudBackupSnapshot?) -> ICloudBackupSnapshot {
        guard let remote else {
            var result = local
            result.updatedAt = .now
            return result
        }

        var tombstones = remote.deletedBatchDates
        for (id, date) in local.deletedBatchDates {
            tombstones[id] = max(tombstones[id] ?? .distantPast, date)
        }

        var batches = Dictionary(uniqueKeysWithValues: remote.importBatches.map { ($0.id, $0) })
        for batch in local.importBatches {
            if let existing = batches[batch.id] {
                // Import batches are immutable. Prefer the newest copy only if an
                // old app somehow reused an identifier.
                batches[batch.id] = existing.createdAt >= batch.createdAt ? existing : batch
            } else {
                batches[batch.id] = batch
            }
        }
        let activeBatches = batches.values.filter { batch in
            guard let deletedAt = tombstones[batch.id.uuidString] else { return true }
            return deletedAt < batch.createdAt
        }

        var health = Dictionary(uniqueKeysWithValues: remote.healthArchive.map { ($0.id, $0) })
        for record in local.healthArchive {
            if let existing = health[record.id] {
                // HealthKit UUIDs are stable. If the same UUID is refreshed, keep
                // the record with the richer duration/energy values.
                health[record.id] = record.duration >= existing.duration ? record : existing
            } else {
                health[record.id] = record
            }
        }

        let profileIsLocal = local.displayNameUpdatedAt >= remote.displayNameUpdatedAt
        return ICloudBackupSnapshot(
            schemaVersion: max(local.schemaVersion, remote.schemaVersion),
            updatedAt: .now,
            healthArchive: health.values.sorted { $0.startDate < $1.startDate },
            importBatches: activeBatches.sorted { $0.createdAt < $1.createdAt },
            deletedBatchDates: tombstones,
            displayName: profileIsLocal ? local.displayName : remote.displayName,
            displayNameUpdatedAt: max(local.displayNameUpdatedAt, remote.displayNameUpdatedAt)
        )
    }
}
