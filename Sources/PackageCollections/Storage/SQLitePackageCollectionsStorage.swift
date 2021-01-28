/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Dispatch
import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import struct Foundation.URL
import PackageModel
import TSCBasic
import TSCUtility

final class SQLitePackageCollectionsStorage: PackageCollectionsStorage, Closable {
    static let batchSize = 100

    private static let packageCollectionsTableName = "package_collections"
    private static let packagesFTSName = "fts_packages"
    private static let targetsFTSName = "fts_targets"

    let fileSystem: FileSystem
    let location: SQLite.Location

    private let diagnosticsEngine: DiagnosticsEngine?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // for concurrent for DB access
    private let queue = DispatchQueue(label: "org.swift.swiftpm.SQLitePackageCollectionsStorage", attributes: .concurrent)

    private var state = State.idle
    private let stateLock = Lock()

    private let cache = ThreadSafeKeyValueStore<Model.CollectionIdentifier, Model.Collection>()
    private let cacheLock = Lock()

    private let isShuttingdown = ThreadSafeBox<Bool>()

    // Lock helps prevent concurrency errors with transaction statements during e.g. `refreshCollections`,
    // since only one transaction is allowed per SQLite connection. We need transactions to speed up bulk updates.
    // TODO: we could potentially optimize this with db connection pool
    private let ftsLock = Lock()
    // FTS not supported on some platforms; the code falls back to "slow path" in that case
    let useSearchIndices = ThreadSafeBox<Bool>()

    // Targets have in-memory trie in addition to SQLite FTS as optimization
    private let targetTrie = Trie<CollectionPackage>()
    private var targetTrieReady = ThreadSafeBox<Bool>()

    init(location: SQLite.Location? = nil, diagnosticsEngine: DiagnosticsEngine? = nil) {
        self.location = location ?? .path(localFileSystem.swiftPMCacheDirectory.appending(components: "package-collection.db"))
        switch self.location {
        case .path, .temporary:
            self.fileSystem = localFileSystem
        case .memory:
            self.fileSystem = InMemoryFileSystem()
        }
        self.diagnosticsEngine = diagnosticsEngine
        self.encoder = JSONEncoder.makeWithDefaults()
        self.decoder = JSONDecoder.makeWithDefaults()

        self.populateTargetTrie()
    }

    convenience init(path: AbsolutePath, diagnosticsEngine: DiagnosticsEngine? = nil) {
        self.init(location: .path(path), diagnosticsEngine: diagnosticsEngine)
    }

    deinit {
        guard case .disconnected = (self.stateLock.withLock { self.state }) else {
            return assertionFailure("db should be closed")
        }
    }

    func close() throws {
        // Signal long-running operation (e.g., populateTargetTrie) to stop
        self.isShuttingdown.put(true)

        func retryClose(db: SQLite, exponentialBackoff: inout ExponentialBackoff) throws {
            let semaphore = DispatchSemaphore(value: 0)
            let callback = { (result: Result<Void, Error>) in
                // If it has failed, the semaphore will timeout in which case we will retry
                if case .success = result {
                    semaphore.signal()
                }
            }

            // This throws error if we have exhausted our attempts
            let delay = try exponentialBackoff.nextDelay()
            self.queue.asyncAfter(deadline: .now() + delay) {
                do {
                    try db.close()
                    callback(.success(()))
                } catch {
                    callback(.failure(error))
                }
            }
            // Add some buffer to allow `asyncAfter` to run
            guard case .success = semaphore.wait(timeout: .now() + delay + .milliseconds(50)) else {
                return try retryClose(db: db, exponentialBackoff: &exponentialBackoff)
            }
        }

        try self.stateLock.withLock {
            if case .connected(let db) = self.state {
                do {
                    try db.close()
                } catch {
                    var exponentialBackoff = ExponentialBackoff()
                    do {
                        try retryClose(db: db, exponentialBackoff: &exponentialBackoff)
                    } catch {
                        throw StringError("Failed to close database")
                    }
                }
            }
            self.state = .disconnected
        }
    }

