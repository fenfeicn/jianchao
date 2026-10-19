import Foundation
import CSQLite
import ImageIO
import UniformTypeIdentifiers

/// All SQLite and payload I/O is isolated from the UI on this actor.
public actor HistoryStore {
    public nonisolated let directory: URL
    public nonisolated let assetsDirectory: URL
    private var db: OpaquePointer?
    private var cachedAssetBytes: Int?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL) throws {
        self.directory = directory
        assetsDirectory = directory.appendingPathComponent("Payloads", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("History.sqlite")
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw ClipError.storage("open")
        }
        // Schema v1; JSON holds the model, indexed columns drive retention and identity.
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=NORMAL", "PRAGMA busy_timeout=2000", "PRAGMA secure_delete=ON",
                    "CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, favorite INTEGER NOT NULL, copied REAL NOT NULL, bytes INTEGER NOT NULL, record BLOB NOT NULL)",
                    "CREATE INDEX IF NOT EXISTS items_copied ON items(copied DESC)"] {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); db = nil; throw ClipError.storage("schema") }
        }
        do { try Self.migrate(db!) } catch { sqlite3_close(db); db = nil; throw error }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { if let db { sqlite3_close(db) } }

    public func load() throws -> [HistoryItem] {
        let statement = try prepare("SELECT record FROM items ORDER BY copied DESC")
        defer { sqlite3_finalize(statement) }
        var items: [HistoryItem] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return items }
            guard result == SQLITE_ROW, let raw = sqlite3_column_blob(statement, 0) else { throw failure() }
            let data = Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, 0)))
            items.append(try decoder.decode(HistoryItem.self, from: data))
        }
    }

    @discardableResult
    public func insert(_ clip: CapturedClip, policy: RetentionPolicy = .init(), returningItems: Bool = true) throws -> [HistoryItem] {
        guard clip.payload.byteCount <= (clip.payload.kind == .image ? 20 * 1_024 * 1_024 : 2 * 1_024 * 1_024) else { throw ClipError.tooLarge }
        if var existing = try fetch("SELECT record FROM items WHERE fingerprint=?", value: clip.payload.fingerprint).first {
            existing.lastCopiedAt = clip.date
            existing.source = clip.source
            try save(existing)
            return try prune(policy: policy, now: clip.date, returningItems: returningItems)
        }
        let favoriteBytes = try scalar("SELECT COALESCE(SUM(cost),0) FROM items WHERE favorite=1")
        guard favoriteBytes + clip.payload.byteCount + 32_768 < policy.maximumBytes else { throw ClipError.capacity }
        let id = UUID().uuidString
        var item = HistoryItem(id: id, fingerprint: clip.payload.fingerprint, kind: clip.payload.kind, title: "", text: nil, fileURLs: [], imageType: nil, imageFilename: nil, thumbnailFilename: nil, imageWidth: nil, imageHeight: nil, source: clip.source, createdAt: clip.date, lastCopiedAt: clip.date, isFavorite: false, byteCount: clip.payload.byteCount)
        var createdFiles: [URL] = []
        do {
            switch clip.payload {
            case .text(let text):
                guard !text.isEmpty else { return returningItems ? try load() : [] }
                item.text = text
                item.title = String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(180) ?? "空白文本".prefix(180))
            case .files(let urls):
                guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw ClipError.unavailableFile }
                item.fileURLs = urls
                item.title = urls[0].lastPathComponent + (urls.count > 1 ? " + \(urls.count - 1) 个文件" : "")
            case .image(let data, let type):
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 40_000_000 / height else { throw ClipError.invalidImage }
                let filename = id + "." + (UTType(type)?.preferredFilenameExtension ?? "image")
                let imageURL = assetsDirectory.appendingPathComponent(filename)
                try data.write(to: imageURL, options: .atomic)
                createdFiles.append(imageURL); cachedAssetBytes = nil
                item.imageType = type; item.imageFilename = filename
                item.imageWidth = width; item.imageHeight = height
                item.title = "图片 · \(width) × \(height)"
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true]
                if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    let thumb = assetsDirectory.appendingPathComponent(id + "-thumb.png")
                    if let destination = CGImageDestinationCreateWithURL(thumb as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, nil)
                        if CGImageDestinationFinalize(destination) { item.thumbnailFilename = thumb.lastPathComponent; createdFiles.append(thumb) }
                    }
                }
            }
            try save(item)
        } catch {
            createdFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        return try prune(policy: policy, now: clip.date, returningItems: returningItems)
    }

    public func setFavorite(_ id: String, value: Bool, returningItems: Bool = true) throws -> [HistoryItem] {
        if var item = try item(id: id) { item.isFavorite = value; try save(item) }
        return returningItems ? try load() : []
    }

    public func delete(_ ids: Set<String>, returningItems: Bool = true) throws -> [HistoryItem] {
        let items = try ids.flatMap { try fetch("SELECT summary FROM items WHERE id=?", value: $0) }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("DELETE FROM items WHERE id=?")
            defer { sqlite3_finalize(statement) }
            for item in items {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(item.id, to: statement, at: 1)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        for item in items {
            for name in [item.imageFilename, item.thumbnailFilename].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: assetsDirectory.appendingPathComponent(name))
                cachedAssetBytes = nil
            }
        }
        return returningItems ? try load() : []
    }

    public func clear(includingFavorites: Bool, returningItems: Bool = true) throws -> [HistoryItem] {
        let items = try fetch("SELECT summary FROM items" + (includingFavorites ? "" : " WHERE favorite=0"))
        _ = try delete(Set(items.map(\.id)), returningItems: false)
        // Explicit clearing is infrequent and should release disk space promptly.
        try compact()
        return returningItems ? try load() : []
    }

    public func prune(policy: RetentionPolicy, now: Date = Date(), returningItems: Bool = true) throws -> [HistoryItem] {
        let cutoff = now.addingTimeInterval(-Double(policy.days) * 86_400).timeIntervalSince1970
        var removing = Set<String>()
        var totalBytes = try scalar("SELECT COALESCE(SUM(bytes),0) FROM items"), count = try self.count()
        if policy.days > 0 {
            let expired = try prepare("SELECT id,bytes FROM items WHERE favorite=0 AND copied<\(cutoff)")
            defer { sqlite3_finalize(expired) }
            while sqlite3_step(expired) == SQLITE_ROW {
                removing.insert(String(cString: sqlite3_column_text(expired, 0)))
                totalBytes -= Int(sqlite3_column_int64(expired, 1)); count -= 1
            }
        }
        if count > policy.maximumItems || totalBytes > policy.maximumBytes {
            let oldest = try prepare("SELECT id,bytes FROM items WHERE favorite=0 ORDER BY copied ASC,id DESC")
            defer { sqlite3_finalize(oldest) }
            while (count > policy.maximumItems || totalBytes > policy.maximumBytes) && sqlite3_step(oldest) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(oldest, 0))
                if removing.insert(id).inserted { count -= 1; totalBytes -= Int(sqlite3_column_int64(oldest, 1)) }
            }
        }
        if !removing.isEmpty { _ = try delete(removing, returningItems: false) }
        // Reuse free pages during normal retention. Vacuum only when substantial
        // space is reclaimable or the real disk budget requires it.
        let free = try scalar("PRAGMA freelist_count"), pages = try scalar("PRAGMA page_count")
        if free > 1024 && free * 4 > pages { try compact() }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        var actual = try managedBytes()
        if actual > policy.maximumBytes && free > 0 { try compact(); actual = try managedBytes() }
        while actual > policy.maximumBytes {
            var deleting = Set<String>(), estimate = actual
            let candidates = try prepare("SELECT id,cost FROM items WHERE favorite=0 ORDER BY copied ASC,id DESC")
            while sqlite3_step(candidates) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(candidates, 0))
                deleting.insert(id); estimate -= Int(sqlite3_column_int64(candidates, 1))
                if estimate < Int(Double(policy.maximumBytes) * 0.94) { break }
            }
            sqlite3_finalize(candidates)
            guard !deleting.isEmpty else { break }
            _ = try delete(deleting, returningItems: false)
            removing.formUnion(deleting)
            try compact()
            let updated = try managedBytes()
            if updated >= actual { break }
            actual = updated
        }
        return returningItems ? try load() : []
    }

    private func compact() throws {
        try execute("VACUUM"); try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func managedBytes() throws -> Int {
        if cachedAssetBytes == nil {
            let files = try FileManager.default.contentsOfDirectory(at: assetsDirectory, includingPropertiesForKeys: [.fileSizeKey])
            cachedAssetBytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        }
        return ["History.sqlite", "History.sqlite-wal", "History.sqlite-shm"].reduce(cachedAssetBytes ?? 0) { total, name in
            total + ((try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    public func count() throws -> Int { try scalar("SELECT COUNT(*) FROM items") }
    public func item(id: String) throws -> HistoryItem? { try fetch("SELECT record FROM items WHERE id=?", value: id).first }

    /// Body text stays in SQLite. Only a bounded page of small list summaries is decoded.
    public func search(query: String, kind: ContentKind?, favoritesOnly: Bool, dateInterval: DateInterval? = nil,
                       limit: Int = 100, offset: Int = 0) throws -> HistorySearchPage {
        let terms = SearchEngine.normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        var clauses: [String] = [], values: [String] = []
        if let kind {
            clauses.append(kind == .image ? "(kind='image' OR previewable=1)" : "kind=?")
            if kind != .image { values.append(kind.rawValue) }
        }
        if favoritesOnly { clauses.append("favorite=1") }
        if let dateInterval { clauses.append("copied>=\(dateInterval.start.timeIntervalSince1970) AND copied<\(dateInterval.end.timeIntervalSince1970)") }
        for term in terms { clauses.append("instr(search,?)>0"); values.append(term) }
        let predicate = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let countStatement = try prepare("SELECT COUNT(*) FROM items" + predicate)
        for (i, value) in values.enumerated() { bind(value, to: countStatement, at: Int32(i + 1)) }
        guard sqlite3_step(countStatement) == SQLITE_ROW else { sqlite3_finalize(countStatement); throw failure() }
        let total = Int(sqlite3_column_int64(countStatement, 0)); sqlite3_finalize(countStatement)
        let relevance = terms.isEmpty ? "" : "CASE WHEN " + terms.map { _ in "instr(title_search,?)>0" }.joined(separator: " AND ") + " THEN 0 ELSE 1 END,"
        let statement = try prepare("SELECT summary FROM items" + predicate + " ORDER BY " + relevance + "copied DESC,id ASC LIMIT \(max(1, min(500, limit))) OFFSET \(max(0, offset))")
        defer { sqlite3_finalize(statement) }
        for (i, value) in (values + terms).enumerated() { bind(value, to: statement, at: Int32(i + 1)) }
        var items: [HistoryItem] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            items.append(try decoder.decode(HistoryItem.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
        return HistorySearchPage(items: items, total: total)
    }

    private func fetch(_ sql: String, value: String? = nil) throws -> [HistoryItem] {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        if let value { bind(value, to: statement, at: 1) }
        var result: [HistoryItem] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            result.append(try decoder.decode(HistoryItem.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
    }
    private func scalar(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func estimatedDiskCost(_ item: HistoryItem) -> Int {
        var cost = (try? encoder.encode(item).count) ?? 1_024
        for name in [item.imageFilename, item.thumbnailFilename].compactMap({ $0 }) {
            let values = try? assetsDirectory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey])
            cost += values?.fileSize ?? 0
        }
        return cost + 512
    }

    public func recoverOrphanedAssets() throws {
        cachedAssetBytes = nil
        let names = Set(try fetch("SELECT summary FROM items").flatMap { [$0.imageFilename, $0.thumbnailFilename].compactMap { $0 } })
        for file in try FileManager.default.contentsOfDirectory(at: assetsDirectory, includingPropertiesForKeys: nil) where !names.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }

    public func payload(for item: HistoryItem) throws -> ClipPayload {
        switch item.kind {
        case .text: guard let text = try item.text ?? self.item(id: item.id)?.text else { throw ClipError.missingContent }; return .text(text)
        case .file:
            guard !item.fileURLs.isEmpty, item.fileURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw ClipError.unavailableFile }
            return .files(item.fileURLs)
        case .image:
            guard let filename = item.imageFilename else { throw ClipError.missingContent }
            let url = assetsDirectory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url) else { throw ClipError.missingContent }
            return .image(data, type: item.imageType ?? "public.png")
        }
    }

    private func save(_ item: HistoryItem) throws {
        let data = try encoder.encode(item)
        let statement = try prepare("INSERT INTO items(id,fingerprint,favorite,copied,bytes,record,summary,search,title_search,kind,previewable,cost) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET favorite=excluded.favorite,copied=excluded.copied,bytes=excluded.bytes,record=excluded.record,summary=excluded.summary,search=excluded.search,title_search=excluded.title_search,kind=excluded.kind,previewable=excluded.previewable,cost=excluded.cost")
        defer { sqlite3_finalize(statement) }
        bind(item.id, to: statement, at: 1); bind(item.fingerprint, to: statement, at: 2)
        sqlite3_bind_int(statement, 3, item.isFavorite ? 1 : 0)
        sqlite3_bind_double(statement, 4, item.lastCopiedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 5, sqlite3_int64(item.byteCount))
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32($0.count), transient) }
        let summary = try encoder.encode(item.listSummary)
        _ = summary.withUnsafeBytes { sqlite3_bind_blob(statement, 7, $0.baseAddress, Int32($0.count), transient) }
        bind(SearchEngine.normalize(item.searchText), to: statement, at: 8)
        bind(SearchEngine.normalize(item.title), to: statement, at: 9)
        bind(item.kind.rawValue, to: statement, at: 10)
        sqlite3_bind_int(statement, 11, item.isImagePreviewable ? 1 : 0)
        sqlite3_bind_int64(statement, 12, sqlite3_int64(estimatedDiskCost(item) + summary.count + item.searchText.utf8.count))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private static func migrate(_ db: OpaquePointer) throws {
        var check: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &check, nil)
        let version = sqlite3_step(check) == SQLITE_ROW ? sqlite3_column_int(check, 0) : 0
        sqlite3_finalize(check)
        guard version <= 2 else { throw ClipError.storage("newer schema") }
        guard version < 2 else { return }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ClipError.storage("migration") }
        }
        try exec("BEGIN IMMEDIATE")
        do {
            for column in ["summary BLOB", "search TEXT", "title_search TEXT", "kind TEXT", "previewable INTEGER", "cost INTEGER"] { try exec("ALTER TABLE items ADD COLUMN " + column) }
            var read: OpaquePointer?, write: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id,record FROM items", -1, &read, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, "UPDATE items SET summary=?,search=?,title_search=?,kind=?,previewable=?,cost=? WHERE id=?", -1, &write, nil) == SQLITE_OK else { throw ClipError.storage("migration prepare") }
            defer { sqlite3_finalize(read); sqlite3_finalize(write) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            while true {
                let step = sqlite3_step(read)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW, let raw = sqlite3_column_blob(read, 1) else { throw ClipError.storage("migration read") }
                let data = Data(bytes: raw, count: Int(sqlite3_column_bytes(read, 1)))
                let item = try JSONDecoder().decode(HistoryItem.self, from: data)
                let summary = try JSONEncoder().encode(item.listSummary)
                sqlite3_reset(write); sqlite3_clear_bindings(write)
                _ = summary.withUnsafeBytes { sqlite3_bind_blob(write, 1, $0.baseAddress, Int32($0.count), transient) }
                for (column, value) in [(Int32(2), SearchEngine.normalize(item.searchText)), (3, SearchEngine.normalize(item.title)), (4, item.kind.rawValue), (7, item.id)] {
                    _ = value.withCString { sqlite3_bind_text(write, column, $0, Int32(value.utf8.count), transient) }
                }
                sqlite3_bind_int(write, 5, item.isImagePreviewable ? 1 : 0)
                sqlite3_bind_int64(write, 6, sqlite3_int64(data.count + summary.count + item.searchText.utf8.count + item.byteCount + 512))
                guard sqlite3_step(write) == SQLITE_DONE else { throw ClipError.storage("migration write") }
            }
            try exec("CREATE INDEX IF NOT EXISTS items_kind_copied ON items(kind,copied DESC)")
            try exec("CREATE INDEX IF NOT EXISTS items_favorite_copied ON items(favorite,copied DESC)")
            try exec("PRAGMA user_version=2"); try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
    }
    private func failure() -> ClipError { .storage(db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed") }
}
