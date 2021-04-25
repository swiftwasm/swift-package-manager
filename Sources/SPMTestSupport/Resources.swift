/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic
import SPMBuildCore
import Foundation
import PackageLoading
import Workspace
import Build

#if os(macOS)
private func bundleRoot() -> AbsolutePath {
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return AbsolutePath(bundle.bundlePath).parentDirectory
    }
    fatalError()
}
#endif

public class Resources: ManifestResourceProvider {

    public var swiftCompiler: AbsolutePath {
        return toolchain.manifestResources.swiftCompiler
    }

    public var libDir: AbsolutePath {
        return toolchain.manifestResources.libDir
    }

    public var binDir: AbsolutePath? {
        return toolchain.manifestResources.binDir
    }

    public var swiftCompilerFlags: [String] {
        return []
    }

  #if os(macOS)
    public var sdkPlatformFrameworksPath: AbsolutePath {
        return Destination.sdkPlatformFrameworkPaths()!.fwk
    }
  #endif

    public let toolchain: UserToolchain

    public static let `default` = Resources()

    private init() {
        let binDir: AbsolutePath
      #if os(macOS)
        binDir = bundleRoot()
      #else
        binDir = AbsolutePath(CommandLine.arguments[0], relativeTo: localFileSystem.currentWorkingDirectory!).parentDirectory
      #endif
        let searchPaths = getEnvSearchPaths(
            pathString: ProcessEnv.vars["PATH"], currentWorkingDirectory: localFileSystem.currentWorkingDirectory)
        toolchain = try! UserToolchain(destination: Destination.hostDestination(binDir), searchPaths: searchPaths)
    }

    /// True if SwiftPM has PackageDescription 4 runtime available.
    public static var havePD4Runtime: Bool {
        return Resources.default.binDir == nil
    }
    
    public let swiftCompilerSupportsRenamingMainSymbol = SwiftTargetBuildDescription.checkSupportedFrontendFlags(flags: ["entry-point-function-name"], fs: localFileSystem)
}