    private struct ExponentialBackoff {
        let intervalInMilliseconds: Int
        let randomizationFactor: Int
        let maximumAttempts: Int

        var attempts: Int = 0
        var multipler: Int = 1

        var canRetry: Bool {
            self.attempts < self.maximumAttempts
        }

        init(intervalInMilliseconds: Int = 100, randomizationFactor: Int = 100, maximumAttempts: Int = 3) {
            self.intervalInMilliseconds = intervalInMilliseconds
            self.randomizationFactor = randomizationFactor
            self.maximumAttempts = maximumAttempts
        }

        mutating func nextDelay() throws -> DispatchTimeInterval {
            guard self.canRetry else {
                throw StringError("Maximum attempts reached")
            }
            let delay = self.multipler * intervalInMilliseconds
            let jitter = Int.random(in: 0 ... self.randomizationFactor)
            self.attempts += 1
            self.multipler *= 2
            return .milliseconds(delay + jitter)
        }
    }

    func put(collection: Model.Collection,
             callback: @escaping (Result<Model.Collection, Error>) -> Void) {
        self.queue.async {
            do {
                // write to db
                let query = "INSERT OR REPLACE INTO \(Self.packageCollectionsTableName) VALUES (?, ?);"
                try self.executeStatement(query) { statement -> Void in
                    let data = try self.encoder.encode(collection)

                    let bindings: [SQLite.SQLiteValue] = [
                        .string(collection.identifier.databaseKey()),
                        .blob(data),
                    ]
                    try statement.bind(bindings)
                    try statement.step()
                }

                // Add to search indices
                try self.insertToSearchIndices(collection: collection)

                // write to cache
                self.cache[collection.identifier] = collection
                callback(.success(collection))
            } catch {
                callback(.failure(error))
            }
        }
    }

    private func insertToSearchIndices(collection: Model.Collection) throws {
        guard self.useSearchIndices.get() ?? false else { return }

        try self.ftsLock.withLock {
            // Update search indices
            try self.withDB { db in
                try db.exec(query: "BEGIN TRANSACTION;")

                // First delete existing data
                try self.removeFromSearchIndices(identifier: collection.identifier)

                let packagesStatement = try db.prepare(query: "INSERT INTO \(Self.packagesFTSName) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);")
                let targetsStatement = try db.prepare(query: "INSERT INTO \(Self.targetsFTSName) VALUES (?, ?, ?);")

                // Then insert new data
                try collection.packages.forEach { package in
                    var targets = Set<String>()

                    try package.versions.forEach { version in
                        // Packages FTS
                        let packagesBindings: [SQLite.SQLiteValue] = [
                            .string(try self.encoder.encode(collection.identifier).base64EncodedString()),
                            .string(package.reference.identity.description),
                            .string(version.version.description),
                            .string(version.packageName),
                            .string(package.repository.url),
                            package.summary.map { .string($0) } ?? .null,
                            package.keywords.map { .string($0.joined(separator: ",")) } ?? .null,
                            .string(version.products.map { $0.name }.joined(separator: ",")),
                            .string(version.targets.map { $0.name }.joined(separator: ",")),
                        ]
                        try packagesStatement.bind(packagesBindings)
                        try packagesStatement.step()

                        try packagesStatement.clearBindings()
                        try packagesStatement.reset()

                        version.targets.forEach { targets.insert($0.name) }
                    }

                    let collectionPackage = CollectionPackage(collection: collection.identifier, package: package.reference.identity)
                    try targets.forEach { target in
                        // Targets in-memory trie
                        self.targetTrie.insert(word: target.lowercased(), foundIn: collectionPackage)

                        // Targets FTS
                        let targetsBindings: [SQLite.SQLiteValue] = [
                            .string(try self.encoder.encode(collection.identifier).base64EncodedString()),
                            .string(package.repository.url),
                            .string(target),
                        ]
                        try targetsStatement.bind(targetsBindings)
                        try targetsStatement.step()

                        try targetsStatement.clearBindings()
                        try targetsStatement.reset()
                    }
                }

                try db.exec(query: "COMMIT;")

                try packagesStatement.finalize()
                try targetsStatement.finalize()
            }
        }
    }

