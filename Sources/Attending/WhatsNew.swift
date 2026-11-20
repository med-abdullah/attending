import AppKit
import SwiftUI

/// After an update, the first launch shows what changed: this version's section of the
/// release notes, which ship inside the app (Resources/CHANGELOG.md). Settings › Updates
/// and the menu bar menu reopen it.
@MainActor final class WhatsNew: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Once per new version. A first install gets the welcome instead; someone updating from
    /// a version before this existed (setup already done, nothing recorded) gets this.
    func showIfUpdated() {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: "lastVersionSeen")
        defaults.set(Self.version, forKey: "lastVersionSeen")
        guard !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }), !Self.highlights().isEmpty else { return }
        if let last { if Updater.isNewer(Self.version, than: last) { show() } }
        else if Onboarding.done { show() }
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 600), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "What's new in Attending"
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: WhatsNewView(version: Self.version, items: Self.highlights(), close: { [weak window] in window?.close() }))
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { window = nil }
    /// For checking the layout: draws the open window into a PNG.
    func snapshot(to url: URL) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The bullets under "## <version>" in the bundled release notes.
    static func highlights(for version: String = version) -> [String] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return section(version, in: text)
    }
    nonisolated static func section(_ version: String, in text: String) -> [String] {
        var items: [String] = [], inside = false
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                if inside { break }
                inside = line.dropFirst(3).trimmingCharacters(in: .whitespaces) == version
                continue
            }
            guard inside else { continue }
            if line.hasPrefix("- ") { items.append(String(line.dropFirst(2))) }
            else if line.hasPrefix("  "), let last = items.indices.last, !line.trimmingCharacters(in: .whitespaces).isEmpty { items[last] += " " + line.trimmingCharacters(in: .whitespaces) }
        }
        return items
    }
}

struct WhatsNewView: View {
    let version: String
    let items: [String]
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                Text("What's new in Attending \(version)").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.primary)
                Text("Here's what changed in this update.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 44).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(Theme.working).frame(width: 6, height: 6).padding(.top, 6)
                            Text((try? AttributedString(markdown: item)) ?? AttributedString(item))
                                .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 40)
            }
            .scrollIndicators(.never)
            HStack(spacing: 12) {
                Button("Full release notes") { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repository)/releases/tag/v\(version)")!) }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                OnboardingButton(title: "Continue", symbol: "arrow.right", action: close)
            }
            .padding(.top, 16).padding(.bottom, 32)
        }
        .frame(width: 540, height: 600)
        .background(Color.black)
    }
}
