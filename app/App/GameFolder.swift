import Foundation

/// Where your own copy of the game lives on this iPhone. Two ways:
/// - In the app's own folder (Files › On My iPhone › GTA V Port): found automatically, at any
///   depth, with no picking and no permissions. Moving a folder within On My iPhone is instant.
/// - A folder picked in Files, which can be any folder above the game (even On My iPhone itself):
///   the app looks through it for the game and keeps access between launches with a bookmark.
/// Either way every game file is checked first (GameFiles), and the app reads the files directly
/// while you play, so no server is needed.
enum GameFolder {
    private static let bookmarkKey = "gameFolderBookmark"
    private static let nameKey = "gameFolderName"
    private static let subpathKey = "gameFolderSubpath" // from the picked folder (or the app folder) down to data/
    private static let inAppKey = "gameFolderInApp"
    /// "Play anyway": the folder (subpath) and how many problems the player accepted for it.
    private static let acceptedKey = "gameFolderAcceptedProblems"
    /// The last folder picked in Files that had problems, so the player can still use it.
    private static var pendingPick: (url: URL, report: GameFiles.Report)?
    private static var accessing: URL?
    /// Lines for the app's log (Settings › Share log), so a refused folder can be diagnosed.
    static var log: (String) -> Void = { _ in }
    /// The check of a game folder found in the app's folder that can't be used yet (shown on the start screen).
    static private(set) var appFolderReport: GameFiles.Report?
    static var appFolderProblem: String? { appFolderReport.map { $0.explanation.message } }
    /// Problem files in the folder in use, when the player chose Play anyway (0: all files fine).
    static private(set) var acceptedProblemCount = 0
    /// Game archives (zip, rar, 7z) seen by the last look, which the app can unpack.
    static private(set) var archivesFound: [URL] = []