    func remove(identifier: Model.CollectionIdentifier,
                callback: @escaping (Result<Void, Error>) -> Void) {
        self.queue.async {
            do {
                // write to db
                let query = "DELETE FROM \(Self.packageCollectionsTableName) WHERE key = ?;"
                try self.executeStatement(query) { statement -> Void in
                    let bindings: [SQLite.SQLiteValue] = [
                        .string(identifier.databaseKey()),
                    ]
                    try statement.bind(bindings)
                    try statement.step()
                }

                // remove from search indices
                try self.removeFromSearchIndices(identifier: identifier)

                // write to cache
                self.cache[identifier] = nil
                callback(.success(()))
            } catch {
                callback(.failure(error))
            }
        }
    }

    private func removeFromSearchIndices(identifier: Model.CollectionIdentifier) throws {
        guard self.useSearchIndices.get() ?? false else { return }

        let identifierBase64 = try self.encoder.encode(identifier.databaseKey()).base64EncodedString()

        let packagesQuery = "DELETE FROM \(Self.packagesFTSName) WHERE collection_id_blob_base64 = ?;"
        try self.executeStatement(packagesQuery) { statement -> Void in
            let bindings: [SQLite.SQLiteValue] = [.string(identifierBase64)]
            try statement.bind(bindings)
            try statement.step()
        }

        let targetsQuery = "DELETE FROM \(Self.targetsFTSName) WHERE collection_id_blob_base64 = ?;"
        try self.executeStatement(targetsQuery) { statement -> Void in
            let bindings: [SQLite.SQLiteValue] = [.string(identifierBase64)]
            try statement.bind(bindings)
            try statement.step()
        }

        self.targetTrie.remove { $0.collection == identifier }
    }

    func get(identifier: Model.CollectionIdentifier,
             callback: @escaping (Result<Model.Collection, Error>) -> Void) {
        // try read to cache
        if let collection = self.cache[identifier] {
            return callback(.success(collection))
        }

        // go to db if not found
        self.queue.async {
            do {
                let query = "SELECT value FROM \(Self.packageCollectionsTableName) WHERE key = ? LIMIT 1;"
                let collection = try self.executeStatement(query) { statement -> Model.Collection in
                    try statement.bind([.string(identifier.databaseKey())])

                    let row = try statement.step()
                    guard let data = row?.blob(at: 0) else {
                        throw NotFoundError("\(identifier)")
                    }

                    let collection = try self.decoder.decode(Model.Collection.self, from: data)
                    return collection
                }
                callback(.success(collection))
            } catch {
                callback(.failure(error))
            }
        }
    }

