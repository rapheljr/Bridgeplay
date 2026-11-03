// EpicManifestScanner.swift
// Scans, registers, and manages Epic Games Store .item manifests
// for both the legacy EpicGamesLauncher and the new Epic Games Launcher Preview.

import Foundation
import Observation

/// Specific errors encountered while inspecting or adapting Epic Games Store manifests.
public enum EpicScannerError: LocalizedError, Sendable {
    case installLocationNotFound(URL)
    case trampolinePayloadMissing
    case manifestCorrupt(URL)
    case targetExeNotFound

    public var errorDescription: String? {
        switch self {
        case .installLocationNotFound(let url):
            return String(localized: "Install location does not exist: \(url.path(percentEncoded: false))")
        case .trampolinePayloadMissing:
            return String(localized: "Universal bridgeplay-epic-trampoline binary not found in app payload or support folder.")
        case .manifestCorrupt(let url):
            return String(localized: "Manifest is corrupt or unreadable at: \(url.path(percentEncoded: false))")
        case .targetExeNotFound:
            return String(localized: "Original executable target could not be determined.")
        }
    }
}

/// Decoded representation of an Epic Games Store `.item` JSON manifest.
public struct EpicItemManifest: Codable, Sendable {
    public let formatVersion: Int?
    public let appVersionString: String?
    public var launchExecutable: String
    public let launchCommand: String?
    public let catalogItemId: String
    public let catalogNamespace: String?
    public let appName: String
    public let displayName: String
    public let installLocation: String
    public let mainGameAppName: String?
    public var bIsManaged: Bool?
    public var bNeedsValidation: Bool?
    public var bRequiresAuth: Bool?
    public var bCanRunOffline: Bool?

    enum CodingKeys: String, CodingKey {
        case formatVersion = "FormatVersion"
        case appVersionString = "AppVersionString"
        case launchExecutable = "LaunchExecutable"
        case launchCommand = "LaunchCommand"
        case catalogItemId = "CatalogItemId"
        case catalogNamespace = "CatalogNamespace"
        case appName = "AppName"
        case displayName = "DisplayName"
        case installLocation = "InstallLocation"
        case mainGameAppName = "MainGameAppName"
        case bIsManaged
        case bNeedsValidation
        case bRequiresAuth
        case bCanRunOffline
    }
}

/// Discovered game entry from the Epic Games Launcher.
public struct EpicInstalledGame: Identifiable, Sendable, Hashable {
    public var id: String { catalogItemId }
    public let catalogItemId: String
    public let appName: String
    public let displayName: String
    public let installLocation: URL
    public let launchExecutable: String
    public let manifestURL: URL
    public let isTrampolineActive: Bool
    public let isWindowsGame: Bool

    public init(
        catalogItemId: String,
        appName: String,
        displayName: String,
        installLocation: URL,
        launchExecutable: String,
        manifestURL: URL,
        isTrampolineActive: Bool,
        isWindowsGame: Bool
    ) {
        self.catalogItemId = catalogItemId
        self.appName = appName
        self.displayName = displayName
        self.installLocation = installLocation
        self.launchExecutable = launchExecutable
        self.manifestURL = manifestURL
        self.isTrampolineActive = isTrampolineActive
        self.isWindowsGame = isWindowsGame
    }
}

/// Scanner and manager for Epic Games Store installations.
@MainActor
@Observable
public final class EpicManifestScanner {

    public static let shared = EpicManifestScanner()

    public private(set) var installedGames: [EpicInstalledGame] = []
    public private(set) var isScanning = false
    public private(set) var lastScanError: String?

    private let fileManager = FileManager.default
    private static let trampolineBinaryName = "bridgeplay-epic-trampoline"
    private static let targetMetadataFileName = "bridgeplay-target.txt"

    public init() {}

