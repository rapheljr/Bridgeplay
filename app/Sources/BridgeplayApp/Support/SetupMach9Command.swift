import Foundation

// What the Mach9 Engine row's "Download & Set Up" does, for scripts: installs the Mach9
// engine (reusing any pinned archive already in the download cache), sets the compatibility tool up
// and makes it Steam's default.
// Steam must be closed, since it rewrites config.vdf when it quits.
enum SetupMach9Command {
    static let flag = "--setup-mach9"

    static func run() -> Never {
        Task.detached { exit(AppLog.finished(await perform())) }
        dispatchMain()
    }

    private static func perform() async -> Int32 {
        do {
            guard CompatTool.Flavor.mach9Available else {
                throw StepFailure(step: FreeEngineMach9.step, detail: "Mach9 requires macOS 26.4 or later.")
            }
            if SteamBundle.isRunningForThisUser {
                throw StepFailure(step: FreeEngineMach9.step, detail: "Steam is running. Quit Steam and run this again.")
            }
            if DeploymentContent.current(version: AppVersion.bundled).blocksInstallation {
                throw StepFailure(step: FreeEngineMach9.step,
                                  detail: "Installation is blocked. Use the Bridgeplay app that installed this build.")
            }
            if RunnerInstaller.runningBuild() != nil {
                throw StepFailure(step: FreeEngineMach9.step,
                                  detail: "A game or Wine tool is running. Quit it before setting Mach9 up.")
            }
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }

            let install = try await FreeEngineMach9.install { say($0.label) }
            _ = try RunnerSetup.run(from: install, replacingExisting: true) { say($0.label) }

            if let tool = FreeEngineMach9.current.runner.tools.first?.name {
                do {
                    try SteamDefaultTool.set(tool)
                } catch is SteamDefaultTool.SteamRunning {
                    throw StepFailure(step: SteamDefaultTool.step,
                                      detail: "Mach9 is set up, but Steam opened in the meantime, so its default compatibility tool was not changed. Quit Steam and run this again.")
                }
                say("Steam's default compatibility tool is \(tool).")
            }
            say("Mach9 is set up.")
            return 0
        } catch {
            AppLog.note("command line failed: \(RemoveEverythingCommand.failureMessage(error))")
            FileHandle.standardError.write(Data("\(RemoveEverythingCommand.failureMessage(error))\n".utf8))
            return 1
        }
    }

    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }
}

