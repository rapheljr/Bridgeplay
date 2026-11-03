// Integration of Alexander Theißen's (athei) mach9 engine: an ARM64-native Wine runner
// with FEX-Emu, KosmicKrisp / vkd3d-proton, DXMT, and mtld3d for macOS Tahoe+.
// https://github.com/athei/mach9

import Foundation

struct Mach9Release: Sendable {
    let build: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let bundleName: String
    let loaderSHA256: String
    let runner: RunnerBuild
    let ntdllPatches: [NtdllPatch]
}

enum FreeEngineMach9 {

    static let step = "Download free Mach9 engine"

    static let current = v010
    static let releases = [current]

    static var runnerBuilds: [RunnerBuild] { releases.map(\.runner) }

    static func release(build id: String) -> Mach9Release? {
        releases.first { $0.build == id }
    }

    static func release(forRoot root: URL) -> Mach9Release? {
        let loader = Clean.copy(of: CrossOverSource.unixLoader(inRoot: root))
        guard let hash = Digest.sha256IfPresent(loader) else { return nil }
        return releases.first { $0.runner.loaderSHA256 == hash }
    }

    static func downloads(for release: Mach9Release = current) -> URL {
        SupportPaths.home.appending(
            path: "Library/Caches/\(SupportPaths.supportDirName)/engines/\(release.build)",
            directoryHint: .isDirectory
        )
    }

    static func bundle(for release: Mach9Release = current, engines: URL = SupportPaths.engines) -> URL {
        engines.appending(path: release.bundleName, directoryHint: .isDirectory)
    }

    static func isInstalled(_ release: Mach9Release = current, engines: URL = SupportPaths.engines) -> Bool {
        let install = CrossOverSource.inspect(bundle: bundle(for: release, engines: engines))
        guard case .supported(let build) = install.support, build.id == release.build else { return false }
        return isInstalled(root: install.crossOverRoot, release: release)
    }

    static func isInstalled(root: URL, release: Mach9Release = current) -> Bool {
        let loader = Clean.copy(of: CrossOverSource.unixLoader(inRoot: root))
        guard Digest.sha256IfPresent(loader) == release.runner.loaderSHA256 else { return false }
        for (arch, cleanHash) in release.runner.cleanNtdll {
            let ntdll = NtdllPatcher.cleanSource(inRoot: root, arch: arch)
            guard Digest.sha256IfPresent(ntdll) == cleanHash else { return false }
        }
        return true
    }

    enum Phase: Sendable {
        case downloading(PinnedDownload.Progress)
        case unpacking

        var label: String {
            switch self {
            case .downloading(let progress): progress.label
            case .unpacking: "Unpacking Mach9"
            }
        }
    }