    func list(identifiers: [Model.CollectionIdentifier]? = nil,
              callback: @escaping (Result<[Model.Collection], Error>) -> Void) {
        // try read to cache
        let cached = identifiers?.compactMap { self.cache[$0] }
        if let cached = cached, cached.count > 0, cached.count == identifiers?.count {
            return callback(.success(cached))
        }

        // go to db if not found
        self.queue.async {
            do {
                var blobs = [Data]()
                if let identifiers = identifiers {
                    var index = 0
                    while index < identifiers.count {
                        let slice = identifiers[index ..< min(index + Self.batchSize, identifiers.count)]
                        let query = "SELECT value FROM \(Self.packageCollectionsTableName) WHERE key in (\(slice.map { _ in "?" }.joined(separator: ",")));"
                        try self.executeStatement(query) { statement in
                            try statement.bind(slice.compactMap { .string($0.databaseKey()) })
                            while let row = try statement.step() {
                                blobs.append(row.blob(at: 0))
                            }
                        }
                        index += Self.batchSize
                    }
                } else {
                    let query = "SELECT value FROM \(Self.packageCollectionsTableName);"
                    try self.executeStatement(query) { statement in
                        while let row = try statement.step() {
                            blobs.append(row.blob(at: 0))
                        }
                    }
                }

                // decoding is a performance bottleneck (10+s for 1000 collections)
                // workaround is to decode in parallel if list is large enough to justify it
                let sync = DispatchGroup()
                let collections: ThreadSafeArrayStore<Model.Collection>
                if blobs.count < Self.batchSize {
                    collections = .init(blobs.compactMap { data -> Model.Collection? in
                        try? self.decoder.decode(Model.Collection.self, from: data)
                    })
                } else {
                    collections = .init()
                    blobs.forEach { data in
                        self.queue.async(group: sync) {
                            if let collection = try? self.decoder.decode(Model.Collection.self, from: data) {
                                collections.append(collection)
                            }
                        }
                    }
                }

                sync.notify(queue: self.queue) {
                    if collections.count != blobs.count {
                        self.diagnosticsEngine?.emit(warning: "Some stored collections could not be deserialized. Please refresh the collections to resolve this issue.")
                    }
                    callback(.success(collections.get()))
                }

            } catch {
                callback(.failure(error))
            }
        }
    }

    func searchPackages(identifiers: [Model.CollectionIdentifier]? = nil,
                        query: String,
                        callback: @escaping (Result<Model.PackageSearchResult, Error>) -> Void) {
        self.list(identifiers: identifiers) { result in
            switch result {
            case .failure(let error):
                callback(.failure(error))
            case .success(let collections):
                if self.useSearchIndices.get() ?? false {
                    var matches = [(collection: Model.CollectionIdentifier, package: PackageIdentity)]()
                    do {
                        let packageQuery = "SELECT collection_id_blob_base64, repository_url FROM \(Self.packagesFTSName) WHERE \(Self.packagesFTSName) MATCH ?;"
                        try self.executeStatement(packageQuery) { statement in
                            try statement.bind([.string(query)])

                            while let row = try statement.step() {
                                if let collectionData = Data(base64Encoded: row.string(at: 0)),
                                    let collection = try? self.decoder.decode(Model.CollectionIdentifier.self, from: collectionData) {
                                    matches.append((collection: collection, package: PackageIdentity(url: row.string(at: 1))))
                                }
                            }
                        }
                    } catch {
                        return callback(.failure(error))
                    }

                    let collectionDict = collections.reduce(into: [Model.CollectionIdentifier: Model.Collection]()) { result, collection in
                        result[collection.identifier] = collection
                    }

                    // For each package, find the containing collections
                    let packageCollections = matches.filter { collectionDict.keys.contains($0.collection) }
                        .reduce(into: [PackageIdentity: (package: Model.Package, collections: Set<Model.CollectionIdentifier>)]()) { result, match in
                            var entry = result.removeValue(forKey: match.package)
                            if entry == nil {
                                guard let package = collectionDict[match.collection].flatMap({ collection in
                                    collection.packages.first { $0.reference.identity == match.package }
                                }) else {
                                    return
                                }
                                entry = (package, .init())
                            }

                            if var entry = entry {
                                entry.collections.insert(match.collection)
                                result[match.package] = entry
                            }
                        }

                    let result = Model.PackageSearchResult(items: packageCollections.map { entry in
                        .init(package: entry.value.package, collections: Array(entry.value.collections))
                    })
                    callback(.success(result))
                } else {
                    let queryString = query.lowercased()
                    let collectionsPackages = collections.reduce([Model.CollectionIdentifier: [Model.Package]]()) { partial, collection in
                        var map = partial
                        map[collection.identifier] = collection.packages.filter { package in
                            if package.repository.url.lowercased().contains(queryString) { return true }
                            if let summary = package.summary, summary.lowercased().contains(queryString) { return true }
                            if let keywords = package.keywords, (keywords.map { $0.lowercased() }).contains(queryString) { return true }
                            return package.versions.contains(where: { version in
                                if version.packageName.lowercased().contains(queryString) { return true }
                                if version.products.contains(where: { $0.name.lowercased().contains(queryString) }) { return true }
                                return version.targets.contains(where: { $0.name.lowercased().contains(queryString) })
                            })
                        }
                        return map
                    }

                    var packageCollections = [PackageReference: (package: Model.Package, collections: Set<Model.CollectionIdentifier>)]()
                    collectionsPackages.forEach { collectionIdentifier, packages in
                        packages.forEach { package in
                            // Avoid copy-on-write: remove entry from dictionary before mutating
                            var entry = packageCollections.removeValue(forKey: package.reference) ?? (package, .init())
                            entry.collections.insert(collectionIdentifier)
                            packageCollections[package.reference] = entry
                        }
                    }

                    let result = Model.PackageSearchResult(items: packageCollections.map { entry in
                        .init(package: entry.value.package, collections: Array(entry.value.collections))
                    })
                    callback(.success(result))
                }
            }
        }
    }

