import AppKit
import CoreServices

/// A Live Activity–style item: a download with real progress, or a video export
/// (such as a DaVinci Resolve render) tracked by the file growing on disk.
struct LiveActivity: Identifiable, Equatable {
    enum Kind: Equatable { case download, export }
    enum State: Equatable { case running, done, cancelled }
    var id: String { url.path }
    var kind: Kind
    var url: URL
    var name: String
    var fraction: Double?
    var bytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var startedAt = Date()
    var finishedAt: Date?
    var state: State = .running
    var appName: String?
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Watches downloads and video exports with file-system events: Safari's .download
/// bundles carry real progress, Chrome/Firefox partial files and exports are tracked
/// by growth (macOS 27 no longer delivers cross-app file progress to subscribers).
/// A one-second size check runs only while something is actively being written.
@MainActor final class ActivityCenter: ObservableObject {
    @Published private(set) var activities: [LiveActivity] = []
    var onFinished: ((LiveActivity) -> Void)?
    private var stream: FSEventStreamRef?
    private var sizeTimer: Timer?
    private var lastGrowth: [String: Date] = [:]
    private var lastSample: [String: (bytes: Int64, at: Date)] = [:]
    /// Files already announced, so a render that pauses and resumes doesn't ding twice.
    private var announced: [String: Date] = [:]
    /// An export is done after this long without growing; renders often pause for a few seconds.
    private static let exportQuiet: TimeInterval = 20
    /// Writes shorter than this (cache files, autosaves, quick saves) finish without an alert.
    private static let minimumExport: TimeInterval = 20
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "mkv", "avi", "webm", "mts", "braw", "wav", "m4a", "aac", "mp3"]

    var running: [LiveActivity] { activities.filter { $0.state == .running } }
    var visible: [LiveActivity] {
        activities.filter { $0.state == .running || ($0.finishedAt.map { Date().timeIntervalSince($0) < 120 } ?? false) }
    }

