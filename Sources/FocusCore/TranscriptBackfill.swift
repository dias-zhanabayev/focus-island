import Foundation
import GRDB
import OpenIslandCore

public final class TranscriptBackfill: Sendable {
    private let store: FocusStore
    private let rootURL: URL
    private let history: SessionHistory

    public init(store: FocusStore, rootURL: URL = ClaudeTranscriptDiscovery.defaultRootURL) {
        self.store = store
        self.rootURL = rootURL
        self.history = SessionHistory(store: store)
    }

    @discardableResult
    public func run() throws -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let known: [String: Date] = try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT path, modifiedAt FROM backfill_files")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["path"] as String, $0["modifiedAt"] as Date) })
        }

        var processed = 0
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl", !fileURL.path.contains("/subagents/") else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modifiedAt = values?.contentModificationDate else { continue }
            if let previous = known[fileURL.path], previous.timeIntervalSince(modifiedAt) > -0.001 { continue }
            if let summary = TranscriptSummaryParser.parse(fileURL: fileURL) {
                try history.mergeTranscript(summary)
                processed += 1
            }
            try store.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO backfill_files (path, modifiedAt) VALUES (?, ?) ON CONFLICT(path) DO UPDATE SET modifiedAt = excluded.modifiedAt",
                    arguments: [fileURL.path, modifiedAt]
                )
            }
        }
        return processed
    }
}