    func findPackage(identifier: PackageIdentity,
                     collectionIdentifiers: [Model.CollectionIdentifier]?,
                     callback: @escaping (Result<Model.PackageSearchResult.Item, Error>) -> Void) {
        self.list(identifiers: collectionIdentifiers) { result in
            switch result {
            case .failure(let error):
                return callback(.failure(error))
            case .success(let collections):
                if self.useSearchIndices.get() ?? false {
                    var matches = [(collection: Model.CollectionIdentifier, package: PackageIdentity)]()
                    do {
                        let packageQuery = "SELECT collection_id_blob_base64, repository_url FROM \(Self.packagesFTSName) WHERE id = ?;"
                        try self.executeStatement(packageQuery) { statement in
                            try statement.bind([.string(identifier.description)])

                            while let row = try statement.step() {
                                if let collectionData = Data(base64Encoded: row.string(at: 0)),
                                    let collection = try? self.decoder.decode(Model.CollectionIdentifier.self, from: collectionData) {
                                    matches.append((collection: collection, package: PackageIdentity(url: row.string(at: 1))))
                                }
                            }
                        }
                    } catch {
                        return callback(.failure(error))
                    }

                    let collectionDict = collections.reduce(into: [Model.CollectionIdentifier: Model.Collection]()) { result, collection in
                        result[collection.identifier] = collection
                    }

                    let collections = matches.filter { collectionDict.keys.contains($0.collection) }
                        .compactMap { collectionDict[$0.collection] }
                        // Sort collections by processing date so the latest metadata is first
                        .sorted(by: { lhs, rhs in lhs.lastProcessedAt > rhs.lastProcessedAt })

                    guard let package = collections.compactMap({ $0.packages.first { $0.reference.identity == identifier } }).first else {
                        return callback(.failure(NotFoundError("\(identifier)")))
                    }

                    callback(.success(.init(package: package, collections: collections.map { $0.identifier })))
                } else {
                    // sorting by collection processing date so the latest metadata is first
                    let collectionPackages = collections.sorted(by: { lhs, rhs in lhs.lastProcessedAt > rhs.lastProcessedAt }).compactMap { collection in
                        collection.packages
                            .first(where: { $0.reference.identity == identifier })
                            .flatMap { (collection: collection.identifier, package: $0) }
                    }
                    // first package should have latest processing date
                    guard let package = collectionPackages.first?.package else {
                        return callback(.failure(NotFoundError("\(identifier)")))
                    }
                    let collections = collectionPackages.map { $0.collection }
                    callback(.success(.init(package: package, collections: collections)))
                }
            }
        }
    }