    /// Candidate directory search paths for Epic manifests (Legacy + Preview).
    public static var defaultManifestSearchDirectories: [URL] {
        let home = URL(filePath: NSHomeDirectory())
        let appSupport = home.appending(path: "Library/Application Support/Epic")

        var paths: [URL] = [
            // Standard / Legacy Epic Games Launcher
            appSupport.appending(path: "EpicGamesLauncher/Data/Manifests"),
            // Epic Games Launcher Preview (October 2026+)
            appSupport.appending(path: "EpicGamesLauncherPreview/Data/Manifests"),
            // Epic Online Services / Modern EOS Engine Storage
            appSupport.appending(path: "EpicOnlineServices/Data/Manifests")
        ]

        // Custom environment override for test or custom library configurations
        if let custom = ProcessInfo.processInfo.environment["EPIC_MANIFESTS_PATH"], !custom.isEmpty {
            paths.insert(URL(filePath: custom), at: 0)
        }

        return paths
    }

    /// Scans candidate directories and updates `installedGames`.
    @discardableResult
    public func scan(customDirectories: [URL]? = nil) async -> [EpicInstalledGame] {
        isScanning = true
        lastScanError = nil
        defer { isScanning = false }

        let searchDirs = customDirectories ?? Self.defaultManifestSearchDirectories
        var discovered: [EpicInstalledGame] = []
        var seenIDs = Set<String>()

        for dir in searchDirs {
            guard fileManager.fileExists(atPath: dir.path(percentEncoded: false)) else {
                continue
            }

            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for fileURL in files {
                guard fileURL.pathExtension.lowercased() == "item" else { continue }
                if let game = parseManifest(at: fileURL) {
                    if !seenIDs.contains(game.catalogItemId) {
                        seenIDs.insert(game.catalogItemId)
                        discovered.append(game)
                    }
                }
            }
        }

        self.installedGames = discovered.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return self.installedGames
    }

    /// Parses an individual .item manifest file.
    public func parseManifest(at url: URL) -> EpicInstalledGame? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let manifest = try? JSONDecoder().decode(EpicItemManifest.self, from: data) else {
            return nil
        }

