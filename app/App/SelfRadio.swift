import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// Opens one of the app's own folders: in the Files app on iPhone, in Finder on Mac (where shareddocuments:
/// opens nothing).
func showInFiles(_ folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #if targetEnvironment(macCatalyst)
    UIApplication.shared.open(folder)
    #else
    if let url = URL(string: "shareddocuments://" + folder.path) { UIApplication.shared.open(url) }
    #endif
}

/// Self Radio (GTA-5): the player's own songs as a station in the game's radio wheel, as on PC. Songs live in
/// Files › GTA V Port › Self Radio; the game reads them through the host (Source/NativeUserMusic.c), which decodes
/// them with iOS's own decoders (MP3, AAC/M4A, ALAC, WAV, AIFF, FLAC). The game shows the station once it has
/// at least three songs.
enum SelfRadio {
    static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Self Radio") }
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "wav", "aif", "aiff", "aifc", "caf", "flac"]
    /// The game lists Self Radio only with more than two songs (audRadioStation::HasUserTracks).
    static let minimumSongs = 3

    struct Song { let url: URL; let title: String; let artist: String; let seconds: Double }

    /// Song files in the folder (any depth), sorted by name.
    static func files() -> [URL] {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Title, artist and length from the file's own tags (the file name when it has none).
    static func song(_ url: URL) -> Song {
        let asset = AVURLAsset(url: url)
        var title = "", artist = ""
        for item in asset.commonMetadata {
            if item.commonKey == .commonKeyTitle, let value = item.stringValue { title = value }
            if item.commonKey == .commonKeyArtist, let value = item.stringValue { artist = value }
        }
        if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
        let seconds = CMTimeGetSeconds(asset.duration)
        return Song(url: url, title: title, artist: artist, seconds: seconds.isFinite ? seconds : 0)
    }

    /// Copies picked files into the folder; a name already there gets a number. Returns how many were added.
    @discardableResult
    static func add(_ urls: [URL]) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var added = 0
        for url in urls where extensions.contains(url.pathExtension.lowercased()) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            var target = folder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: target.path) { target = folder.appendingPathComponent("\(stem) \(n).\(ext)"); n += 1 }
            if (try? fm.copyItem(at: url, to: target)) != nil { added += 1 }
        }
        return added
    }

    static func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    static func showFolder() { showInFiles(folder) }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Settings › Self Radio: add songs, see them, remove them.
final class SelfRadioViewController: UITableViewController, UIDocumentPickerDelegate {
    private var songs: [SelfRadio.Song] = []
    private var loading = false

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = AppLanguage.choose("Self Radio")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        try? FileManager.default.createDirectory(at: SelfRadio.folder, withIntermediateDirectories: true)
        reload()
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }

    /// Reading the tags takes a moment for many songs, so it runs off the main thread.
    private func reload() {
        loading = true
        tableView.reloadData()
        DispatchQueue.global(qos: .userInitiated).async {
            let list = SelfRadio.files().map(SelfRadio.song)
            DispatchQueue.main.async { self.songs = list; self.loading = false; self.tableView.reloadData() }
        }
    }

    static let orders = [(2, AppLanguage.choose("Shuffle")), (1, AppLanguage.choose("In order")), (0, AppLanguage.choose("Like a radio station"))]
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 3 : max(songs.count, 1) }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard section == 1, !songs.isEmpty else { return section == 1 ? AppLanguage.choose("Songs") : nil }
        let total = songs.reduce(0) { $0 + $1.seconds }
        return AppLanguage.interpolate(AppLanguage.choose("{arg0} songs · {arg1}"), [String(songs.count), SelfRadio.duration(total)])
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return AppLanguage.choose("Pick songs from Files (MP3, M4A, AAC, WAV, AIFF or FLAC), or copy them into Files › On My iPhone › GTA V Port › Self Radio. Songs from Apple Music or Spotify can't be added: they're protected.")
                + " " + AppLanguage.choose("Shuffle and In order start each song from the beginning, and Next song skips one. Like a radio station joins songs midway, as on a real station.")
        }
        var text = AppLanguage.choose("In a car, Self Radio is the smiley next to Los Santos Rock Radio in the radio wheel; the game calls it User Music FM. Songs added or removed while you play reach the station the next time the game starts.")
        if !loading, songs.count < SelfRadio.minimumSongs {
            text = AppLanguage.interpolate(AppLanguage.choose("The game shows Self Radio once there are at least {arg0} songs."), [String(SelfRadio.minimumSongs)]) + " " + text
        }
        return text
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.selectionStyle = .default
        cell.accessoryView = nil
        if indexPath.section == 0 && indexPath.row == 2 {
            // Play order: the game's Self Radio Mode, applied when the game is running.
            content.text = AppLanguage.choose("Play order")
            content.image = UIImage(systemName: "shuffle")
            let mode = GameSettings.shared.selfRadioMode
            let button = UIButton(type: .system)
            button.setTitle((Self.orders.first { $0.0 == mode }?.1 ?? "") + " ▾", for: .normal)
            button.showsMenuAsPrimaryAction = true
            button.accessibilityLabel = AppLanguage.choose("Play order")
            button.menu = UIMenu(children: Self.orders.map { order in
                UIAction(title: order.1, state: order.0 == mode ? .on : .off) { [weak self] _ in
                    GameSettings.shared.selfRadioMode = order.0
                    PGSetSelfRadioMode(Int32(order.0))
                    self?.tableView.reloadData()
                }
            })
            button.sizeToFit()
            cell.accessoryView = button
            cell.selectionStyle = .none
        } else if indexPath.section == 0 {
            content.text = [AppLanguage.choose("Add songs…"), AppLanguage.choose("Show the Self Radio folder in Files")][indexPath.row]
            content.image = UIImage(systemName: ["plus.circle", "folder"][indexPath.row])
            content.textProperties.color = view.tintColor ?? .systemBlue
        } else if songs.isEmpty {
            content.text = loading ? AppLanguage.choose("Reading your songs…") : AppLanguage.choose("No songs yet")
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        } else {
            let song = songs[indexPath.row]
            content.text = song.title
            content.secondaryText = (song.artist.isEmpty ? "" : song.artist + " · ") + SelfRadio.duration(song.seconds)
            content.image = UIImage(systemName: "music.note")
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0, indexPath.row < 2 else { return }
        if indexPath.row == 0 {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
            picker.delegate = self
            picker.allowsMultipleSelection = true
            present(picker, animated: true)
        } else {
            SelfRadio.showFolder()
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1, !songs.isEmpty else { return nil }
        let song = songs[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: AppLanguage.choose("Remove")) { [weak self] _, _, done in
            try? SelfRadio.remove(song.url)
            self?.reload(); done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let added = SelfRadio.add(urls)
        NSLog("Self Radio: added %d of %d picked songs", added, urls.count)
        reload()
    }
}