    func searchTargets(identifiers: [Model.CollectionIdentifier]? = nil,
                       query: String,
                       type: Model.TargetSearchType,
                       callback: @escaping (Result<Model.TargetSearchResult, Error>) -> Void) {
        let query = query.lowercased()

        self.list(identifiers: identifiers) { result in
            switch result {
            case .failure(let error):
                callback(.failure(error))
            case .success(let collections):
                if self.useSearchIndices.get() ?? false {
                    var matches = [(collection: Model.CollectionIdentifier, package: PackageIdentity, targetName: String)]()
                    // Trie is more performant for target search; use it if available
                    if self.targetTrieReady.get() ?? false {
                        do {
                            switch type {
                            case .exactMatch:
                                try self.targetTrie.find(word: query).forEach {
                                    matches.append((collection: $0.collection, package: $0.package, targetName: query))
                                }
                            case .prefix:
                                try self.targetTrie.findWithPrefix(query).forEach { targetName, collectionPackages in
                                    collectionPackages.forEach {
                                        matches.append((collection: $0.collection, package: $0.package, targetName: targetName))
                                    }
                                }
                            }
                        } catch is NotFoundError {
                            // Do nothing if no matches found
                        } catch {
                            return callback(.failure(error))
                        }
                    } else {
                        do {
                            let targetQuery = "SELECT collection_id_blob_base64, package_repository_url, name FROM \(Self.targetsFTSName) WHERE name LIKE ?;"
                            try self.executeStatement(targetQuery) { statement in
                                switch type {
                                case .exactMatch:
                                    try statement.bind([.string("\(query)")])
                                case .prefix:
                                    try statement.bind([.string("\(query)%")])
                                }

                                while let row = try statement.step() {
                                    if let collectionData = Data(base64Encoded: row.string(at: 0)),
                                        let collection = try? self.decoder.decode(Model.CollectionIdentifier.self, from: collectionData) {
                                        matches.append((
                                            collection: collection,
                                            package: PackageIdentity(url: row.string(at: 1)),
                                            targetName: row.string(at: 2)
                                        ))
                                    }
                                }
                            }
                        } catch {
                            return callback(.failure(error))
                        }
                    }

                    let collectionDict = collections.reduce(into: [Model.CollectionIdentifier: Model.Collection]()) { result, collection in
                        result[collection.identifier] = collection
                    }

                    // For each package, find the containing collections
                    var packageCollections = [PackageIdentity: (package: Model.Package, collections: Set<Model.CollectionIdentifier>)]()
                    // For each matching target, find the containing package version(s)
                    var targetPackageVersions = [Model.Target: [PackageIdentity: Set<Model.TargetListResult.PackageVersion>]]()

                    matches.filter { collectionDict.keys.contains($0.collection) }.forEach { match in
                        var packageEntry = packageCollections.removeValue(forKey: match.package)
                        if packageEntry == nil {
                            guard let package = collectionDict[match.collection].flatMap({ collection in
                                collection.packages.first { $0.reference.identity == match.package }
                            }) else {
                                return
                            }
                            packageEntry = (package, .init())
                        }

                        if var packageEntry = packageEntry {
                            packageEntry.collections.insert(match.collection)
                            packageCollections[match.package] = packageEntry

                            packageEntry.package.versions.forEach { version in
                                let targets = version.targets.filter { $0.name.lowercased() == match.targetName.lowercased() }
                                targets.forEach { target in
                                    var targetEntry = targetPackageVersions.removeValue(forKey: target) ?? [:]
                                    var targetPackageEntry = targetEntry.removeValue(forKey: packageEntry.package.reference.identity) ?? .init()
                                    targetPackageEntry.insert(.init(version: version.version, packageName: version.packageName))
                                    targetEntry[packageEntry.package.reference.identity] = targetPackageEntry
                                    targetPackageVersions[target] = targetEntry
                                }
                            }
                        }
                    }

                    let result = Model.TargetSearchResult(items: targetPackageVersions.map { target, packageVersions in
                        let targetPackages: [Model.TargetListItem.Package] = packageVersions.compactMap { reference, versions in
                            guard let packageEntry = packageCollections[reference] else {
                                return nil
                            }
                            return Model.TargetListItem.Package(
                                repository: packageEntry.package.repository,
                                summary: packageEntry.package.summary,
                                versions: Array(versions).sorted(by: >),
                                collections: Array(packageEntry.collections)
                            )
                        }
                        return Model.TargetListItem(target: target, packages: targetPackages)
                    })
                    callback(.success(result))
                } else {
                    let collectionsPackages = collections.reduce([Model.CollectionIdentifier: [(target: Model.Target, package: Model.Package)]]()) { partial, collection in
                        var map = partial
                        collection.packages.forEach { package in
                            package.versions.forEach { version in
                                version.targets.forEach { target in
                                    let match: Bool
                                    switch type {
                                    case .exactMatch:
                                        match = target.name.lowercased() == query
                                    case .prefix:
                                        match = target.name.lowercased().hasPrefix(query)
                                    }
                                    if match {
                                        // Avoid copy-on-write: remove entry from dictionary before mutating
                                        var entry = map.removeValue(forKey: collection.identifier) ?? .init()
                                        entry.append((target, package))
                                        map[collection.identifier] = entry
                                    }
                                }
                            }
                        }
                        return map
                    }

                    // compose result :p
                    var packageCollections = [PackageReference: (package: Model.Package, collections: Set<Model.CollectionIdentifier>)]()
                    var targetsPackages = [Model.Target: Set<PackageReference>]()

                    collectionsPackages.forEach { collectionIdentifier, packagesAndTargets in
                        packagesAndTargets.forEach { item in
                            // Avoid copy-on-write: remove entry from dictionary before mutating
                            var packageCollectionsEntry = packageCollections.removeValue(forKey: item.package.reference) ?? (item.package, .init())
                            packageCollectionsEntry.collections.insert(collectionIdentifier)
                            packageCollections[item.package.reference] = packageCollectionsEntry

                            // Avoid copy-on-write: remove entry from dictionary before mutating
                            var targetsPackagesEntry = targetsPackages.removeValue(forKey: item.target) ?? .init()
                            targetsPackagesEntry.insert(item.package.reference)
                            targetsPackages[item.target] = targetsPackagesEntry
                        }
                    }

                    let result = Model.TargetSearchResult(items: targetsPackages.map { target, packages in
                        let targetsPackages = packages
                            .compactMap { packageCollections[$0] }
                            .map { pair -> Model.TargetListItem.Package in
                                let versions = pair.package.versions.map { Model.TargetListItem.Package.Version(version: $0.version, packageName: $0.packageName) }
                                return Model.TargetListItem.Package(repository: pair.package.repository,
                                                                    summary: pair.package.summary,
                                                                    versions: versions,
                                                                    collections: Array(pair.collections))
                            }

                        return Model.TargetListItem(target: target, packages: targetsPackages)
                    })

                    callback(.success(result))
                }
            }
        }
    }

