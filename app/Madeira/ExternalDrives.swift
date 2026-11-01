import SwiftUI
import UniformTypeIdentifiers
import BackgroundTasks

/// Folders the user picked outside the app, usually on a USB or SSD drive.
///
/// iOS only lets the app reach them through the folder picker. The picked URL
/// is kept as a bookmark in Documents/madeira-external.json, and on every launch
/// (before the wineserver starts) each one is opened again and linked into the
/// prefix twice: as drive_c/External/<name>, so the library and the executable
/// browser work unchanged, and as dosdevices/<letter>:, so Windows lists it as a
/// drive. A folder whose drive is not plugged in is left out until next time.
struct ExternalFolder: Codable, Identifiable {
    var id = UUID()
    var name: String
    var letter: String
    var bookmark: Data
    /// Madeira's Steam downloads go to <folder>/SteamLibrary on this drive.
    var steamInstalls: Bool? = nil
    var libraryID: String? = nil
}

final class ExternalDrives: ObservableObject {
    static let shared = ExternalDrives()
    @Published private(set) var folders: [ExternalFolder] = []
    /// Folders opened this launch, by id, with the path they resolved to.
    @Published private(set) var mounted: [UUID: URL] = [:]

    private static var store: URL { LibraryModel.documents.appendingPathComponent("madeira-external.json") }
    static var linkRoot: URL { MadeiraDock.drive.appendingPathComponent("External", isDirectory: true) }
    private static var dosdevices: URL { MadeiraDock.prefix.appendingPathComponent("dosdevices", isDirectory: true) }

    /// Steam libraries (drive_c-relative steamapps folders) on the drives opened
    /// this launch, and the one Steam downloads go to. Read from any thread
    /// (MadeiraDock.games runs off the main thread), so kept behind a lock.
    private static let lock = NSLock()
    private static var libraries: [String] = []
    private static var installTarget: String?
    private static var installMissing: String?
    private static var opened: [String: (root: URL, identity: String?)] = [:]
    private var loadFailure: Error?
    static var steamLibraries: [String] { lock.lock(); defer { lock.unlock() }; return libraries }
    /// The library Madeira's Steam downloads go to, or nil for drive_c's own.
    static var steamInstallLibrary: String? { lock.lock(); defer { lock.unlock() }; return installTarget }
    /// The name of the drive Steam downloads go to when it is not connected.
    static var steamInstallMissing: String? { lock.lock(); defer { lock.unlock() }; return installMissing }
    /// Where Steam libraries are looked for inside a picked folder.
    private static let libraryFolders = ["", "SteamLibrary", "Steam", "Program Files (x86)/Steam", "Program Files/Steam"]

    private init() {
        do {
            let data = try Data(contentsOf: Self.store)
            guard data.count <= 32 << 20 else { throw ExternalStorageError.invalidRecord }
            let list = try JSONDecoder().decode([ExternalFolder].self, from: data)
            try Self.validate(list)
            folders = list
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { }
        catch { loadFailure = error; LogStore.shared.log("[external] saved registrations could not be read; files kept") }
    }

    private static func validate(_ list: [ExternalFolder]) throws {
        guard list.count <= 22, Set(list.map(\.id)).count == list.count,
              list.filter({ $0.steamInstalls == true }).count <= 1,
              Set(list.map { $0.name.lowercased() }).count == list.count,
              Set(list.map(\.letter)).count == list.count else { throw ExternalStorageError.invalidRecord }
        for folder in list {
            guard try ExternalStoragePath.components(folder.name) == [folder.name],
                  folder.letter.count == 1, "defghijklmnopqrstuvwxy".contains(folder.letter),
                  !folder.bookmark.isEmpty, folder.bookmark.count <= 1 << 20,
                  folder.libraryID == nil || UUID(uuidString: folder.libraryID!) != nil else { throw ExternalStorageError.invalidRecord }
        }
    }

    private func save(_ list: [ExternalFolder]) throws {
        if let loadFailure { throw loadFailure }
        try Self.validate(list)
        try JSONEncoder().encode(list).write(to: Self.store, options: .atomic)
        folders = list
    }

    private func publishOpened() {
        let next = Dictionary(uniqueKeysWithValues: folders.compactMap { folder in
            mounted[folder.id].map { (folder.name, (root: $0, identity: folder.libraryID)) }
        })
        Self.lock.lock(); Self.opened = next; Self.lock.unlock()
    }

    static func externalRoot(for relative: String) throws -> (root: URL, identity: String?)? {
        guard let name = driveName(library: relative) else { return nil }
        lock.lock(); let folder = opened[name]; lock.unlock()
        guard let folder else { throw ExternalStorageError.unavailable }
        try validateRoot(folder.root, identity: folder.identity)
        return folder
    }

    private static func validateRoot(_ root: URL, identity: String?) throws {
        guard try root.checkResourceIsReachable(),
              try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ExternalStorageError.unavailable }
        if let identity { try ExternalStorageIdentity.verify(identity, root: root) }
    }

    static func nativeURL(_ relative: String, write: Bool = false) throws -> URL {
        _ = try ExternalStoragePath.components(relative)
        guard let external = try externalRoot(for: relative) else { return MadeiraDock.drive.appendingPathComponent(relative) }
        if write, try external.root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true {
            throw CocoaError(.fileWriteVolumeReadOnly)
        }
        let parts = try ExternalStoragePath.components(relative)
        return parts.count == 2 ? external.root : try ExternalStoragePath.native(parts.dropFirst(2).joined(separator: "/"), root: external.root)
    }