        let normalizedID = manifest.catalogItemId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }

        let installURL = URL(filePath: manifest.installLocation)
        let trampolinePath = installURL.appending(path: Self.trampolineBinaryName).path(percentEncoded: false)
        let isTrampolinePresent = fileManager.fileExists(atPath: trampolinePath)
        let isTrampolineActive = manifest.launchExecutable == Self.trampolineBinaryName || isTrampolinePresent

        // Check if there is an original target saved
        var effectiveExe = manifest.launchExecutable
        let targetFileURL = installURL.appending(path: Self.targetMetadataFileName)
        if let saved = try? String(contentsOf: targetFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            effectiveExe = saved
        }

        // Determine whether this is a Windows game
        let exeLower = effectiveExe.lowercased()
        let isWindowsTarget = exeLower.hasSuffix(".exe") || exeLower.hasSuffix(".bat") || exeLower.hasSuffix(".cmd")
        var isWindowsFolder = false

        if fileManager.fileExists(atPath: installURL.path(percentEncoded: false)) {
            // Check for Windows binaries inside install location
            if let files = try? fileManager.contentsOfDirectory(atPath: installURL.path(percentEncoded: false)) {
                isWindowsFolder = files.contains { name in
                    let lower = name.lowercased()
                    return lower.hasSuffix(".exe") || lower.hasSuffix(".dll") || lower == "playgtav.exe" || lower == "gta5.exe"
                }
            }
        }

        let isWindows = isWindowsTarget || isWindowsFolder || isTrampolineActive

        return EpicInstalledGame(
            catalogItemId: normalizedID,
            appName: manifest.appName,
            displayName: manifest.displayName,
            installLocation: installURL,
            launchExecutable: effectiveExe,
            manifestURL: url,
            isTrampolineActive: isTrampolineActive,
            isWindowsGame: isWindows
        )
    }

    /// Deploys the universal bridgeplay-epic-trampoline into the game's InstallLocation
    /// and safely adapts the .item manifest to bypass Unreal Engine validation checks.
    public func enableBridgeplay(for game: EpicInstalledGame) throws {
        let installURL = game.installLocation
        guard fileManager.fileExists(atPath: installURL.path(percentEncoded: false)) else {
            throw EpicScannerError.installLocationNotFound(installURL)
        }

        var sourceURL: URL?

        // 1. Check bundled payload
        if let payloadURL = Bundle.main.resourceURL?.appending(path: "payload/\(Self.trampolineBinaryName)"),
           fileManager.fileExists(atPath: payloadURL.path(percentEncoded: false)) {
            sourceURL = payloadURL
        }

        // 2. Check ~/Library/Application Support/bridgeplay
        if sourceURL == nil {
            let supportURL = URL(filePath: NSHomeDirectory())
                .appending(path: "Library/Application Support/bridgeplay/\(Self.trampolineBinaryName)")
            if fileManager.fileExists(atPath: supportURL.path(percentEncoded: false)) {
                sourceURL = supportURL
            }
        }

        guard let source = sourceURL else {
            throw EpicScannerError.trampolinePayloadMissing
        }

        // 3. Preserve original target executable in bridgeplay-target.txt
        let targetFileURL = installURL.appending(path: Self.targetMetadataFileName)
        let originalExe = game.launchExecutable
        if !fileManager.fileExists(atPath: targetFileURL.path(percentEncoded: false)) && originalExe != Self.trampolineBinaryName {
            try originalExe.write(to: targetFileURL, atomically: true, encoding: .utf8)
        }

        // 4. Copy trampoline into InstallLocation
        let destTrampoline = installURL.appending(path: Self.trampolineBinaryName)
        let destPath = destTrampoline.path(percentEncoded: false)
        if fileManager.fileExists(atPath: destPath) {
            try fileManager.removeItem(at: destTrampoline)
        }
        try fileManager.copyItem(at: source, to: destTrampoline)

        // Make executable (0755)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)

        // 5. Read manifest, update flags, set LaunchExecutable
        let manifestData = try Data(contentsOf: game.manifestURL)
        guard var manifest = try? JSONDecoder().decode(EpicItemManifest.self, from: manifestData) else {
            throw EpicScannerError.manifestCorrupt(game.manifestURL)
        }

        manifest.launchExecutable = Self.trampolineBinaryName
        manifest.bNeedsValidation = false
        manifest.bIsManaged = false
        manifest.bRequiresAuth = true
        manifest.bCanRunOffline = true

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let updatedData = try encoder.encode(manifest)
        try updatedData.write(to: game.manifestURL, options: .atomic)
    }

    /// Reverts an Epic installation from Bridgeplay back to stock launcher configuration.
    public func disableBridgeplay(for game: EpicInstalledGame) throws {
        let installURL = game.installLocation
        let destTrampoline = installURL.appending(path: Self.trampolineBinaryName)
        let targetFileURL = installURL.appending(path: Self.targetMetadataFileName)

        var restoredExe = game.launchExecutable
        if let saved = try? String(contentsOf: targetFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            restoredExe = saved
        }

        // 1. Remove trampoline binary
        if fileManager.fileExists(atPath: destTrampoline.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: destTrampoline)
        }

        // 2. Remove target metadata file
        if fileManager.fileExists(atPath: targetFileURL.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: targetFileURL)
        }

        // 3. Revert manifest to original executable
        let manifestData = try Data(contentsOf: game.manifestURL)
        guard var manifest = try? JSONDecoder().decode(EpicItemManifest.self, from: manifestData) else {
            throw EpicScannerError.manifestCorrupt(game.manifestURL)
        }

        manifest.launchExecutable = restoredExe
        manifest.bNeedsValidation = false
        manifest.bIsManaged = true

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let updatedData = try encoder.encode(manifest)
        try updatedData.write(to: game.manifestURL, options: .atomic)
    }
}