    // for testing
    internal func resetCache() {
        self.cache.clear()
    }

    // MARK: -  Private

    private func createSchemaIfNecessary(db: SQLite) throws {
        let table = """
            CREATE TABLE IF NOT EXISTS \(Self.packageCollectionsTableName) (
                key STRING PRIMARY KEY NOT NULL,
                value BLOB NOT NULL
            );
        """
        try db.exec(query: table)

        do {
            let ftsPackages = """
                CREATE VIRTUAL TABLE IF NOT EXISTS \(Self.packagesFTSName) USING fts4(
                    collection_id_blob_base64, id, version, name, repository_url, summary, keywords, products, targets,
                    notindexed=collection_id_blob_base64,
                    tokenize=unicode61
                );
            """
            try db.exec(query: ftsPackages)

            let ftsTargets = """
                CREATE VIRTUAL TABLE IF NOT EXISTS \(Self.targetsFTSName) USING fts4(
                    collection_id_blob_base64, package_repository_url, name,
                    notindexed=collection_id_blob_base64,
                    tokenize=unicode61
                );
            """
            try db.exec(query: ftsTargets)

            useSearchIndices.put(true)
        } catch {
            // We can use FTS3 tables but queries yield different results when run on different
            // platforms. This could be because of SQLite version perhaps? But since we can't get
            // consistent results we will not fallback to FTS3 and just give up if FTS4 is not available.
            useSearchIndices.put(false)
        }

        try db.exec(query: "PRAGMA journal_mode=WAL;")
    }