    /// Opens every saved folder and refreshes the links. Safe to call again; it
    /// must run before the wineserver starts for Windows to list the drives.
    @MainActor func mountAll() {
        guard loadFailure == nil, wine_process_is_running() == 0 else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.linkRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.dosdevices, withIntermediateDirectories: true)
        var next = folders
        for i in folders.indices {
            let folder = folders[i]
            if let root = mounted[folder.id], (try? Self.validateRoot(root, identity: folder.libraryID)) != nil { continue }
            mounted.removeValue(forKey: folder.id)?.stopAccessingSecurityScopedResource()
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw ExternalStorageError.unavailable }
                do {
                    try Self.validateRoot(url, identity: folder.libraryID)
                    try link(folder, to: url, owned: true)
                    if stale { next[i].bookmark = try url.bookmarkData() }
                    mounted[folder.id] = url
                } catch { url.stopAccessingSecurityScopedResource(); throw error }
            } catch {
                LogStore.shared.log("[external] \(folder.name) unavailable: \(error.localizedDescription)")
                unlink(folder)
            }
        }
        do { try save(next) } catch { LogStore.shared.log("[external] bookmark refresh could not be saved") }
        publishOpened()
        refreshSteam()
        SteamOwnedLibrary.shared.externalStorageReconnected()
    }

    /// Finds the Steam libraries on the opened drives, makes the chosen download
    /// folder, and lists them all in the Steam client's libraryfolders.vdf so
    /// Valve's client (started by Madeira Dock) can start their games.
    func refreshSteam() {
        let fm = FileManager.default
        var found: [String] = [], target: String?, missing: String?
        for folder in folders {
            if folder.steamInstalls == true { target = "External/\(folder.name)/SteamLibrary/steamapps" }
            guard mounted[folder.id] != nil, Self.isConnected(folder.name) else {
                if folder.steamInstalls == true { missing = folder.name }
                continue
            }
            if folder.steamInstalls == true {
                do {
                    let common = try Self.nativeURL("External/\(folder.name)/SteamLibrary/steamapps/common", write: true)
                    try fm.createDirectory(at: common, withIntermediateDirectories: true)
                } catch { missing = folder.name }
            }
            for sub in Self.libraryFolders {
                let apps = sub.isEmpty ? "steamapps" : sub + "/steamapps"
                var isDir: ObjCBool = false
                if let appsURL = try? Self.nativeURL("External/\(folder.name)/" + apps),
                   fm.fileExists(atPath: appsURL.path, isDirectory: &isDir), isDir.boolValue {
                    found.append("External/\(folder.name)/" + apps)
                }
            }
        }
        // What each drive library holds, to tell a moved game's state from the log.
        for library in found {
            let apps = MadeiraDock.drive.appendingPathComponent(library)
            let records = ((try? fm.contentsOfDirectory(atPath: apps.path)) ?? []).filter { $0.hasPrefix("appmanifest_") }
            let folders = (try? fm.contentsOfDirectory(atPath: apps.appendingPathComponent("common").path)) ?? []
            LogStore.shared.log("[external] \(library) records=\(records.count) folders=\(folders.sorted().joined(separator: "|"))")
        }
        Self.lock.lock(); Self.libraries = found; Self.installTarget = target; Self.installMissing = missing; Self.lock.unlock()
        Self.listInSteamClient(found.map { String($0.dropLast("/steamapps".count)) })
        LogStore.shared.log("[external] steam libraries=\(found.count) install=\(target ?? "drive_c")")
    }

    /// Adds `C:\<folder>` entries for the libraries Valve's client does not list yet.
    private static func listInSteamClient(_ relative: [String]) {
        guard !relative.isEmpty else { return }
        let vdf = MadeiraDock.drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/steamapps/libraryfolders.vdf")
        do {
            let existing: Data?
            do { existing = try Data(contentsOf: vdf) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { existing = nil }
            let paths = [SteamRuntimeFiles.relativeRoot] + relative
            let data = try ExternalSteamLibraries.add(paths: paths, to: existing)
            guard data != existing else { return }
            try FileManager.default.createDirectory(at: vdf.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: vdf, options: .atomic)
        } catch { LogStore.shared.log("[external] Steam library metadata was kept: \(error.localizedDescription)") }
    }

    /// "External/<name>/..." -> "<name>", or nil for drive_c.
    static func driveName(library: String) -> String? {
        let parts = library.split(separator: "/", maxSplits: 2).map(String.init)
        return parts.count >= 2 && parts[0] == "External" ? parts[1] : nil
    }
    static func isConnected(_ name: String) -> Bool {
        (try? externalRoot(for: "External/" + name)) != nil
    }
    /// Places a Steam game can be installed or moved to: this device's own
    /// library and <folder>/SteamLibrary on each connected drive.
    var steamTargets: [(name: String, library: String)] {
        [("This iPhone", SteamInstallPaths.libraryRelative)] + folders.filter { mounted[$0.id] != nil }
            .map { ($0.name, "External/\($0.name)/SteamLibrary/steamapps") }
    }
    /// Places a non-Steam game can be moved to: drive_c/Games, or <folder>/Games.
    var gameTargets: [(name: String, root: String)] {
        [("This iPhone", "Games")] + folders.filter { mounted[$0.id] != nil }.map { ($0.name, "External/\($0.name)/Games") }
    }

    /// Sends Madeira's Steam downloads to this folder (nil: back to drive_c).
    func setSteamInstalls(_ id: UUID?) {
        var next = folders
        for i in next.indices { next[i].steamInstalls = next[i].id == id ? true : nil }
        do { try save(next); refreshSteam() }
        catch { LogStore.shared.log("[external] install target was not changed: \(error.localizedDescription)") }
    }

    /// Adds a folder picked with the folder picker and links it right away.
    func add(_ url: URL) throws {
        if let loadFailure { throw loadFailure }
        guard wine_process_is_running() == 0 else { throw LibraryError.message("Close the running game before adding a drive.") }
        guard url.startAccessingSecurityScopedResource() else { throw LibraryError.message("Madeira could not open that folder.") }
        let bookmark: Data
        do { bookmark = try url.bookmarkData() } catch { url.stopAccessingSecurityScopedResource(); throw error }
        let used = Set(folders.map(\.letter))
        guard let letter = "defghijklmnopqrstuvwxy".map(String.init).first(where: {
            !used.contains($0) && (try? FileManager.default.attributesOfItem(atPath: Self.dosdevices.appendingPathComponent($0 + ":").path)) == nil
        }) else {
            url.stopAccessingSecurityScopedResource()
            throw LibraryError.message("No free drive letters.")
        }
        var name = url.lastPathComponent.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
        if name.isEmpty { name = "Drive" }
        let base = name; var n = 2
        while folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "\(base) \(n)"; n += 1 }
        var folder = ExternalFolder(name: name, letter: letter, bookmark: bookmark)
        do {
            guard !mounted.values.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) else {
                throw LibraryError.message("That folder is already registered.")
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsReadOnlyKey])
            guard values.isDirectory == true, values.isUbiquitousItem != true, values.volumeIsLocal == true else {
                throw LibraryError.message("Choose a folder on a local USB or SSD drive.")
            }
            if values.volumeIsReadOnly != true { folder.libraryID = try ExternalStorageIdentity.register(root: url) }
            try Self.validate(folders + [folder])
            try link(folder, to: url, owned: false)
            do { try save(folders + [folder]) } catch { unlink(folder); throw error }
            mounted[folder.id] = url
        } catch { url.stopAccessingSecurityScopedResource(); throw error }
        publishOpened()
        refreshSteam()
        LogStore.shared.log("[external] added \(letter.uppercased()): \(name) -> \(url.path)")
    }

    /// Forgets a folder. Its files stay on the drive; the library entries that
    /// start programs on it (and its Steam games' entries) are removed.
    @MainActor func remove(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        guard wine_process_is_running() == 0, GameMover.shared.moving == nil,
              !SteamOwnedLibrary.shared.hasStorageWork else {
            LogStore.shared.log("[external] drive kept while a game, download or cloud operation uses storage")
            return
        }
        do { try save(folders.filter { $0.id != id }) }
        catch { LogStore.shared.log("[external] drive registration could not be removed"); return }
        let prefix = "External/\(folder.name)/"
        let library = LibraryModel.shared
        for entry in library.entries where entry.relativePath.hasPrefix(prefix) {
            if let appID = entry.steamAppID { library.removeSteam(appID: appID) } else { library.remove(entry.id) }
        }
        unlink(folder)
        mounted.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        publishOpened()
        refreshSteam()
        Task { @MainActor in SteamGamesModel.shared.refresh() }
        LogStore.shared.log("[external] removed \(folder.name)")
    }

    private func link(_ folder: ExternalFolder, to url: URL, owned: Bool) throws {
        let fm = FileManager.default
        for container in [Self.linkRoot, Self.dosdevices] {
            try fm.createDirectory(at: container, withIntermediateDirectories: true)
            guard try fm.attributesOfItem(atPath: container.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ExternalStorageError.mappingConflict
            }
        }
        let links = [Self.linkRoot.appendingPathComponent(folder.name), Self.dosdevices.appendingPathComponent(folder.letter + ":")]
        for path in links { try ExternalStorageMapping.validate(path, root: url, owned: owned) }
        for path in links { try ExternalStorageMapping.replace(path, root: url, owned: owned) }
    }

    private func unlink(_ folder: ExternalFolder) {
        // Only links are removed, never what they point at.
        for path in [Self.linkRoot.appendingPathComponent(folder.name).path,
                     Self.dosdevices.appendingPathComponent(folder.letter + ":").path] {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    /// The real roots of the folders opened this launch.
    var roots: [(name: String, path: String)] {
        folders.compactMap { f in mounted[f.id].map { (f.name, $0.resolvingSymlinksInPath().path) } }
    }
}

/// Games already on an external folder: the programs that look like a game's
/// own executable, a few folders deep. Steam libraries are left to Steam.
enum ExternalGameScan {
    private static let skipNames = ["unins", "setup", "install", "redist", "vcredist", "vc_redist", "dxsetup", "directx",
                                    "dotnet", "crash", "report", "update", "patch", "launcherhelper", "helper", "cef",
                                    "touchup", "easyanticheat", "battleye", "ue4prereq", "prereq", "config", "settings"]
    private static let skipFolders: Set<String> = ["steamapps", "_commonredist", "commonredist", "redist",
                                                   "redistributables", "directx", "dotnet", "vcredist", "__installer", "windows", "system32",
                                                   "$recycle.bin", "system volume information", "engine", "node_modules"]

    /// Every subfolder is searched, within a budget of folders and time so a
    /// huge drive still returns.
    static func scan(_ root: URL) -> [URL] {
        var found: [URL] = [], budget = Budget()
        walk(root, depth: 40, into: &found, budget: &budget)
        return found
    }

    private struct Budget { var folders = 0; let deadline = Date().addingTimeInterval(20) }

    private static func walk(_ folder: URL, depth: Int, into found: inout [URL], budget: inout Budget) {
        budget.folders += 1
        guard found.count < 1000, budget.folders < 50_000, Date() < budget.deadline, let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { return }
        for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = item.lastPathComponent.lowercased()
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if depth > 0, !skipFolders.contains(name), !item.isSymlink { walk(item, depth: depth - 1, into: &found, budget: &budget) }
            } else if item.pathExtension.lowercased() == "exe", !skipNames.contains(where: { name.hasPrefix($0) || name.contains("_" + $0) || name.contains("-" + $0) }) {
                found.append(item)
            }
        }
    }
}

