/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import struct Foundation.Date
import struct Foundation.URL

import PackageModel
import SourceControl
import TSCUtility

public enum PackageCollectionsModel {}

extension PackageCollectionsModel {
    /// A `PackageCollection` is a collection of packages.
    public struct Collection: Equatable, Codable {
        public typealias Identifier = CollectionIdentifier
        public typealias Source = CollectionSource

        /// The identifier of the collection
        public let identifier: Identifier

        /// Where the collection and its contents are obtained
        public let source: Source

        /// The name of the collection
        public let name: String

        /// The description of the collection
        public let description: String?

        /// Keywords for the collection
        public let keywords: [String]?

        /// Metadata of packages belonging to the collection
        public let packages: [Package]

        /// When this collection was created/published by the source
        public let createdAt: Date

        /// When this collection was last processed locally
        public let lastProcessedAt: Date

        /// Initializes a `PackageCollection`
        init(
            source: Source,
            name: String,
            description: String?,
            keywords: [String]?,
            packages: [Package],
            createdAt: Date,
            lastProcessedAt: Date = Date()
        ) {
            self.identifier = .init(from: source)
            self.source = source
            self.name = name
            self.description = description
            self.keywords = keywords
            self.packages = packages
            self.createdAt = createdAt
            self.lastProcessedAt = lastProcessedAt
        }
    }
}

extension PackageCollectionsModel {
    /// Represents the source of a `PackageCollection`
    public struct CollectionSource: Equatable, Hashable, Codable {
        /// Source type
        public let type: CollectionSourceType

        /// URL of the source file
        public let url: URL

        public init(type: CollectionSourceType, url: URL) {
            self.type = type
            self.url = url
        }
    }

    /// Represents the source type of a `PackageCollection`
    public enum CollectionSourceType: String, Codable, CaseIterable {
        case json
    }
}

extension PackageCollectionsModel {
    /// Represents the identifier of a `PackageCollection`
    public enum CollectionIdentifier: Hashable, Comparable {
        /// JSON based package collection at URL
        case json(URL)

        /// Creates an `Identifier` from `Source`
        init(from source: CollectionSource) {
            switch source.type {
            case .json:
                self = .json(source.url)
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.json(let lhs), .json(let rhs)):
                return lhs.absoluteString < rhs.absoluteString
            }
        }
    }
}

extension PackageCollectionsModel.CollectionIdentifier: Codable {
    public enum DiscriminatorKeys: String, Codable {
        case json
    }

    public enum CodingKeys: CodingKey {
        case _case
        case url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .json:
            let url = try container.decode(URL.self, forKey: .url)
            self = .json(url)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .json(let url):
            try container.encode(DiscriminatorKeys.json, forKey: ._case)
            try container.encode(url, forKey: .url)
        }
    }
}

// FIXME: add minimumPlatformVersions
extension PackageCollectionsModel.Collection {
    /// A representation of package metadata
    public struct Package: Equatable, Codable {
        public typealias Version = PackageVersion

        /// Package reference
        public let reference: PackageReference

        /// Package's repository address
        public let repository: RepositorySpecifier

        /// A summary about the package
        public let summary: String?

        /// Published versions of the package
        public let versions: [Version]

        /// URL of the package's README
        public let readmeURL: URL?

        /// Initializes a `Package`
        init(
            repository: RepositorySpecifier,
            summary: String?,
            versions: [Version],
            readmeURL: URL?
        ) {
            self.reference = .init(repository: repository)
            self.repository = repository
            self.summary = summary
            self.versions = versions
            self.readmeURL = readmeURL
        }
    }
}

extension PackageCollectionsModel.Collection {
    /// A representation of package version
    public struct PackageVersion: Equatable, Codable {
        public typealias Target = PackageCollectionsModel.PackageTarget
        public typealias Product = PackageCollectionsModel.PackageProduct

        /// The version
        public let version: TSCUtility.Version

        /// The package name
        public let packageName: String

        // Custom instead of `PackageModel.Target` because we don't need the additional details
        /// The package version's targets
        public let targets: [Target]

        // Custom instead of `PackageModel.Product` because of the simplified `Target`
        /// The package version's products
        public let products: [Product]

        /// The package version's Swift tools version
        public let toolsVersion: ToolsVersion

        /// The package version's supported platforms verified to work
        public let verifiedPlatforms: [PackageModel.Platform]?

        /// The package version's Swift versions verified to work
        public let verifiedSwiftVersions: [SwiftLanguageVersion]?

        /// The package version's license
        public let license: PackageCollectionsModel.License?
    }
}
