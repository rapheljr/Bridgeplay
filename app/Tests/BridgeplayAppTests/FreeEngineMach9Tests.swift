import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Free Mach9 engine")
struct FreeEngineMach9Tests {

    private func makeEngines() throws -> URL {
        let engines = FileManager.default.temporaryDirectory
            .appending(path: "bp-mach9-engines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: true)
        return engines
    }

    @Test("Each pinned release names a free build Bridgeplay knows how to patch",
          arguments: FreeEngineMach9.releases.map(\.build))
    func releaseIsSupported(id: String) throws {
        let release = try #require(FreeEngineMach9.release(build: id))
        let build = try #require(SupportedRunners.build(id: id))
        #expect(build == release.runner)
        #expect(build.isFree)
        #expect(Set(NtdllPatcher.patches(for: build).map(\.arch)) == [.aarch64Windows, .i386Windows])
        #expect(SupportedRunners.build(loaderSHA256: build.loaderSHA256)?.id == build.id)
        #expect(build.tools.count == 1)
        #expect(build.tools.first?.name == "bridgeplay-proton-mach9")
        #expect(build.tools.first?.flavor == .fex)
        #expect(build.tools.first?.display == "Mach9 0.1.0 (ARM64EC, FEX)")
        #expect(release.bundleName == "Mach9 0.1.0.app")
        #expect(StatusHero.engineName(release.build) == "Mach9 0.1.0")

        let patches = NtdllPatcher.patches(for: build)
        #expect(patches.count == 2)
        for patch in patches {
            let payload = try NtdllPatcher.payload(for: patch)
            #expect(Digest.sha256(of: payload) == patch.payloadSHA256)
            #expect(patch.payloadResource.contains("mach9"))
        }
    }

    @Test("Mach9 availability is gated on macOS 26.4+")
    func availabilityGate() throws {
        let expected = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
        )
        #expect(CompatTool.Flavor.mach9Available == expected)

        let tools = SupportedRunners.tools(for: [FreeEngineMach9.current.runner])
        if expected {
            #expect(tools.map(\.name).contains("bridgeplay-proton-mach9"))
        } else {
            #expect(!tools.map(\.name).contains("bridgeplay-proton-mach9"))
            // But when keeping an existing tool, it remains available
            let keeping = SupportedRunners.tools(
                for: [FreeEngineMach9.current.runner],
                keeping: ["bridgeplay-proton-mach9"]
            )
            #expect(keeping.map(\.name).contains("bridgeplay-proton-mach9"))
        }
    }

    // Runs against the real archive once it has been downloaded into Bridgeplay's cache.
    @Test("Unpacking the real archive yields a supported, license-free, patchable engine")
    func unpacksRealArchive() throws {
        let archive = FreeEngineMach9.downloads(for: FreeEngineMach9.current)
            .appending(path: FreeEngineMach9.current.archive)
        guard Digest.sha256IfPresent(archive) == FreeEngineMach9.current.sha256 else { return }

        let engines = try makeEngines()
        defer { try? FileManager.default.removeItem(at: engines) }

        let install = try FreeEngineMach9.unpack(archive, release: FreeEngineMach9.current, engines: engines)
        guard case .supported(let build) = install.support else {
            Issue.record(Comment(rawValue: "unpacked engine is \(install.support)"))
            return
        }
        #expect(build.id == FreeEngineMach9.current.build)
        #expect(install.isFree)
        #expect(FreeEngineMach9.isInstalled(FreeEngineMach9.current, engines: engines))
        #expect(CrossOverLicense.check(crossOverRoot: install.crossOverRoot).licensed)
        try RunnerInstaller.verifyClone(build: build, root: install.crossOverRoot)

        for patch in NtdllPatcher.patches(for: build) {
            let source = NtdllPatcher.cleanSource(inRoot: install.crossOverRoot, arch: patch.arch)
            let payload = try NtdllPatcher.payload(for: patch)
            let patched = try NtdllPatcher.apply(patch, to: try Data(contentsOf: source), payload: payload)
            #expect(Digest.sha256(of: patched) == build.patchedNtdll[patch.arch])
        }

        #expect(RunnerPatcher.windowsBuiltins(in: install.crossOverRoot).map(\.arch) == ["i386-windows", "aarch64-windows"])
        #expect(RunnerPatcher.unixArches(in: install.crossOverRoot) == ["aarch64-unix"])
        #expect(RunnerPatcher.builtins(in: install.crossOverRoot).map(\.name) == ["lsteamclient.dll", "lsteamclient.dll", "lsteamclient.so"])

        let sample = WinePrefix(
            appID: "1574480",
            name: "Agent 64: Spies Never Die",
            library: SteamLibrary(root: URL(filePath: "/tmp/steam")),
            lastUsed: nil
        )
        let layout = PrefixTools.layout(runner: install.crossOverRoot)
        #expect(layout.loader == install.crossOverRoot.appending(path: "lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine"))
        #expect(layout.server == install.crossOverRoot.appending(path: "bin/wineserver"))
        let env = PrefixTools.environment(prefix: sample, runner: install.crossOverRoot)
        #expect(env["WINEDLLPATH"]?.contains("aarch64-windows") == true)
        #expect(env["WINEDLLPATH"]?.contains("x86_64-windows") == false)
        #expect(SetupMach9Command.flag == "--setup-mach9")
    }
}