    static func install(
        _ release: Mach9Release = current,
        engines: URL = SupportPaths.engines,
        report: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> CrossOverInstall {
        let archive = try await PinnedDownload.obtain(
            file: release.archive, sha256: release.sha256, bases: release.bases,
            into: downloads(for: release), step: step, from: "Mach9",
            report: { report(.downloading($0)) }
        )
        report(.unpacking)
        return try unpack(archive, release: release, engines: engines)
    }

    static func unpack(
        _ archive: URL,
        release: Mach9Release = current,
        engines: URL = SupportPaths.engines
    ) throws -> CrossOverInstall {
        let fm = FileManager.default
        let staging = engines.appending(path: ".\(release.bundleName).new", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let shaped = staging.appending(path: release.bundleName, directoryHint: .isDirectory)
        let root = SupportPaths.crossOverRoot(inBundle: shaped)
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)

        try DiskImage.withMounted(archive) { mount in
            let wine = mount.appending(path: "Mach9.app/Contents/Resources/wine", directoryHint: .isDirectory)
            guard fm.fileExists(atPath: wine.appending(path: "lib/wine").path(percentEncoded: false)) else {
                throw StepFailure(step: step, detail: "\(release.archive) has no Wine tree at Mach9.app/Contents/Resources/wine.")
            }
            let copied = try Shell.run("/bin/cp", ["-R", wine.path(percentEncoded: false), root.path(percentEncoded: false)])
            guard copied.status == 0 else {
                throw StepFailure(
                    step: step,
                    detail: "Copying Mach9 Wine tree failed: \(copied.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
        }

        let info: [String: Any] = [
            "CFBundleIdentifier": "app.mach9.notproton",
            "CFBundleName": release.bundleName.replacingOccurrences(of: ".app", with: ""),
            "CFBundleShortVersionString": release.build.replacingOccurrences(of: "mach9-", with: ""),
            "CFBundleVersion": release.build,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: shaped.appending(path: "Contents/Info.plist"))
        try RunnerInstaller.clearQuarantine(at: shaped)

        let install = CrossOverSource.inspect(bundle: shaped)
        guard case .supported(let build) = install.support, build.id == release.build else {
            throw StepFailure(
                step: step,
                detail: "The unpacked Mach9 Wine loader is not the \(release.build) build Bridgeplay was made for."
            )
        }

        try fm.createDirectory(at: engines, withIntermediateDirectories: true)
        let target = bundle(for: release, engines: engines)
        if fm.fileExists(atPath: target.path(percentEncoded: false)) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: shaped, to: target)
        return CrossOverSource.inspect(bundle: target)
    }

    static let v010 = Mach9Release(
        build: "mach9-0.1.0",
        archive: "Mach9.dmg",
        sha256: "2f11f4799c5d52f61d1ac5760f1cdce7359ceacc22f62eacb8a2830fbc416d13",
        bases: [
            URL(string: "https://updates.mach9.app")!,
        ],
        bundleName: "Mach9 0.1.0.app",
        loaderSHA256: "b725db5159279d5f8bd01b9770d6755f6b57967054315be8fa033b04c6f6798c",
        runner: RunnerBuild(
            bundleVersion: "mach9-0.1.0",
            releaseVersion: "Mach9 0.1.0",
            flavor: nil,
            loaderSHA256: "b725db5159279d5f8bd01b9770d6755f6b57967054315be8fa033b04c6f6798c",
            cleanNtdll: [
                .aarch64Windows: "a189df1dc1d5401f44efa569949a8a299ab35443d164e1bcfa3eb93caceed956",
                .i386Windows: "2be3da1241d2489d08164258b1023e12c0ae16a09f10de38821de54845b4fb92",
            ],
            patchedNtdll: [
                .aarch64Windows: "3ffc33eed09a6e99ae20a31b4461f4140228544bc9643f178b0562c485990b97",
                .i386Windows: "f810f99787db4f6de4d7c68353c91f81c875df2f19c06b24fa3816e241bd6dd9",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-mach9", flavor: .fex, display: "Mach9 0.1.0 (ARM64EC, FEX)"),
            ],
            isFree: true
        ),
        ntdllPatches: [
            NtdllPatch(
                arch: .i386Windows,
                payloadResource: "detour32-mach9",
                payloadSHA256: "8aca2eda012e1e8f260d22c3c1dd05244f5b4851a883f85f52cfa009d7c944fd",
                caveRVA: 0x6b125,
                payloadRVA: 0x6b130,
                hooks: [
                    NtdllHook(rva: 0x2ee1d, stolen: [0x8b, 0x45, 0x14, 0xa8, 0x02]),
                ],
                caveSize: 3803,
                cavePad: 0xcc,
                machine: 0x14c,
                magic: 0x10b,
                imageBase: 0x7bc0_0000,
                placement: .padding
            ),
            NtdllPatch(
                arch: .aarch64Windows,
                payloadResource: "detour64-mach9",
                payloadSHA256: "bf9eebe404003d9b244a0391108f10f4c620de786e7b76ecd487bffb30f71866",
                caveRVA: 0x101d45,
                payloadRVA: 0x101d50,
                hooks: [
                    NtdllHook(rva: 0x4859c, stolen: [0x1f, 0x20, 0x03, 0xd5]),
                    NtdllHook(rva: 0xa7eb0, stolen: [0x1f, 0x20, 0x03, 0xd5]),
                ],
                caveSize: 58043,
                cavePad: 0xcc,
                machine: 0xaa64,
                magic: 0x20b,
                imageBase: 0x1_8000_0000,
                placement: .padding
            ),
        ]
    )
}
