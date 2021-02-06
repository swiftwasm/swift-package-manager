# Contributing to Swift Package Manager
There are several types of contributions one can make. Bug fixes, documentation and enhancements that do not materially change the user facing semantics of Swift Package Manager should be submitted directly as PR.

Larger changes that do materially change the semantics of Swift Package Manager (e.g. changes to the manifest format or behavior) are required to go through [Swift Evolution Process](https://github.com/apple/swift-evolution/blob/master/process.md).

To see how previous evolution decisions for SwiftPM have been made and have some direction for the development of future features please check out the [Community Proposals](https://forums.swift.org/tag/packagemanager).

For more information about making contributions to the Swift project in general see [Swift Contribution Guide](https://swift.org/contributing/).

## Reporting issues
* [SwiftPM JIRA Bug Tracker](https://bugs.swift.org/browse/SR-13640?jql=component%20%3D%20%22Package%20Manager%22).
* [Guide for filing quality bug reports](https://github.com/apple/swift-package-manager/blob/main/Documentation/Resources.md#reporting-a-good-swiftpm-bug).

## Development environment

First, clone a copy of SwiftPM code from https://github.com/apple/swift-package-manager.

If you are preparing to make a contribution you should fork the repository first and clone the fork which will make opening Pull Requests easier. See "Creating Pull Requests" section below.

SwiftPM is typically built with a pre-existing version of SwiftPM present on the system, but there are multiple ways to setup your development environment:

### Using Xcode (Easiest)

1. Install Xcode from [https://developer.apple.com/xcode](https://developer.apple.com/xcode) (including betas!).
2. Verify the expected version of Xcode was installed.
3. Open SwiftPM's `Package.swift` manifest with Xcode, and use Xcode to edit the code, build, and run the tests.

### Using the Command Line

If you are using macOS and have Xcode installed, you can use the command line even without downloading and installing a toolchain, otherwise, you first need to doownload and install one.

#### Installing the toolchain

1. Download a toolchain from https://swift.org/download/
2. Install it and verify the expected version of the toolchain was installed:

**macOS**
```bash
$> export TOOLCHAINS=swift
```

Verify that we're able to find the swift compiler from the installed toolchain.
```bash
$> xcrun --find swift
/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift
$> swift package --version
Swift Package Manager - Swift 5.3.0
$> swift --version
Apple Swift version 5.3
```

**Linux**
```bash
$> export PATH=/path/to/swift-toolchain/usr/bin:"${PATH}"
```
Verify that we're able to find the swift compiler from the installed toolchain.
```bash
$> which swift
/path/to/swift-toolchain/usr/bin/swift
$> swift package --version
Swift Package Manager - Swift 5.3.0
$> swift --version
Apple Swift version 5.3
```

Note:  Alternatively use tools like [swiftenv](https://github.com/kylef/swiftenv) that help manage toolchains versions.

#### Building

```bash
$> swift build
```

A successful build will create a `.build/` directory with the following approximate structure:
```bash
artifacts/
checkouts/
debug/
repositories
x86_64-apple-macosx
```

Binary artifacts are located in `x86_64-apple-macosx/` when building on macOS, 
or the equivalent on other architectures and operating systems.

These binaries can be used to test the code modification. For example, to test the `swift package init` and `swift build` commands from the new SwiftPM artifacts in `.build/`:

```bash
$> cd /tmp && mkdir hello && cd hello
$> /path/to/swiftpm/.build/x86_64-apple-macosx/debug/swift-package init
$> /path/to/swiftpm/.build/x86_64-apple-macosx/debug/swift-build
```

#### Testing

```bash
$> swift test
```

to run a single test:

```bash
$> swift test --filter PackageGraphTests.DependencyResolverTests/testBasics
```

Or another example, to run tests for the test targets BuildTests and WorkspaceTests, but skip some test cases:

```bash
$> swift test --filter BuildTests --skip BuildPlanTests --filter WorkspaceTests --skip InitTests
```

To run the performance tests, enable them with an ENV variable:

```bash
$> export TSC_ENABLE_PERF_TESTS=1
$> swift test -c release --filter PerformanceTests
```

### Using the bootstrap script

The bootstrap script is designed for building SwiftPM on systems that do not have Xcode or a toolchain installed.
It is used on bare systems to bootstrap the Swift toolchain (including SwiftPM), and as such not typically used outside the Swift team.

the bootstrap script requires having [CMake](https://cmake.org/) and [Ninja](https://ninja-build.org/) installed. 
Please refer to the [Swift project repo](https://github.com/apple/swift/blob/master/README.md#macos) for installation instructions.

1. Clone [llbuild](https://github.com/apple/swift-llbuild) beside the SwiftPM directory.

```bash
$> git clone https://github.com/apple/swift-llbuild llbuild
```

Note: Make sure the directory for llbuild is called "llbuild" and not
    "swift-llbuild".

2. Clone [Yams](https://github.com/jpsim/yams) beside the SwiftPM directory.

```bash
$> git clone https://github.com/jpsim/yams
```

3. Clone [swift-driver](https://github.com/apple/swift-driver) beside the SwiftPM directory.

```bash
$> git clone https://github.com/apple/swift-driver
```

4. Clone [swift-argument-parser](https://github.com/apple/swift-argument-parser) beside the SwiftPM directory and check out tag with the [latest version](https://github.com/apple/swift-argument-parser/tags).

For example, if the latest tag is 0.3.1:
```bash
$> git clone https://github.com/apple/swift-argument-parser --branch 0.3.1
```

5. Clone [swift-crypto](https://github.com/apple/swift-crypto) beside the SwiftPM directory and check out tag with the [latest version](https://github.com/apple/swift-crypto/tags).

For example, if the latest tag is 1.1.3:
```bash
$> git clone https://github.com/apple/swift-crypto --branch 1.1.3
```

#### Building

```bash
$> Utilities/bootstrap build
```

See "Using the Command Line / Building" section above for more information on how to test the new artifacts.

#### Testing

```bash
$> Utilities/bootstrap test
```

## Testing locally

Before submitting code modification as Pull Requests, test locally across the supported platforms and build variants.

1. If using Xcode, run all the unit tests and verify they pass.
2. If using the Command Line, run all the unit tests and verify they pass.

```bash
$> swift test
```

3. Optionally: Test with the bootstrap script as well.

```bash
$> Utilities/bootstrap test
```

When developing on macOS and need to test on Linux, install [Docker](https://www.docker.com/products/docker-desktop) and use the following commands:

```bash
$> Utilities/Docker/docker-utils build # will build an image with the latest Swift snapshot
$> Utilities/Docker/docker-utils bootstrap # will bootstrap SwiftPM on the Linux container
$> Utilities/Docker/docker-utils run bash # to run an interactive Bash shell in the container
$> Utilities/Docker/docker-utils swift-build # to run swift-build in the container
$> Utilities/Docker/docker-utils swift-test # to run swift-test in the container
$> Utilities/Docker/docker-utils swift-run # to run swift-run in the container
```

## Creating Pull Requests
1. Fork: https://github.com/apple/swift-package-manager
2. Clone a working copy of your fork
3. Create a new branch
4. Make your code changes
5. Try to keep your changes (when possible) below 200 lines of code.
6. We use [SwiftFormat](https://www.github.com/nicklockwood/SwiftFormat) to enforce code style. Please install and run SwiftFormat before submitting your PR.
7. Commit (include the Radar link or JIRA issue id in the commit message if possible and a description your changes). Try to have only 1 commit in your PR (but, of course, if you add changes that can be helpful to be kept aside from the previous commit, make a new commit for them).
8. Push the commit / branch to your fork
9. Make a PR from your fork / branch to `apple: main`
10. While creating your PR, make sure to follow the PR Template providing information about the motivation and highlighting the changes.
11. Reviewers are going to be automatically added to your PR
12. Merge pull request when you received approval from the reviewers (one or more)

## Using Continuous Integration
SwiftPM uses [swift-ci](https://ci.swift.org) infrastructure for its continuous integration testing. The bots can be triggered on pull-requests if you have commit access. Otherwise, ask one of the code owners to trigger them for you.

Run tests with the trunk compiler and other projects. This is **required** before
a pull-request can be merged.

```
@swift-ci please smoke test
```

Run just the self-hosted tests. This has fast turnaround times so it can be used
to get quick feedback.

Note: Smoke tests are still required for merging pull-requests.

## Advanced
### Using Custom Swift Compilers
SwiftPM needs the Swift compiler to parse `Package.swift` manifest files and to
compile Swift source files. You can use the `SWIFT_EXEC` and `SWIFT_EXEC_MANIFEST`
environment variables to control which compiler to use for these operations.

`SWIFT_EXEC_MANIFEST`: This variable controls which compiler to use for parsing
`Package.swift` manifest files. The lookup order for the manifest compiler is:
`SWIFT_EXEC_MANIFEST`, `swiftc` adjacent to the `swiftpm` binaries, then `SWIFT_EXEC`

`SWIFT_EXEC`: This variable controls which compiler to use for compiling Swift
sources. The lookup order for the sources' compiler is: `SWIFT_EXEC`, then `swiftc` adjacent
to `swiftpm` binaries. This is also useful for Swift compiler developers when they
want to use a debug compiler with SwiftPM.

```bash
$> SWIFT_EXEC=/path/to/my/built/swiftc swift build
```

### Overriding the Path to the Runtime Libraries
SwiftPM computes the path of its runtime libraries relative to where it is
installed. This path can be overridden by setting the environment variable
`SWIFTPM_PD_LIBS` to a directory containing the libraries, or a colon-separated list of
absolute search paths. SwiftPM will choose the first
path which exists on disk. If none of the paths are present on disk, it will fall
back to built-in computation.

### Making changes in TSC targets
SwiftPM uses [Tools Support Core](https://github.com/apple/swift-tools-support-core) (aka TSC) for many of its general purpose utilities. Changes in SwiftPM often require changes in TSC first. To coordinate changes, open a PR against TSC first, then a second one against SwiftPM pulling the correct TSC version.

## Community and Support
If you want to connect with the Swift community you can:
* Use Swift Forums: [https://forums.swift.org/c/development/SwiftPM](https://forums.swift.org/c/development/SwiftPM)
* Contact the CODEOWNERS: https://github.com/apple/swift-package-manager/blob/main/CODEOWNERS

## Additional resources
* `Swift.org` Contributing page
[https://swift.org/contributing/](https://swift.org/contributing/)
* License
[https://swift.org/LICENSE.txt](https://swift.org/LICENSE.txt)
* Code of Conduct
[https://swift.org/community/#code-of-conduct](https://swift.org/community/#code-of-conduct)

## Troubleshooting
* If during `swift build` you encounter this error:
```bash
/../apple-repos/swift-package-manager/.build/checkouts/swift-driver/Sources/SwiftDriver/Explicit Module Builds/InterModuleDependencyGraph.swift:102:3: error: unknown attribute '_spi'
  @_spi(Testing) public var isFramework: Bool
  ^
```
Make sure you are using SwiftPM 5.3
```bash
$> swift package --version
Swift Package Manager - Swift 5.3.0
```
* If during `swift build` you encounter this error:
```bash
/../swift-package-manager/Sources/PackageLoading/Target+PkgConfig.swift:84:36: error: type 'PkgConfigError' has no member 'prohibitedFlags'
            error = PkgConfigError.prohibitedFlags(filtered.unallowed.joined(separator: ", "))
                    ~~~~~~~~~~~~~~ ^~~~~~~~~~~~~~~
```
Make sure to update your TSC (Tools Support Core):
```bash
$> swift package update
```
Alternatively, if you are using Xcode, you can update to the latest version of all packages:  
**Xcode App** > *File* > *Swift Packages* > *Update to Latest Package Versions*