private extension URL {
    var isSymlink: Bool { (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
}

/// Lists the games found on one external folder and adds the chosen ones.
struct ExternalGamesSheet: View {
    let folder: ExternalFolder
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = LibraryModel.shared
    @State private var found: [URL]?
    @State private var chosen: Set<URL> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let found {
                    if found.isEmpty { Text("No games found. Steam games on this drive show up in the Steam section.").foregroundStyle(.secondary) }
                    ForEach(found, id: \.self) { url in
                        let added = isAdded(url)
                        Button { if chosen.contains(url) { chosen.remove(url) } else { chosen.insert(url) } } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                    Text(String(url.path.dropFirst(root.path.count + 1))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if added { Text("Added").foregroundStyle(.secondary) }
                                else if chosen.contains(url) { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(added)
                    }
                } else {
                    HStack { ProgressView(); Text("Looking for games") }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(folder.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add \(chosen.count)") { add() }.disabled(chosen.isEmpty) }
            }
        }
        .task {
            let root = root
            found = await Task.detached(priority: .userInitiated) { ExternalGameScan.scan(root) }.value
        }
    }

    private func isAdded(_ url: URL) -> Bool {
        guard let relative = LibraryModel.relativeToDrive(url) else { return false }
        return library.entries.contains { $0.relativePath.caseInsensitiveCompare(relative) == .orderedSame }
    }

    private func add() {
        var failed: [String] = []
        for url in chosen.sorted(by: { $0.path < $1.path }) {
            do {
                var entry = try LibraryModel.inspect(url)
                // A program's own name is often generic: use its folder's.
                let parent = url.deletingLastPathComponent()
                if parent.path != root.path { entry.title = parent.lastPathComponent }
                library.save(entry)
            } catch { failed.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        LogStore.shared.log("[external] added games=\(chosen.count - failed.count) from \(folder.name)")
        if failed.isEmpty { dismiss() } else { error = failed.joined(separator: "\n"); chosen = [] }
    }
}

/// Settings › External drives.
struct ExternalDrivesSection: View {
    @ObservedObject private var drives = ExternalDrives.shared
    @State private var error: String?
    @State private var dropTarget = false
    @State private var scanning: ExternalFolder?
    @State private var removing: ExternalFolder?
    private var bundleID: String { Bundle.main.bundleIdentifier ?? "different" }

    var body: some View {
        Section {
            ForEach(drives.folders) { folder in
                HStack {
                    Text(folder.letter.uppercased() + ":").font(.body.monospaced())
                    Text(folder.name)
                    Spacer()
                    Text(drives.mounted[folder.id] == nil ? "Not connected" : "Connected").foregroundStyle(.secondary)
                }
                .swipeActions { Button("Remove", role: .destructive) { removing = folder } }
                if drives.mounted[folder.id] != nil {
                    Button("Find games on \(folder.name)") { scanning = folder }
                }
            }
            Button("Add drive or folder") { ExternalFolderPicker.shared.start(added) }
                // Anything is let in so the log shows every drop; dropped() picks the folder out.
                .onDrop(of: [.folder, .directory, .item], isTargeted: $dropTarget) { providers in
                    guard let provider = providers.first else { return false }
                    ExternalFolderPicker.shared.dropped(provider, done: added, failed: { error = $0 })
                    return true
                }
            if !drives.folders.isEmpty {
                Picker("Install Steam games on", selection: Binding(
                    get: { drives.folders.first { $0.steamInstalls == true }?.id },
                    set: { drives.setSteamInstalls($0) })) {
                    Text("This iPhone").tag(UUID?.none)
                    ForEach(drives.folders) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let appID = FolderPickerSigning.signedAppID {
                // Builds 47 to 60: with these two different, iOS refuses every in-place
                // folder hand-off (picker, drag and drop, Shortcuts), with no error.
                Label {
                    // One literal, so the catalog translates it (%@ for each interpolation).
                    Text("This copy of Madeira is signed with the App ID \(appID), but its bundle ID is \(bundleID). iOS only lets an app open folders on a drive when the two match. Sign Madeira again with the bundle ID set to \(appID) (in your signer, usually a Bundle ID or \"use profile's App ID\" option), then add the drive here.")
                        .font(.footnote)
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        } header: { Text("External drives") } footer: {
            Text("Pick a folder on a USB or SSD drive, or a whole drive that already has games on it. Windows sees it as a drive letter and as C:\\External\\<name>. Find games adds the games on it to the library; Steam libraries on it (steamapps or SteamLibrary) show up in the Steam section. Install Steam games on picks where new Steam downloads go by default (each install can still pick another place); on a drive they go into <name>\\SteamLibrary. Unplugging the drive while a game runs will close it. Restart Madeira after adding a folder for Windows to list the new drive. If the picker's Open button does nothing, Madeira's bundle ID does not match the App ID it is signed with; the note above says how to fix that.")
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { folder in
            Button("Remove", role: .destructive) { drives.remove(folder.id) }
        } message: { _ in
            Text("Madeira forgets this drive and removes its games from the library. The files on the drive are kept.")
        }
        .sheet(item: $scanning) { folder in
            if let root = drives.mounted[folder.id] { ExternalGamesSheet(folder: folder, root: root.resolvingSymlinksInPath()) }
        }
        .onAppear { ExternalFolderPicker.shared.installWindowDrop() }
        .onChange(of: dropTarget) { _, over in if over { LogStore.shared.log("[external] something is being dragged over Add drive or folder") } }
    }

    private func added(_ url: URL) {
        do {
            try drives.add(url); error = nil
            SteamGamesModel.shared.refresh()
            // Offer the games already on it.
            scanning = drives.folders.last
        } catch { self.error = error.localizedDescription }
    }
}

/// Settings › External drives' folder picker. Madeira presents it itself, not
/// through SwiftUI's fileImporter, so FolderPickerSigning can fix the picker up
/// before it is shown and the log can tell Cancel apart from a pick.
@MainActor final class ExternalFolderPicker: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate,
                                          UIDropInteractionDelegate {
    static let shared = ExternalFolderPicker()
    private var done: (@MainActor (URL) -> Void)?

    /// Add drive or folder. A copy signed with an App ID other than its bundle ID
    /// cannot take a folder from the picker on iOS 27.2 (builds 47 to 58), so it
    /// gets the drop screen, which can still open the picker.
    func start(_ done: @escaping @MainActor (URL) -> Void) {
        guard FolderPickerSigning.signedAppID != nil else { present(done); return }
        guard let top = Self.topController() else {
            LogStore.shared.log("[external] drop screen: no window to show it from")
            return
        }
        let screen = FolderDropController(done: done, pick: { [weak self] in self?.present(done) })
        LogStore.shared.log("[external] drop screen shown (signed App ID differs from the bundle ID)")
        top.present(UINavigationController(rootViewController: screen), animated: true)
    }

    static func topController() -> UIViewController? {
        guard var top = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    func present(_ done: @escaping @MainActor (URL) -> Void) {
        guard var top = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            LogStore.shared.log("[external] folder picker: no window to show it from")
            return
        }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        // Before the picker exists: iOS fills in its configuration when it is created.
        FolderPickerSigning.willPick()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        FolderPickerSigning.prepare(picker)
        self.done = done
        top.present(picker, animated: true) {
            picker.presentationController?.delegate = self
            FolderPickerSigning.report(picker, stage: "shown")
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let staging = exporting {
            exporting = nil
            exported(urls, staging: staging)
            return
        }
        FolderPickerSigning.didPick(.picked)
        if let url = urls.first { done?(url) }
        done = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if exporting != nil { LogStore.shared.log("[external] anchor folder: cancelled") }
        else { FolderPickerSigning.didPick(.cancelled) }
        exporting = nil
        done = nil
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if exporting != nil { LogStore.shared.log("[external] anchor folder: swiped away") }
        else { FolderPickerSigning.didPick(.swipedAway) }
        exporting = nil
        done = nil
    }

    /// The folder being moved onto a drive by the export picker, while it is open.
    private var exporting: URL?
    static let anchorName = "Madeira Games"

    /// A way in that does not open anything: the picker's export (move) mode writes a
    /// new, empty "Madeira Games" folder onto the drive and hands back where it went.
    /// Opening is what iOS refuses to a copy signed with another App ID (builds 47 to
    /// 60); moving goes the other way, so it may still hand over the new folder.
    /// Game folders moved into it in the Files app are then inside a folder Madeira has.
    func presentAnchor(_ done: @escaping @MainActor (URL) -> Void) {
        guard let top = Self.topController() else { return }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("anchor-" + UUID().uuidString, isDirectory: true)
        let folder = staging.appendingPathComponent(Self.anchorName, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Madeira can reach everything in this folder. Move game folders into it in the Files app.\n".utf8)
                .write(to: folder.appendingPathComponent("About this folder.txt"))
        } catch {
            LogStore.shared.log("[external] anchor folder: could not make it: \(error.localizedDescription)")
            return
        }
        let picker = UIDocumentPickerViewController(forExporting: [folder], asCopy: false)
        picker.delegate = self
        self.done = done
        exporting = staging
        LogStore.shared.log("[external] anchor folder: export picker shown")
        top.present(picker, animated: true) { picker.presentationController?.delegate = self }
    }

    private func exported(_ urls: [URL], staging: URL) {
        let done = self.done
        self.done = nil
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let url = urls.first else {
            LogStore.shared.log("[external] anchor folder: picker returned no URL")
            Self.tell("iOS did not say where the folder went.")
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let listed = (try? FileManager.default.contentsOfDirectory(atPath: url.path)).map { "\($0.count)" } ?? "no"
        LogStore.shared.log("[external] anchor folder: moved, urls=\(urls.count) scoped=\(scoped ? 1 : 0)"
            + " copy=\(Self.isOurCopy(url) ? 1 : 0) listable=\(listed) name=\(url.lastPathComponent == Self.anchorName ? 1 : 0)")
        guard !Self.isOurCopy(url) else { Self.tell("iOS kept the folder inside Madeira instead of moving it."); return }
        done?(url)
    }

    /// Edit › Paste: a folder copied in the Files app (press and hold, Copy). The
    /// pasteboard hands items over on its own path, separate from drag and drop.
    func pasteFolder(done: @escaping @MainActor (URL) -> Void, failed: @escaping @MainActor (String) -> Void) {
        let providers = UIPasteboard.general.itemProviders
        LogStore.shared.log("[external] paste: items=\(providers.count)")
        guard let provider = providers.first else {
            failed("Nothing is copied. In the Files app, press and hold the folder, tap Copy, then come back and tap Paste.")
            return
        }
        dropped(provider, done: done, failed: failed)
    }

    /// A second drop target on the whole window, under every SwiftUI view: Form rows
    /// may never hand a drop to SwiftUI's onDrop, and build 50's log showed a folder
    /// dragged onto Add drive or folder never reaching it. Installed once, when the
    /// External drives settings first show; a folder dropped anywhere in Madeira is
    /// then added as a drive.
    private var windowDrop: UIDropInteraction?

    func installWindowDrop() {
        guard windowDrop == nil, let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let interaction = UIDropInteraction(delegate: self)
        window.addInteraction(interaction)
        windowDrop = interaction
        LogStore.shared.log("[external] window drop target installed")
    }

    private static let folderTypes = [UTType.folder.identifier, UTType.directory.identifier]

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        let types = session.items.flatMap { $0.itemProvider.registeredTypeIdentifiers }
        LogStore.shared.log("[external] drag entered the window, types: \(types.joined(separator: ","))")
        return session.hasItemsConforming(toTypeIdentifiers: Self.folderTypes)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: session.hasItemsConforming(toTypeIdentifiers: Self.folderTypes) ? .copy : .forbidden)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        LogStore.shared.log("[external] drag over the window ended")
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        LogStore.shared.log("[external] folder dropped on the window")
        guard let provider = session.items.first?.itemProvider else { return }
        dropped(provider, done: { url in
            do {
                try ExternalDrives.shared.add(url)
                SteamGamesModel.shared.refresh()
            } catch { Self.tell(error.localizedDescription) }
        }, failed: { Self.tell($0) })
    }

    /// The drop has no settings row to show an error under, so it gets an alert.
    private static func tell(_ message: String) {
        LogStore.shared.log("[external] window drop failed: \(message)")
        guard var top = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let alert = UIAlertController(title: "External drives", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }

    /// A folder dragged in from the Files app. Drag and drop hands the folder over
    /// on a different path than the picker's Open button, so it is a second way in
    /// when the picker refuses the folder.
    func dropped(_ provider: NSItemProvider, done: @escaping @MainActor (URL) -> Void,
                 failed: @escaping @MainActor (String) -> Void) {
        let types = provider.registeredTypeIdentifiers
        LogStore.shared.log("[external] folder dropped, types: \(types.joined(separator: ","))")
        // Files offers a folder as public.folder; anything that is a folder or directory will do.
        guard let type = types.first(where: { UTType($0).map { $0.conforms(to: .folder) || $0.conforms(to: .directory) } ?? false }) else {
            // Diagnostic: whether a single file still opens in place on this signing.
            if let first = types.first {
                _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: first) { url, inPlace, error in
                    let scoped = url?.startAccessingSecurityScopedResource() ?? false
                    if scoped { url?.stopAccessingSecurityScopedResource() }
                    let text = "[external] dropped a file (\(first)): url=\(url == nil ? 0 : 1) in-place=\(inPlace ? 1 : 0)"
                        + " scoped=\(scoped ? 1 : 0)" + (error.map { " error=\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "")
                    Task { @MainActor in LogStore.shared.log(text) }
                }
            }
            failed("That is not a folder. Drag the folder itself, not a file inside it.")
            return
        }
        let inPlaceOffered = provider.hasRepresentationConforming(toTypeIdentifier: type, fileOptions: .openInPlace)
        LogStore.shared.log("[external] dropped \(type): open-in-place offered=\(inPlaceOffered ? 1 : 0)"
            + " name=\(provider.suggestedName == nil ? 0 : 1)")
        _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, inPlace, error in
            // Held across the hop to the main thread; add() takes its own access and keeps it.
            let scoped = url?.startAccessingSecurityScopedResource() ?? false
            Task { @MainActor in
                defer { if scoped { url?.stopAccessingSecurityScopedResource() } }
                LogStore.shared.log("[external] dropped folder: url=\(url == nil ? 0 : 1) in-place=\(inPlace ? 1 : 0)"
                    + " scoped=\(scoped ? 1 : 0)" + (error.map { " error=\(Self.describe($0))" } ?? ""))
                if let url, inPlace { done(url); return }
                // Build 58: Files gave neither a URL nor an error here, for a drive and for
                // a Downloads folder alike. The older item API hands file-provider items
                // over as a URL of their own, so it is tried next.
                self.loadItem(provider, type: type, done: done, failed: failed)
            }
        }
    }

    private func loadItem(_ provider: NSItemProvider, type: String, done: @escaping @MainActor (URL) -> Void,
                          failed: @escaping @MainActor (String) -> Void) {
        provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
            let url = item as? URL
            let scoped = url?.startAccessingSecurityScopedResource() ?? false
            let kind = item.map { String(describing: Swift.type(of: $0)) } ?? "nil"
            Task { @MainActor in
                defer { if scoped { url?.stopAccessingSecurityScopedResource() } }
                LogStore.shared.log("[external] dropped folder by item: item=\(kind) url=\(url == nil ? 0 : 1)"
                    + " scoped=\(scoped ? 1 : 0)" + (url.map { " copy=\(Self.isOurCopy($0) ? 1 : 0)" } ?? "")
                    + (error.map { " error=\(Self.describe($0))" } ?? ""))
                // A copy would fill this device and is not the drive: only the folder itself will do.
                if let url, !Self.isOurCopy(url) { done(url); return }
                if url != nil { failed("Files handed over a copy instead of the folder itself."); return }
                self.loadURLObject(provider, done: done, failed: failed,
                                   fallback: error.map { Self.describe($0) } ?? "Files did not hand Madeira the folder.")
            }
        }
    }

    /// Last try: the provider coerced to a URL object, which some sources offer even
    /// without a public.file-url type.
    private func loadURLObject(_ provider: NSItemProvider, done: @escaping @MainActor (URL) -> Void,
                               failed: @escaping @MainActor (String) -> Void, fallback: String) {
        let can = provider.canLoadObject(ofClass: NSURL.self)
        LogStore.shared.log("[external] dropped folder: can load as URL=\(can ? 1 : 0)")
        guard can else { failed(fallback); return }
        _ = provider.loadObject(ofClass: NSURL.self) { object, error in
            let url = (object as? NSURL).map { $0 as URL }
            let scoped = url?.startAccessingSecurityScopedResource() ?? false
            Task { @MainActor in
                defer { if scoped { url?.stopAccessingSecurityScopedResource() } }
                LogStore.shared.log("[external] dropped folder as URL: url=\(url == nil ? 0 : 1) scoped=\(scoped ? 1 : 0)"
                    + (url.map { " copy=\(Self.isOurCopy($0) ? 1 : 0)" } ?? "")
                    + (error.map { " error=\(Self.describe($0))" } ?? ""))
                if let url, scoped, !Self.isOurCopy(url) { done(url); return }
                failed(error.map { Self.describe($0) } ?? fallback)
            }
        }
    }

    /// A path inside Madeira's own storage: a copy iOS made for us, not the folder.
    private static func isOurCopy(_ url: URL) -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(home + "/")
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }
}

/// The drop screen: one plain UIKit view and one drop target, so no SwiftUI row
/// takes the drag first. On build 58 a folder dragged over Settings reached the
/// window (canHandle ran 20 times as it crossed the rows) but the drop never
/// happened, and Files threw the folder away.
@MainActor final class FolderDropController: UIViewController, UIDropInteractionDelegate {
    private let done: @MainActor (URL) -> Void
    private let pick: @MainActor () -> Void
    private let box = UIView()
    private let label = UILabel()
    private let hint = "Open the Files app, press and hold the drive or folder, and drag it here.\n\n"
        + "On iPhone: keep holding it, swipe up with another finger to go home, open Madeira, and let go anywhere on this screen."
    private var proposed: UIDropOperation?

    init(done: @escaping @MainActor (URL) -> Void, pick: @escaping @MainActor () -> Void) {
        self.done = done
        self.pick = pick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add drive or folder"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            LogStore.shared.log("[external] drop screen cancelled")
            self?.dismiss(animated: true)
        })
        box.layer.cornerRadius = 20
        box.layer.borderWidth = 2
        box.layer.borderColor = UIColor.systemBlue.cgColor
        box.backgroundColor = .secondarySystemBackground
        let icon = UIImageView(image: UIImage(systemName: "externaldrive.badge.plus"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56)
        label.text = hint
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        let pickerButton = UIButton(configuration: .plain(), primaryAction: UIAction(title: "Use the folder picker instead") { [weak self] _ in
            guard let self else { return }
            let pick = self.pick
            self.dismiss(animated: true) { pick() }
        })
        let pasteButton = UIButton(configuration: .plain(), primaryAction: UIAction(title: "Paste a folder copied in Files") { [weak self] _ in
            guard let self else { return }
            self.show("Opening the folder…", error: false)
            ExternalFolderPicker.shared.pasteFolder(done: { [weak self] url in self?.finish(url) },
                                                    failed: { [weak self] message in self?.fail(message) })
        })
        let anchorButton = UIButton(configuration: .plain(), primaryAction: UIAction(title: "Make a \(ExternalFolderPicker.anchorName) folder on the drive") { [weak self] _ in
            guard let self else { return }
            let done = self.done
            self.dismiss(animated: true) { ExternalFolderPicker.shared.presentAnchor(done) }
        })
        let picker = UIStackView(arrangedSubviews: [pasteButton, anchorButton, pickerButton])
        picker.axis = .vertical
        picker.spacing = 2
        picker.alignment = .center
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        for subview in [box, stack, picker] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            box.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            box.topAnchor.constraint(equalTo: guide.topAnchor, constant: 20),
            box.bottomAnchor.constraint(equalTo: picker.topAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            picker.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            picker.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
        ])
        // On the whole screen, so a drop anywhere on it counts.
        view.addInteraction(UIDropInteraction(delegate: self))
    }

    private func show(_ text: String, error: Bool) {
        label.text = text
        label.textColor = error ? .systemRed : .label
    }

    private func highlight(_ on: Bool) {
        box.backgroundColor = on ? UIColor.systemBlue.withAlphaComponent(0.15) : .secondarySystemBackground
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        let types = session.items.flatMap { $0.itemProvider.registeredTypeIdentifiers }
        LogStore.shared.log("[external] drop screen: drag entered, items=\(session.items.count) types: \(types.joined(separator: ","))")
        // Anything is let in, so a drag that is not a folder is told why instead of flying back.
        return true
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) { highlight(true) }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        let operation: UIDropOperation = session.items.count == 1 ? .copy : .forbidden
        if operation != proposed {
            proposed = operation
            LogStore.shared.log("[external] drop screen: proposing \(operation == .copy ? "copy" : "forbidden")"
                + " local=\(session.localDragSession == nil ? 0 : 1)")
        }
        return UIDropProposal(operation: operation)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        highlight(false)
        LogStore.shared.log("[external] drop screen: drag left the screen")
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        highlight(false)
        proposed = nil
        LogStore.shared.log("[external] drop screen: drag ended")
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        LogStore.shared.log("[external] drop screen: dropped")
        guard let provider = session.items.first?.itemProvider else { return }
        show("Opening the folder…", error: false)
        ExternalFolderPicker.shared.dropped(provider, done: { [weak self] url in self?.finish(url) },
                                            failed: { [weak self] message in self?.fail(message) })
    }

    private func finish(_ url: URL) {
        let done = self.done
        dismiss(animated: true) { done(url) }
    }

    private func fail(_ message: String) {
        LogStore.shared.log("[external] drop screen: \(message)")
        show(message + "\n\n" + hint, error: true)
    }
}

/// The folder picker's Open button does nothing when this copy is signed with a
/// profile whose App ID differs from its bundle ID (KravaSigner and other signers
/// that keep the bundle ID do this): iOS drops the pick without calling back, and
/// only Cancel works. The picker names the app that gets the folder in its
/// DOCConfiguration (hostIdentifier), filled in from the bundle ID, and the folder
/// is only granted to the App ID the process is really signed with.
///
/// Build 47 swapped the value through hostIdentifier's setter and getter only, and
/// Open still did nothing on iOS 27.2. So while Madeira's own folder picker is open
/// this now also rewrites every field of the picker and its configuration that
/// holds the bundle ID, again just before the configuration is encoded for the
/// picker's process, and logs what each field holds and which hooks ran, so one
/// device log shows how far the change got. Nothing changes on a copy whose bundle
/// ID already is its App ID, and the folder is still opened in place, never copied.
///
/// Build 48 showed the App ID reaching the configuration that is sent (hostIdentifier
/// = App ID, encoded once) and Open still doing nothing on iOS 27.2, so the host
/// identity alone is not what iOS checks there. madeira.cfg `external-picker-fix`
/// picks what else to try, without a new build: unset or 1 = all of the above; or a
/// comma list of hooks (only build 47's setter/getter swap), ignore (the picker's
/// "ignore the application entitlement" flag), inprocess (the configuration's
/// _inProcess flag) and nobookmark (_neverCreateBookmarkForOpenInPlace); 0 = off.
enum FolderPickerSigning {
    enum Outcome: String { case picked, cancelled, swipedAway = "swiped away" }

    /// The signed App ID when it differs from the bundle ID, else nil.
    static let signedAppID: String? = {
        guard let signed = signedAppIdentifier() ?? SigningProfile.embedded?.appIdentifier,
              signed != Bundle.main.bundleIdentifier else { return nil }
        return signed
    }()
    private static let bundleID = Bundle.main.bundleIdentifier ?? ""
    /// One object for every write, so the fields that take it keep it alive.
    private static let signedObject: NSString? = signedAppID.map { $0 as NSString }

    private static let lock = NSLock()
    private static var open = false
    /// Extra changes chosen in madeira.cfg (hooks, ignore, inprocess, nobookmark).
    private static var options: Set<String> = []
    private static var installed = false
    /// Hook calls while the picker is open: how many ran, how many swapped a value.
    private static var calls: [String: (ran: Int, swapped: Int)] = [:]

    // MARK: session

    /// Right before the picker is created, so the hooks are in effect when iOS fills it in.
    static func willPick() {
        // Default on. 0: the folder picker is left as iOS builds it, so on a copy signed with a different App ID
        // its Open button does nothing again. Otherwise a comma list of extras: hooks (only build 47's swap), ignore
        // (the picker's ignore-entitlement flag), inprocess (the picker runs inside Madeira), nobookmark (no bookmark
        // for the opened folder). Read each time the picker opens.
        let setting = (MadeiraConfig.get("external-picker-fix") ?? "1").lowercased()
        let words = Set(setting.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
        let picked = words.intersection(["hooks", "ignore", "inprocess", "nobookmark"])
        let chosen = words.isDisjoint(with: ["0", "off", "no", "false"]) ? (picked.isEmpty ? "all" : picked.sorted().joined(separator: ",")) : "off"
        guard let signedAppID else {
            LogStore.shared.log("[external] folder picker: App ID matches the bundle ID, nothing to fix")
            return
        }
        guard chosen != "off" else {
            LogStore.shared.log("[external] folder picker: fix off in madeira.cfg")
            return
        }
        lock.lock()
        if !installed { installed = install(signedAppID) }
        open = true; options = picked; calls = [:]
        lock.unlock()
        LogStore.shared.log("[external] folder picker opened with the signed App ID mode=\(chosen)"
            + " bundle-id-len=\(bundleID.count) app-id-len=\(signedAppID.count)")
    }

    /// The picker answered or went away.
    static func didPick(_ outcome: Outcome) {
        lock.lock()
        guard open else { lock.unlock(); return }
        open = false
        let counts = calls.keys.sorted().map { "\($0)=\(calls[$0]!.ran)/\(calls[$0]!.swapped)" }.joined(separator: " ")
        lock.unlock()
        LogStore.shared.log("[external] folder picker \(outcome.rawValue); hook calls ran/swapped: \(counts.isEmpty ? "none" : counts)")
    }

    private static var active: (on: Bool, options: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        return (open, options)
    }

    private static func count(_ hook: String, swapped: Bool) {
        lock.lock(); defer { lock.unlock() }
        var entry = calls[hook] ?? (0, 0)
        entry.ran += 1
        if swapped { entry.swapped += 1 }
        calls[hook] = entry
    }

    // MARK: fixing up the picker

    /// Just after the picker is created and before it is shown.
    static func prepare(_ picker: NSObject) {
        let (on, options) = active
        guard on else { return }
        report(picker, stage: "created")
        guard !options.contains("hooks") else { return }
        var rewritten = rewrite(picker)
        let configs = configurations(of: picker)
        for config in configs { rewritten += rewrite(config) }
        if options.contains("ignore") { setFlag(picker, name: "_ignoreApplicationEntitlementForImport") }
        for config in configs {
            if options.contains("inprocess") { setFlag(config, name: "_inProcess") }
            if options.contains("nobookmark") { setFlag(config, name: "_neverCreateBookmarkForOpenInPlace") }
        }
        LogStore.shared.log("[external] folder picker fields rewritten: \(rewritten.isEmpty ? "none" : rewritten.joined(separator: ","))")
        report(picker, stage: "prepared")
    }

    /// Logs what the identity fields of the picker and its configuration hold.
    static func report(_ picker: NSObject, stage: String) {
        guard active.on || stage == "shown" else { return }
        var parts = ["picker{\(describe(picker))}"]
        for config in configurations(of: picker) { parts.append("\(type(of: config)){\(describe(config))}") }
        LogStore.shared.log("[external] folder picker \(stage): " + parts.joined(separator: " "))
    }

    /// The DOCConfiguration objects the picker holds.
    private static func configurations(of picker: NSObject) -> [NSObject] {
        guard let cls = NSClassFromString("DOCConfiguration") else { return [] }
        var found: [NSObject] = []
        for (_, ivar, _) in ivars(of: picker) where isObject(ivar) {
            if let value = object_getIvar(picker, ivar) as? NSObject, value.isKind(of: cls),
               !found.contains(where: { $0 === value }) { found.append(value) }
        }
        return found
    }

    /// Every object field of `object` that holds the bundle ID gets the signed App
    /// ID instead. Returns the fields' names.
    private static func rewrite(_ object: NSObject) -> [String] {
        guard let signedObject else { return [] }
        var names: [String] = []
        for (name, ivar, _) in ivars(of: object) where isObject(ivar) {
            guard let value = object_getIvar(object, ivar) as? NSString, value as String == bundleID else { continue }
            object_setIvarWithStrongDefault(object, ivar, signedObject)
            names.append(name)
        }
        return names
    }

    /// Sets a BOOL field to YES when the object has one by that name.
    private static func setFlag(_ object: NSObject, name: String) {
        guard let field = ivars(of: object).first(where: { $0.name == name }), field.kind == "B" || field.kind == "c" else {
            LogStore.shared.log("[external] folder picker: no \(name) field")
            return
        }
        Unmanaged.passUnretained(object).toOpaque().advanced(by: ivar_getOffset(field.ivar)).storeBytes(of: 1, as: UInt8.self)
        LogStore.shared.log("[external] folder picker: \(name) set")
    }

    /// The fields that look like an app's identity, with what they hold: the
    /// bundle ID, the signed App ID, nothing, or the value itself.
    private static func describe(_ object: NSObject) -> String {
        let words = ["identifier", "host", "bundle", "entitlement", "client", "source", "process", "bookmark", "interaction"]
        var parts: [String] = []
        for (name, ivar, kind) in ivars(of: object) where words.contains(where: { name.lowercased().contains($0) }) {
            if isObject(ivar) {
                let value = object_getIvar(object, ivar)
                if value == nil { parts.append("\(name)=nil"); continue }
                guard let text = value as? NSString else { parts.append("\(name)=<\(type(of: value!))>"); continue }
                let string = text as String
                parts.append("\(name)=" + (string == bundleID ? "bundle-id" : string == signedAppID ? "app-id" : "\"\(string)\""))
            } else if kind == "B" || kind == "c" {
                let field = Unmanaged.passUnretained(object).toOpaque().advanced(by: ivar_getOffset(ivar))
                parts.append("\(name)=\(field.load(as: UInt8.self))")
            } else if kind == "q" || kind == "Q" {
                let field = Unmanaged.passUnretained(object).toOpaque().advanced(by: ivar_getOffset(ivar))
                parts.append("\(name)=\(field.load(as: Int64.self))")
            }
        }
        return parts.joined(separator: " ")
    }

    /// All instance variables of the object's class and its superclasses below NSObject.
    private static func ivars(of object: NSObject) -> [(name: String, ivar: Ivar, kind: String)] {
        var result: [(name: String, ivar: Ivar, kind: String)] = []
        var cls: AnyClass? = object_getClass(object)
        while let current = cls, ObjectIdentifier(current) != ObjectIdentifier(NSObject.self) {
            var count: UInt32 = 0
            if let list = class_copyIvarList(current, &count) {
                for i in 0..<Int(count) {
                    let ivar = list[i]
                    guard let name = ivar_getName(ivar) else { continue }
                    let type = ivar_getTypeEncoding(ivar).map { String(cString: $0) } ?? ""
                    result.append((String(cString: name), ivar, type))
                }
                free(list)
            }
            cls = class_getSuperclass(current)
        }
        return result
    }

    private static func isObject(_ ivar: Ivar) -> Bool {
        ivar_getTypeEncoding(ivar).map { $0.pointee == CChar(UInt8(ascii: "@")) } ?? false
    }

    // MARK: hooks

    /// The signed App ID in place of the bundle ID while the picker is open; any
    /// other value, and every value at other times, is kept.
    private static func host(_ value: NSString?, hook: String) -> NSString? {
        guard active.on else { return value }
        let swap = value.map { $0 as String == bundleID } ?? false
        count(hook, swapped: swap)
        return swap ? signedObject : value
    }

    /// Hooks DOCConfiguration's hostIdentifier setter and getter and its
    /// encodeWithCoder:. Only methods the class defines itself are replaced, so
    /// nothing it inherits changes. False when the class is not loaded yet, to try
    /// again at the next pick.
    private static func install(_ signed: String) -> Bool {
        if NSClassFromString("DOCConfiguration") == nil {
            for framework in ["DocumentManager", "DocumentManagerCore"] {
                _ = dlopen("/System/Library/PrivateFrameworks/\(framework).framework/\(framework)", RTLD_LAZY)
            }
        }
        guard let cls = NSClassFromString("DOCConfiguration") else {
            LogStore.shared.log("[external] folder picker: DOCConfiguration not found, picker left as it is")
            return false
        }
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return true }
        defer { free(list) }
        let methods = (0..<Int(count)).map { list[$0] }
        func own(_ name: String) -> (Method, Selector)? {
            let sel = NSSelectorFromString(name)
            return methods.first { method_getName($0) == sel }.map { ($0, sel) }
        }
        var hooked: [String] = []
        if case let (method, sel)? = own("setHostIdentifier:") {
            typealias Setter = @convention(c) (AnyObject, Selector, NSString?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
            let body: @convention(block) (AnyObject, NSString?) -> Void = { object, value in
                original(object, sel, host(value, hook: "set"))
            }
            method_setImplementation(method, imp_implementationWithBlock(body))
            hooked.append("set")
        }
        if case let (method, sel)? = own("hostIdentifier") {
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSString?
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let body: @convention(block) (AnyObject) -> NSString? = { object in
                host(original(object, sel), hook: "get")
            }
            method_setImplementation(method, imp_implementationWithBlock(body))
            hooked.append("get")
        }
        if case let (method, sel)? = own("encodeWithCoder:") {
            // The last moment before the configuration goes to the picker's process.
            typealias Encode = @convention(c) (AnyObject, Selector, NSCoder) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Encode.self)
            let body: @convention(block) (AnyObject, NSCoder) -> Void = { object, coder in
                let (on, options) = active
                if on, !options.contains("hooks"), let config = object as? NSObject {
                    FolderPickerSigning.count("encode", swapped: !rewrite(config).isEmpty)
                } else if on {
                    FolderPickerSigning.count("encode", swapped: false)
                }
                original(object, sel, coder)
            }
            method_setImplementation(method, imp_implementationWithBlock(body))
            hooked.append("encode")
        }
        let names = ivarNames(cls)
        LogStore.shared.log("[external] folder picker hooks: \(hooked.isEmpty ? "none" : hooked.joined(separator: "+"))"
            + " DOCConfiguration fields: \(names)")
        return true
    }

    private static func ivarNames(_ cls: AnyClass) -> String {
        var count: UInt32 = 0
        guard let list = class_copyIvarList(cls, &count) else { return "none" }
        defer { free(list) }
        return (0..<Int(count)).compactMap { ivar_getName(list[$0]).map { String(cString: $0) } }.joined(separator: ",")
    }
}

/// Moves an installed game between this device and external drives: copies
/// it, checks the copy, then deletes the original. A failed or cancelled move
/// removes the partial copy and leaves the original as it was.
@MainActor final class GameMover: ObservableObject {
    static let shared = GameMover()
    /// The entry being moved, and how far along (0...1).
    @Published private(set) var moving: UUID?
    @Published private(set) var progress = 0.0

    struct Failure: LocalizedError { let errorDescription: String? }

    /// What a non-Steam entry's move takes along: the program's folder, or the
    /// folder above it when the program sits in a bin/Win64-style subfolder.
    static func gameFolder(_ relativePath: String) -> String {
        var parts = relativePath.split(separator: "/").map(String.init).dropLast()
        let inner: Set<String> = ["bin", "bin32", "bin64", "binaries", "win32", "win64", "x86", "x64", "x86_64", "system", "game", "release", "shipping"]
        while parts.count > 1, inner.contains(parts.last!.lowercased()) { parts = parts.dropLast() }
        // Never a top-level container such as "Games" or "External/<name>" itself.
        return parts.joined(separator: "/")
    }

    /// Where a library entry is now (a drive name, or "This iPhone").
    static func place(_ relativePath: String) -> String {
        ExternalDrives.driveName(library: relativePath) ?? "This iPhone"
    }

    func move(_ entry: LibraryEntry, toSteamLibrary target: String? = nil, toRoot root: String? = nil) async throws -> LibraryEntry {
        guard moving == nil else { throw Failure(errorDescription: "Another game is being moved.") }
        guard wine_process_is_running() == 0 else { throw Failure(errorDescription: "Close the running game first.") }
        guard !SteamOwnedLibrary.shared.hasStorageWork else { throw Failure(errorDescription: "Wait for downloads and cloud operations to finish.") }
        var entry = entry
        var items: [(from: URL, to: URL)] = []
        var newPath: String
        if let appID = entry.steamAppID {
            guard SteamOwnedLibrary.shared.downloads[appID] == nil else { throw Failure(errorDescription: "Wait for the download to finish or cancel it first.") }
            guard let target, let game = SteamGamesModel.shared.games.first(where: { $0.id == appID }) else {
                throw Failure(errorDescription: "Steam does not list this game as installed.")
            }
            guard game.library.caseInsensitiveCompare(target) != .orderedSame else { return entry }
            guard SteamInstallPaths.isManaged(library: target) else { throw ExternalStorageError.invalidRecord }
            let fromGame = try ExternalDrives.nativeURL(game.library + "/common/" + game.installDir, write: true)
            let toGame = try ExternalDrives.nativeURL(target + "/common/" + game.installDir, write: true)
            items.append((fromGame, toGame))
            let manifest = "/appmanifest_\(appID).acf"
            items.append((try ExternalDrives.nativeURL(game.library + manifest, write: true),
                          try ExternalDrives.nativeURL(target + manifest, write: true)))
            let journal = "downloading/\(appID)"
            let fromJournal = try ExternalDrives.nativeURL(game.library + "/" + journal, write: true)
            if FileManager.default.fileExists(atPath: fromJournal.path) {
                items.append((fromJournal, try ExternalDrives.nativeURL(target + "/" + journal, write: true)))
            }
            newPath = target + "/common/" + game.installDir
        } else {
            guard let root else { throw Failure(errorDescription: "Choose where to move the game.") }
            let folder = Self.gameFolder(entry.relativePath)
            let name = (folder as NSString).lastPathComponent
            guard !folder.isEmpty, !["games", "external"].contains(folder.lowercased()), folder.split(separator: "/").count >= (folder.hasPrefix("External/") ? 3 : 1)
            else { throw Failure(errorDescription: "This game's folder cannot be moved.") }
            let dest = root + "/" + name
            guard dest.caseInsensitiveCompare(folder) != .orderedSame else { return entry }
            items.append((try ExternalDrives.nativeURL(folder, write: true), try ExternalDrives.nativeURL(dest, write: true)))
            newPath = dest + entry.relativePath.dropFirst(folder.count)
        }
        if let name = ExternalDrives.driveName(library: newPath), !ExternalDrives.isConnected(name) {
            throw Failure(errorDescription: "\(name) is not connected.")
        }
        let copy = items.map { (from: $0.from.resolvingSymlinksInPath(), to: $0.to) }

        moving = entry.id; progress = 0
        MoveBackground.shared.started(entry.title)
        defer { moving = nil; MoveBackground.shared.ended() }
        LogStore.shared.log("[move] \(entry.title): \(entry.relativePath) -> \(newPath)")
        try await Task.detached(priority: .userInitiated) {
            try Self.copyVerifyDelete(copy) { fraction in
                Task { @MainActor in GameMover.shared.progress = fraction; MoveBackground.shared.progress(fraction) }
            }
        }.value
        entry.relativePath = newPath
        LibraryModel.shared.save(entry)
        if let appID = entry.steamAppID, let target {
            SteamOwnedLibrary.shared.installMoved(appID, to: target)
            if newPath.hasPrefix("External/") { ExternalDrives.shared.refreshSteam() }
            SteamGamesModel.shared.refresh()
        }
        LogStore.shared.log("[move] done \(entry.title)")
        return entry
    }

    /// Copies one file in 8 MB pieces, reporting each piece, so a large file
    /// moves the progress bar too.
    nonisolated private static func copyFile(_ from: URL, to: URL, copied: (Int64) -> Void) throws {
        guard FileManager.default.createFile(atPath: to.path, contents: nil) else {
            throw Failure(errorDescription: "Could not write \(to.lastPathComponent).")
        }
        let input = try FileHandle(forReadingFrom: from), output = try FileHandle(forWritingTo: to)
        defer { try? input.close(); try? output.close() }
        while true {
            let chunk = try autoreleasepool { try input.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied(Int64(chunk.count))
        }
        try output.synchronize()
    }

    nonisolated private static func copyVerifyDelete(_ items: [(from: URL, to: URL)], progress: @escaping (Double) -> Void) throws {
        let fm = FileManager.default
        func files(_ url: URL) -> [(URL, Int64)] {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            if !isDir.boolValue { return [(url, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))] }
            // Any folder that cannot be read fails the move: a skipped folder
            // would be missing from the copy and then deleted with the original.
            var out: [(URL, Int64)] = [], unreadable: URL?
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) { failed, _ in
                unreadable = failed; return false
            }
            while let item = walker?.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                if values?.isRegularFile == true { out.append((item, Int64(values?.fileSize ?? 0))) }
                else if values?.isDirectory != true { unreadable = item; break }
            }
            if let unreadable { failure = "Could not read \(unreadable.lastPathComponent)." }
            return out
        }
        var failure: String?
        let sources = items.map { files($0.from) }
        if let failure { throw Failure(errorDescription: failure) }
        let total = sources.flatMap { $0 }.reduce(Int64(0)) { $0 + $1.1 }
        guard !sources.isEmpty, !(sources.first?.isEmpty ?? true) else { throw Failure(errorDescription: "The game's files were not found.") }
        for item in items where fm.fileExists(atPath: item.to.path) {
            throw Failure(errorDescription: "\(item.to.lastPathComponent) already exists there.")
        }
        if let parent = items.first?.to.deletingLastPathComponent() {
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // FAT32 holds no file of 4 GB or more.
            let largest = sources.flatMap { $0 }.map(\.1).max() ?? 0
            if let type = parent.fileSystemType?.lowercased(), ["msdos", "fat", "fat32", "vfat"].contains(type), largest >= 1 << 32 {
                throw Failure(errorDescription: "This drive is formatted FAT32, which cannot hold this game's files over 4 GB. Use an exFAT or APFS drive.")
            }
            if let free = parent.freeSpace, free < total + 256 << 20 {
                throw Failure(errorDescription: "Not enough free space: \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) needed.")
            }
        }
        var done: Int64 = 0, lastReport = Date.distantPast
        do {
            for (index, item) in items.enumerated() {
                let base = item.from.path
                for (file, size) in sources[index] {
                    let relative = file.path == base ? "" : String(file.path.dropFirst(base.count + 1))
                    let dest = relative.isEmpty ? item.to : item.to.appendingPathComponent(relative)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try copyFile(file, to: dest) { bytes in
                        done += bytes
                        if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(total > 0 ? Double(done) / Double(total) : 1) }
                    }
                    let copied = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
                    guard copied == size else { throw Failure(errorDescription: "The copy of \(file.lastPathComponent) does not match.") }
                }
            }
            // Check the whole copy before anything is deleted.
            for (index, item) in items.enumerated() {
                func listing(_ list: [(URL, Int64)], base: URL) -> [String: Int64] {
                    Dictionary(list.map { (String($0.0.path.dropFirst(base.path.count)), $0.1) }, uniquingKeysWith: { a, _ in a })
                }
                let copied = listing(files(item.to), base: item.to)
                // The original is listed again, in case it changed or was only partly read.
                let original = listing(files(item.from), base: item.from)
                guard failure == nil, copied == original, original == listing(sources[index], base: item.from) else {
                    throw Failure(errorDescription: "The copy is incomplete (\(copied.count) of \(original.count) files).")
                }
            }
        } catch {
            for item in items { try? fm.removeItem(at: item.to) }
            throw error
        }
        progress(1)
        LogStore.shared.log("[move] copied and checked files=\(sources.reduce(0) { $0 + $1.count }) bytes=\(total)")
        // The copy is already checked, so the move stands; a source that cannot be
        // removed (read-only or busy files) is logged rather than left unexplained,
        // because it keeps using the old drive's space.
        for item in items {
            do { try fm.removeItem(at: item.from) }
            catch { LogStore.shared.log("[move] copied, but the original \(item.from.lastPathComponent) could not be removed: \(error.localizedDescription)") }
        }
    }
}

/// Game details › Location: where the game is and Move to.
struct GameMoveSection: View {
    @Binding var entry: LibraryEntry
    @ObservedObject private var mover = GameMover.shared
    @ObservedObject private var drives = ExternalDrives.shared
    @State private var error: String?
    /// "120 GB free of 500 GB" for each place, by its library or root.
    @State private var sizes: [String: String] = [:]

    var body: some View {
        let here = GameMover.place(entry.relativePath)
        let steam = entry.steamAppID != nil
        let targets: [(name: String, value: String)] = steam ? drives.steamTargets.map { ($0.name, $0.library) } : drives.gameTargets.map { ($0.name, $0.root) }
        Section {
            LabeledContent("Installed on", value: here)
            if mover.moving == entry.id {
                ProgressView(value: mover.progress) { Text("Moving") } currentValueLabel: { Text("\(Int(mover.progress * 100))%") }
            } else if targets.count > 1 {
                Menu("Move to") {
                    ForEach(targets.filter { $0.name != here }, id: \.value) { target in
                        Button { start(target.value, steam: steam) } label: {
                            Text(target.name)
                            if let size = sizes[target.value] { Text(size) }
                        }
                    }
                }
                .disabled(mover.moving != nil)
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: { Text("Install Location") } footer: {
            Text("Moving copies the game, checks the copy, then deletes the original. Keep the drive connected until it finishes.")
        }
        .task(id: targets.map(\.value).joined()) {
            let drive = LibraryModel.drive
            var next: [String: String] = [:]
            for target in targets {
                let url = drive.appendingPathComponent(target.value)
                let free = url.freeSpace
                let total = url.volumeTotal
                let f = ByteCountFormatter.string(fromByteCount: free ?? 0, countStyle: .file)
                next[target.value] = switch (free, total) {
                case let (_?, total?): "\(f) free of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                case (_?, nil): "\(f) free"
                default: nil
                }
            }
            sizes = next
        }
    }

    private func start(_ value: String, steam: Bool) {
        error = nil
        Task {
            do { entry = try await GameMover.shared.move(entry, toSteamLibrary: steam ? value : nil, toRoot: steam ? nil : value) }
            catch { self.error = error.localizedDescription }
        }
    }
}

extension URL {
    /// The volume's file system ("exfat", "msdos", "apfs", ...), or nil.
    var fileSystemType: String? {
        var url = resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
    /// Total bytes of the volume holding this path (statfs), or nil.
    var volumeTotal: Int64? {
        var url = resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        if let total = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity, total > 0 { return Int64(total) }
        var info = statfs()
        if statfs(url.path, &info) == 0, info.f_blocks > 0 { return Int64(info.f_blocks) * Int64(info.f_bsize) }
        return nil
    }
}

/// A move shown by iOS like a Steam download (SteamDownloadBackground.swift):
/// on iOS 26 and later a continued-processing task with the move's progress,
/// which also keeps Madeira running if it leaves the foreground. Its
/// identifier "<bundle id>.download.move" is covered by Info.plist's
/// `.download.*` entry.
@MainActor final class MoveBackground {
    static let shared = MoveBackground()
    private var task: AnyObject?
    private var registered = false
    private var title = ""
    private var fraction = 0.0

    private var identifier: String? {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return permitted.first { $0.hasSuffix(".download.*") }.map { String($0.dropLast()) + "move" }
    }

    func started(_ name: String) {
        title = "Moving \(name)"; fraction = 0
        guard #available(iOS 26.0, *), let identifier else { return }
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                MainActor.assumeIsolated { self?.attach(task) }
            }
            guard registered else { LogStore.shared.log("[move] background task refused"); return }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Madeira")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { LogStore.shared.log("[move] background task not submitted") }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        guard GameMover.shared.moving != nil else { task.setTaskCompleted(success: true); return }
        self.task = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(fraction * 1000)
        task.updateTitle(title, subtitle: "Madeira")
        task.expirationHandler = { LogStore.shared.log("[move] background time ended") }
    }

    func progress(_ value: Double) {
        fraction = value
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(min(1, value) * 1000)
            task.updateTitle(title, subtitle: "\(Int(min(1, value) * 100))% · Madeira")
        }
    }

    func ended() {
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask { task.setTaskCompleted(success: true) }
        task = nil
    }
}