    func start() { restartExportWatch() }
    func stop() {
        stopStream()
        sizeTimer?.invalidate(); sizeTimer = nil
    }
    func reveal(_ activity: LiveActivity) {
        let url = FileManager.default.fileExists(atPath: activity.url.path) ? activity.url : activity.url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func dismiss(_ activity: LiveActivity) { activities.removeAll { $0.id == activity.id } }

    // MARK: Downloads

    private static var downloadsFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true) }
    private static let partialExtensions: Set<String> = ["crdownload", "part", "partial", "download"]

    /// Safari keeps progress in the .download bundle's Info.plist.
    private func safariProgress(_ bundle: URL) {
        let info = bundle.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: bundle.path) else { finish(path: bundle.path); return }
        guard let plist = NSDictionary(contentsOf: info),
              let done = (plist["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value else { return }
        let total = (plist["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value ?? 0
        let now = Date()
        if let index = activities.firstIndex(where: { $0.id == bundle.path && $0.state == .running }) {
            if let previous = lastSample[bundle.path], done > previous.bytes {
                let rate = Double(done - previous.bytes) / max(0.2, now.timeIntervalSince(previous.at))
                activities[index].bytesPerSecond = activities[index].bytesPerSecond == 0 ? rate : activities[index].bytesPerSecond * 0.7 + rate * 0.3
            }
            activities[index].bytes = done
            activities[index].fraction = total > 0 ? Double(done) / Double(total) : nil
        } else {
            var activity = LiveActivity(kind: .download, url: bundle, name: Self.displayName(for: bundle), fraction: total > 0 ? Double(done) / Double(total) : nil, bytes: done)
            activity.appName = "Safari"
            activities.removeAll { $0.id == bundle.path }
            activities.insert(activity, at: 0)
        }
        lastSample[bundle.path] = (done, now)
        lastGrowth[bundle.path] = now
        ensureSizeTimer()
    }
    /// A partial download disappeared: finished if the renamed file exists, otherwise cancelled.
    private func finish(path: String) {
        guard let index = activities.firstIndex(where: { $0.id == path && $0.state == .running }) else { return }
        let finalURL = Self.finalURL(for: activities[index].url)
        let succeeded = finalURL.path != path && FileManager.default.fileExists(atPath: finalURL.path)
        activities[index].state = succeeded ? .done : .cancelled
        activities[index].finishedAt = Date()
        activities[index].bytesPerSecond = 0
        if succeeded {
            activities[index].url = finalURL
            activities[index].fraction = 1
            activities[index].bytes = (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? activities[index].bytes
            announce(activities[index])
        }
    }
    static func displayName(for url: URL) -> String {
        ["crdownload", "download", "part", "partial"].contains(url.pathExtension.lowercased()) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
    static func finalURL(for url: URL) -> URL {
        ["crdownload", "download", "part", "partial"].contains(url.pathExtension.lowercased()) ? url.deletingPathExtension() : url
    }

    // MARK: Exports and renders

    /// Folders watched: Downloads, Movies, Desktop, Documents and every external drive.
    static var exportFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var folders = ["Downloads", "Movies", "Desktop", "Documents"].map { home.appendingPathComponent($0, isDirectory: true) }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey], options: [.skipHiddenVolumes]) ?? []
        folders += volumes.filter { $0.path.hasPrefix("/Volumes/") && (try? $0.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) != true }
        return folders.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// Call when drives mount or unmount so new drives are watched.
    func restartExportWatch() {
        stopStream()
        let paths = Self.exportFolders.map(\.path) as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let center = Unmanaged<ActivityCenter>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changed: [String] = []
            for index in 0..<min(count, list.count) {
                let flag = eventFlags[index]
                guard flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 else { continue }
                changed.append(list[index])
            }
            MainActor.assumeIsolated { center.filesChanged(changed) }
        }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.8, FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
    private func filesChanged(_ paths: [String]) {
        let downloads = Self.downloadsFolder.path + "/"
        for path in paths {
            if let range = path.range(of: ".download/") {
                safariProgress(URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".download")); continue
            }
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            let inDownloads = path.hasPrefix(downloads) && !path.dropFirst(downloads.count).contains("/")
            guard !url.lastPathComponent.hasPrefix("."), inDownloads || (Self.videoExtensions.contains(ext) && !Self.isWorkingFile(path)) else { continue }
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else {
                finish(path: path); lastSample[path] = nil; continue
            }
            let now = Date()
            if let index = activities.firstIndex(where: { $0.id == path && $0.state == .running }) {
                update(index, size: size, now: now)
            } else if let previous = lastSample[path], size > previous.bytes,
                      let index = activities.firstIndex(where: { $0.id == path && $0.state == .done && $0.kind == .export && now.timeIntervalSince($0.finishedAt ?? .distantPast) < 10 * 60 }) {
                // A render that paused long enough to look finished: pick it back up, without a second alert.
                activities[index].state = .running; activities[index].finishedAt = nil
                update(index, size: size, now: now)
                ensureSizeTimer()
            } else if let previous = lastSample[path], size > previous.bytes,
                      !activities.contains(where: { $0.id == path && $0.state != .running && Date().timeIntervalSince($0.finishedAt ?? .distantPast) < 60 }) {
                // Seen growing twice (and not a file that just finished): in progress.
                let kind: LiveActivity.Kind = inDownloads ? .download : .export
                var activity = LiveActivity(kind: kind, url: url, name: Self.displayName(for: url), bytes: size)
                activity.appName = kind == .export ? Self.renderingApp : (ext == "crdownload" ? "Chrome" : ext == "part" ? "Firefox" : nil)
                activity.startedAt = previous.at
                activities.removeAll { $0.id == path }
                activities.insert(activity, at: 0)
                lastGrowth[path] = now
                ensureSizeTimer()
            }
            lastSample[path] = (size, now)
        }
    }
    private func update(_ index: Int, size: Int64, now: Date) {
        let path = activities[index].id
        if let previous = lastSample[path], size > previous.bytes {
            let rate = Double(size - previous.bytes) / max(0.2, now.timeIntervalSince(previous.at))
            activities[index].bytesPerSecond = activities[index].bytesPerSecond == 0 ? rate : activities[index].bytesPerSecond * 0.7 + rate * 0.3
            lastGrowth[path] = now
        }
        activities[index].bytes = size
    }
    /// While an export runs, check sizes each second; 8 seconds without growth means done.
    private func ensureSizeTimer() {
        guard sizeTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tickExports() } }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        sizeTimer = timer
    }
    private func tickExports() {
        let now = Date()
        for activity in activities where activity.state == .running && activity.url.pathExtension == "download" {
            safariProgress(activity.url)
        }
        for index in activities.indices where activities[index].state == .running && activities[index].url.pathExtension != "download" {
            let path = activities[index].id
            if let size = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) {
                update(index, size: size, now: now)
                lastSample[path] = (size, now)
            } else {
                finish(path: path); continue
            }
            // Partial downloads finish when renamed; other downloads after 8 s without growth,
            // exports after 20 s (renders pause between segments).
            let quiet = activities[index].kind == .export ? Self.exportQuiet : 8
            if !Self.partialExtensions.contains(activities[index].url.pathExtension.lowercased()), now.timeIntervalSince(lastGrowth[path] ?? now) > quiet {
                activities[index].state = .done
                activities[index].finishedAt = lastGrowth[path] ?? now
                activities[index].bytesPerSecond = 0
                announce(activities[index])
            }
        }
        lastSample = lastSample.filter { now.timeIntervalSince($0.value.at) < 60 }
        announced = announced.filter { now.timeIntervalSince($0.value) < 30 * 60 }
        if !activities.contains(where: { $0.state == .running }) {
            sizeTimer?.invalidate(); sizeTimer = nil
        }
    }
    /// Only finished work the user would want to hear about: not a file already announced,
    /// and not an export that took under 20 seconds (caches, autosaves, quick saves).
    private func announce(_ activity: LiveActivity) {
        if announced[activity.id] != nil { return }
        if activity.kind == .export, (activity.finishedAt ?? Date()).timeIntervalSince(activity.startedAt) < Self.minimumExport { return }
        announced[activity.id] = Date()
        onFinished?(activity)
    }
    /// Files editors write while you work, never exports: render caches, optimized and proxy
    /// media, audio caches, backups and anything inside a library bundle.
    static func isWorkingFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        let folders = ["/cacheclip/", "/cache/", "/caches/", "/render cache/", "/render files/", "/optimizedmedia/", "/optimized media/", "/proxymedia/", "/proxy media/", "/proxies/", "/proxy/",
                       "/transcoded media/", "/.gallery/", "/gallery/", "/audio cache/", "/fusion/", "/resolve disk database/", "/resolve project library/", "/final cut backups/",
                       "/capcut/user data/", "/capcut drafts/", "/user data/", "/autosave", "/backups/", "/screen studio projects/"]
        if folders.contains(where: lower.contains) { return true }
        // Inside a Final Cut, iMovie, Photos or Capture One library: renders and transcodes, not exports.
        let bundles = [".fcpbundle/", ".imovielibrary/", ".photoslibrary/", ".cocatalog/", ".drp/", ".prproj/", ".band/", ".logicx/"]
        return bundles.contains(where: lower.contains)
    }
    /// Names the app most likely writing an export.
    private static var renderingApp: String? {
        let apps: [(String, String)] = [("com.blackmagic-design.DaVinciResolve", "DaVinci Resolve"), ("com.blackmagic-design.DaVinciResolveLite", "DaVinci Resolve"),
                                         ("com.lemon.lvoverseas", "CapCut"), ("com.apple.FinalCut", "Final Cut Pro"), ("com.apple.Compressor", "Compressor"),
                                         ("com.apple.QuickTimePlayerX", "QuickTime"), ("com.apple.iMovieApp", "iMovie")]
        return apps.first { NSRunningApplication.runningApplications(withBundleIdentifier: $0.0).first != nil }?.1
    }
    static func icon(for activity: LiveActivity) -> NSImage {
        let ids = ["DaVinci Resolve": "com.blackmagic-design.DaVinciResolve", "CapCut": "com.lemon.lvoverseas", "Final Cut Pro": "com.apple.FinalCut", "QuickTime": "com.apple.QuickTimePlayerX", "iMovie": "com.apple.iMovieApp", "Compressor": "com.apple.Compressor"]
        if let name = activity.appName, let id = ids[name], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(forFile: FileManager.default.fileExists(atPath: activity.url.path) ? activity.url.path : activity.url.deletingLastPathComponent().path)
    }
}