    /// Whether the app runs inside LiveContainer, whose folder picker only hands a folder over with its Fix File
    /// Picker and Use LiveContainer's Bundle ID fixes on (a player found it, 2026-10-21). LiveContainer runs the app
    /// from its own storage, not from iOS's app folder.
    static let insideLiveContainer: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["PG_TEST_LIVECONTAINER"] == "1"
        #elseif targetEnvironment(macCatalyst)
        return false
        #else
        let executable = (CommandLine.arguments.first ?? "").lowercased()
        return executable.contains("livecontainer") || !Bundle.main.bundlePath.lowercased().contains("/containers/bundle/application/")
        #endif
    }()

    static var isChosen: Bool { inAppFolder || UserDefaults.standard.data(forKey: bookmarkKey) != nil }
    static var inAppFolder: Bool { UserDefaults.standard.bool(forKey: inAppKey) }
    static var name: String { UserDefaults.standard.string(forKey: nameKey) ?? "folder" }
    static var appFolder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func clear() {
        testMapKnown = nil
        for key in [bookmarkKey, nameKey, subpathKey, inAppKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: The app's own folder

    /// Looks for the game anywhere inside Files › On My iPhone › GTA V Port and checks every file.
    /// Returns true when a complete game was found (and remembers it). Does nothing when a picked
    /// folder is already in use. Takes about a second.
    @discardableResult
    static func findInAppFolder() -> Bool {
        if isChosen && !inAppFolder { return false }
        let previous = appFolderReport?.explanation.message
        appFolderReport = nil
        let scan = GameFiles.scan(appFolder)
        archivesFound = scan.archives
        guard let best = scan.best else {
            if inAppFolder { log("The game folder is no longer in the app's folder."); clear() }
            return false
        }
        let subpath = relative(best.data, to: appFolder)
        guard best.isComplete || accepted(best, subpath: subpath) else {
            if previous != best.explanation.message {
                log("Game folder in the app's folder can't be used (\(subpath)): \(best.problems.count) problems")
                log(best.details.split(separator: "\n").prefix(20).joined(separator: "\n"))
            }
            appFolderReport = best
            if inAppFolder { clear() }
            return false
        }
        acceptedProblemCount = best.problems.count
        if !inAppFolder || UserDefaults.standard.string(forKey: subpathKey) != subpath {
            log("Game folder found in the app's folder: \(subpath) (\(best.isComplete ? "all \(best.fileCount) files checked" : "\(best.problems.count) problem files, played anyway"))")
        }
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.set(true, forKey: inAppKey)
        testMapKnown = nil
        UserDefaults.standard.set(subpath, forKey: subpathKey)
        UserDefaults.standard.set(displayName(best.data), forKey: nameKey)
        return true
    }

    // MARK: A folder picked in Files

    /// What happened with a picked folder.
    enum Choice {
        case accepted(GameFiles.Report)
        case incomplete(GameFiles.Report)
        case archivesOnly([URL])
        case refused(String)
    }

    /// Looks through a folder picked in Files (any folder above the game, even On My iPhone itself),
    /// checks the best game folder in it and remembers it when it's complete.
    #if targetEnvironment(macCatalyst)
    // The sandboxed Mac app keeps access to a picked folder across launches only through a security-scoped bookmark.
    private static let bookmarkCreation: URL.BookmarkCreationOptions = .withSecurityScope
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let bookmarkCreation: URL.BookmarkCreationOptions = []
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = []
    #endif

    static func choose(_ picked: URL) -> Choice {
        // Folders picked in Files need security-scoped access; plain paths (tests) don't.
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        log("Folder picked: \(picked.path) (access granted: \(scoped), \(describeLocation(picked)))")
        guard FileManager.default.isReadableFile(atPath: picked.path) else {
            return .refused(AppLanguage.choose("The app was not allowed to open that folder. Move your game folder to Files › On My iPhone › GTA V Port instead; the app finds it there by itself."))
        }
        let scan = GameFiles.scan(picked)
        archivesFound = scan.archives
        guard let best = scan.best else {
            if !scan.archives.isEmpty { log("No unpacked game in the picked folder; archives: \(scan.archives.map(\.lastPathComponent))"); return .archivesOnly(scan.archives) }
            return .refused(wrongFolderMessage(picked))
        }
        let subpath = relative(best.data, to: picked)
        guard best.isComplete || accepted(best, subpath: subpath) else {
            pendingPick = (picked, best)
            log("Picked game folder can't be used (\(subpath.isEmpty ? "the picked folder" : subpath)): \(best.problems.count) problems")
            log(best.details.split(separator: "\n").prefix(20).joined(separator: "\n"))
            return .incomplete(best)
        }
        do {
            let bookmark = try picked.bookmarkData(options: bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            UserDefaults.standard.set(false, forKey: inAppKey)
            testMapKnown = nil
            UserDefaults.standard.set(subpath, forKey: subpathKey)
            UserDefaults.standard.set(displayName(best.data), forKey: nameKey)
            acceptedProblemCount = best.problems.count
            log("Game folder accepted: data at \(subpath.isEmpty ? "(the picked folder)" : subpath), all \(best.fileCount) files checked")
            return .accepted(best)
        } catch {
            return .refused(AppLanguage.interpolate(AppLanguage.choose("The app could not remember that folder: {arg0}"), [error.localizedDescription]))
        }
    }

    // MARK: Play anyway

    /// A folder with a few damaged or missing files can still be used, at the player's risk: the
    /// game may crash where it needs them. Not for iCloud-only files, which can't be read at all.
    static func playAnywayAllowed(_ report: GameFiles.Report) -> Bool {
        !report.isComplete && report.inICloud.isEmpty && report.problems.count <= 20
    }
    private static func accepted(_ report: GameFiles.Report, subpath: String) -> Bool {
        guard let saved = UserDefaults.standard.string(forKey: acceptedKey) else { return false }
        let parts = saved.split(separator: "\u{1}", maxSplits: 1).map(String.init)
        return parts.count == 2 && parts[1] == subpath && report.problems.count <= Int(parts[0]) ?? 0 && playAnywayAllowed(report)
    }
    /// Uses the folder that was just refused (in the app's folder, or the last one picked) anyway.
    @discardableResult
    static func playAnyway(_ report: GameFiles.Report) -> Bool {
        guard playAnywayAllowed(report) else { return false }
        if let pick = pendingPick, pick.report.data == report.data {
            let subpath = relative(report.data, to: pick.url)
            UserDefaults.standard.set("\(report.problems.count)\u{1}\(subpath)", forKey: acceptedKey)
            if case .accepted = choose(pick.url) { pendingPick = nil; return true }
            return false
        }
        let subpath = relative(report.data, to: appFolder)
        UserDefaults.standard.set("\(report.problems.count)\u{1}\(subpath)", forKey: acceptedKey)
        log("Playing anyway with \(report.problems.count) problem files in \(subpath)")
        return findInAppFolder()
    }

    /// The chosen game's data/ folder, with access granted for the rest of this launch.
    static func open() -> URL? {
        let subpath = UserDefaults.standard.string(forKey: subpathKey) ?? ""
        if inAppFolder {
            let data = subpath.isEmpty ? appFolder : appFolder.appendingPathComponent(subpath)
            return GameFiles.gameData(at: data) == data ? data : nil
        }
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let root = try? URL(resolvingBookmarkData: bookmark, options: bookmarkResolution, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if root.startAccessingSecurityScopedResource() { accessing = root }
        guard FileManager.default.isReadableFile(atPath: root.path) else { return nil }
        if stale, let fresh = try? root.bookmarkData(options: bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        // Folders remembered by older versions have no subpath: look again.
        let data = subpath.isEmpty ? (GameFiles.scan(root, depth: 4).best?.data ?? root) : root.appendingPathComponent(subpath)
        return GameFiles.gameData(at: data) == data ? data : nil
    }

    /// Whether the game in use includes the GTA VI test map (checked once per launch).
    static var testMapAvailable: Bool {
        if let known = testMapKnown { return known }
        let available = open().map(GameFiles.hasTestMap) ?? false
        testMapKnown = available
        if !available { log("The game files don't include the GTA VI test map; that Sandbox map is unavailable.") }
        return available
    }
    static var testMapKnown: Bool?

    /// Checks every file of the game in use (Settings › Check game files).
    static func checkChosen() -> GameFiles.Report? {
        guard let data = open() else { return nil }
        return GameFiles.check(data)
    }

    // MARK: Helpers

    /// Explains what to pick instead when the picked folder has no game in it.
    private static func wrongFolderMessage(_ picked: URL) -> String {
        let name = picked.lastPathComponent
        let manager = FileManager.default
        let hasEngine = manager.fileExists(atPath: picked.appendingPathComponent("game.wasm").path)
            || manager.fileExists(atPath: picked.appendingPathComponent("8b0b5899ed/game.wasm").path)
        if name == "b" || name == "8b0b5899ed" || name == "shaders" || hasEngine {
            return AppLanguage.interpolate(AppLanguage.choose("You opened the \"{arg0}\" folder. Go back up one or two levels and pick the folder that has both \"data\" and \"b\" inside, then tap Open there."), [String(describing: name)])
        }
        return AppLanguage.interpolate(AppLanguage.choose("There is no game in \"{arg0}\". Pick the folder that has your game in it (any folder above it works, even On My iPhone itself).\n\nEasiest: move your game folder into Files › On My iPhone › GTA V Port. The app finds it there by itself."), [name])
    }

    /// The name shown for a game folder: the folder holding data/, or data/'s own name.
    private static func displayName(_ data: URL) -> String {
        data.lastPathComponent == "data" ? data.deletingLastPathComponent().lastPathComponent : data.lastPathComponent
    }
    private static func relative(_ url: URL, to base: URL) -> String {
        let full = url.standardizedFileURL.path, root = base.standardizedFileURL.path
        guard full.hasPrefix(root) else { return full }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private static func describeLocation(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeNameKey, .volumeIsInternalKey])
        var parts: [String] = []
        if values?.isUbiquitousItem == true { parts.append("iCloud") }
        if let volume = values?.volumeName { parts.append("volume \(volume)") }
        if values?.volumeIsInternal == false { parts.append("external drive") }
        if url.path.contains("/File Provider Storage/") || url.path.contains("/Containers/Shared/AppGroup/") { parts.append("On My iPhone") }
        else if url.path.contains("/Library/CloudStorage/") || url.path.contains("FileProvider") { parts.append("cloud or app provider") }
        return parts.isEmpty ? "location unknown" : parts.joined(separator: ", ")
    }
}