    private enum State {
        case idle
        case connected(SQLite)
        case disconnected
        case error
    }

    private func executeStatement<T>(_ query: String, _ body: (SQLite.PreparedStatement) throws -> T) throws -> T {
        try self.withDB { db in
            let result: Result<T, Error>
            let statement = try db.prepare(query: query)
            do {
                result = .success(try body(statement))
            } catch {
                result = .failure(error)
            }
            try statement.finalize()
            switch result {
            case .failure(let error):
                throw error
            case .success(let value):
                return value
            }
        }
    }

    private func withDB<T>(_ body: (SQLite) throws -> T) throws -> T {
        let createDB = { () throws -> SQLite in
            let db = try SQLite(location: self.location)
            try self.createSchemaIfNecessary(db: db)
            return db
        }

        let db = try stateLock.withLock { () -> SQLite in
            let db: SQLite
            switch (self.location, self.state) {
            case (.path(let path), .connected(let database)):
                if self.fileSystem.exists(path) {
                    db = database
                } else {
                    try database.close()
                    try self.fileSystem.createDirectory(path.parentDirectory, recursive: true)
                    db = try createDB()
                }
            case (.path(let path), _):
                if !self.fileSystem.exists(path) {
                    try self.fileSystem.createDirectory(path.parentDirectory, recursive: true)
                }
                db = try createDB()
            case (_, .connected(let database)):
                db = database
            case (_, _):
                db = try createDB()
            }
            self.state = .connected(db)
            return db
        }

        return try body(db)
    }

    func populateTargetTrie(callback: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        self.queue.async {
            self.targetTrieReady.memoize {
                do {
                    // Use FTS to build the trie
                    let query = "SELECT collection_id_blob_base64, package_repository_url, name FROM \(Self.targetsFTSName);"
                    try self.executeStatement(query) { statement in
                        while let row = try statement.step() {
                            if self.isShuttingdown.get() ?? false { return }

                            let targetName = row.string(at: 2)

                            if let collectionData = Data(base64Encoded: row.string(at: 0)),
                                let collection = try? self.decoder.decode(Model.CollectionIdentifier.self, from: collectionData) {
                                let collectionPackage = CollectionPackage(collection: collection, package: PackageIdentity(url: row.string(at: 1)))
                                self.targetTrie.insert(word: targetName.lowercased(), foundIn: collectionPackage)
                            }
                        }
                    }
                    callback(.success(()))
                    return true
                } catch {
                    callback(.failure(error))
                    return false
                }
            }
        }
    }

    // For `Trie`
    private struct CollectionPackage: Hashable, CustomStringConvertible {
        let collection: Model.CollectionIdentifier
        let package: PackageIdentity

        var description: String {
            "\(collection): \(package)"
        }
    }
}

// MARK: - Utility

private extension Model.Collection.Identifier {
    func databaseKey() -> String {
        switch self {
        case .json(let url):
            return url.absoluteString
        }
    }
}
