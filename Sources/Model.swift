import AppKit
import CoreServices
import PDFKit

/// Watches a folder tree with FSEvents and calls back on the main queue (coalesced).
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, [url.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

struct TreeRow: Identifiable {
    let id: String
    let version: ResumeVersion
    let depth: Int
}

final class AppModel: ObservableObject {
    static let mainID = Scanner.mainID

    let root: URL
    @Published private(set) var versions: [String: ResumeVersion] = [:]
    @Published private(set) var rootIDs: [String] = []
    @Published private(set) var main: ResumeVersion?
    @Published var selection: String? = AppModel.mainID
    @Published var collapsed: Set<String> = []
    @Published var search = ""
    @Published var preferredKind = "1 page"

    weak var pdfView: PDFView?
    private var watcher: FolderWatcher?
    private var keyMonitor: Any?

    init(root: URL) {
        self.root = root
        reload()
        watcher = FolderWatcher(url: root) { [weak self] in self?.reload() }
    }

    static func locateRoot() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--root"), i + 1 < args.count {
            return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        }
        let besideApp = Bundle.main.bundleURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: besideApp.appendingPathComponent("versions").path) {
            return besideApp
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Resume")
    }

    func reload() {
        let old = selected
        let r = Scanner.scan(root: root)
        if CommandLine.arguments.contains("--log-reloads") { print("RELOAD \(r.versions.count) versions"); fflush(stdout) }
        if r.versions != versions { versions = r.versions }
        if r.roots != rootIDs { rootIDs = r.roots }
        if r.main != main { main = r.main }
        // If the selected folder was renamed (e.g. v19_..._new-copy -> v19_..._company), follow it.
        if let s = selection, s != Self.mainID, versions[s] == nil {
            selection = versions.values.first { $0.numberText == old?.numberText && $0.date == old?.date }?.id
                ?? Self.mainID
        }
    }

    // MARK: Selection

    var selected: ResumeVersion? {
        guard let s = selection else { return nil }
        return s == Self.mainID ? main : versions[s]
    }

    var selectedPDF: PDFFile? {
        guard let v = selected else { return nil }
        return v.pdfs.first { $0.kind == preferredKind } ?? v.pdfs.first
    }

    var visibleRows: [TreeRow] {
        var rows: [TreeRow] = []
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            func walk(_ id: String, _ depth: Int) {
                guard let v = versions[id] else { return }
                rows.append(TreeRow(id: id, version: v, depth: depth))
                if !collapsed.contains(id) { v.children.forEach { walk($0, depth + 1) } }
            }
            rootIDs.forEach { walk($0, 0) }
        } else {
            let terms = q.split(separator: " ").map(String.init)
            rows = versions.values
                .filter { v in terms.allSatisfy { v.searchText.contains($0) } }
                .sorted { ($0.number, $0.date, $0.id) < ($1.number, $1.date, $1.id) }
                .map { TreeRow(id: $0.id, version: $0, depth: 0) }
        }
        return rows
    }

    var navOrder: [String] { (main.map { [$0.id] } ?? []) + visibleRows.map(\.id) }

    func move(_ delta: Int) {
        let order = navOrder
        guard !order.isEmpty else { return }
        if let s = selection, let i = order.firstIndex(of: s) {
            selection = order[max(0, min(order.count - 1, i + delta))]
        } else {
            selection = delta > 0 ? order.first : order.last
        }
    }

    func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    private func collapseOrGoToParent() {
        guard search.isEmpty, let s = selection, let v = versions[s] else { return }
        if !v.children.isEmpty && !collapsed.contains(s) { collapsed.insert(s) }
        else if let p = v.parentID { selection = p }
    }

    private func expandSelected() {
        if let s = selection, versions[s]?.children.isEmpty == false { collapsed.remove(s) }
    }

    /// Up/Down move through versions from anywhere in the window (including the search box).
    /// Left/Right collapse/expand when not typing.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return e }
            let typing = NSApp.keyWindow?.firstResponder is NSText
            switch e.keyCode {
            case 125: self.move(1); return nil
            case 126: self.move(-1); return nil
            case 123 where !typing: self.collapseOrGoToParent(); return nil
            case 124 where !typing: self.expandSelected(); return nil
            default: return e
            }
        }
    }

    // MARK: Actions (read-only)

    func showInFinder() {
        if let u = selectedPDF?.url { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    func openInPreview() {
        guard let u = selectedPDF?.url else { return }
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        NSWorkspace.shared.open([u], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    private func snapshotWindow(to url: URL) {
        guard let win = NSApp.windows.first(where: { $0.isVisible }),
              let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming])
        else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Self-test (--selftest): select every version/PDF and check the PDFView shows that file.

    func runSelfTest() {
        print("ROOT \(root.path)")
        print("TREE")
        if let m = main { print("  [pinned] \(m.label) -> \(m.pdfs.map { $0.url.lastPathComponent })") }
        for r in visibleRows {
            print(String(repeating: "  ", count: r.depth + 1) + "\(r.id)  parent=\(r.version.parentID ?? "-")  pdfs=\(r.version.pdfs.map(\.kind))")
        }
        var checks: [(String, String)] = []
        for id in navOrder {
            guard let v = id == Self.mainID ? main : versions[id] else { continue }
            if v.pdfs.isEmpty { checks.append((id, "")) }
            for p in v.pdfs { checks.append((id, p.kind)) }
        }
        var failures = 0
        func step(_ i: Int) {
            guard i < checks.count else {
                print("SELFTEST DONE: \(checks.count) checks, \(failures) failures")
                fflush(stdout)
                NSApp.terminate(nil)
                return
            }
            let (id, kind) = checks[i]
            selection = id
            preferredKind = kind
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let shown = self.pdfView?.document?.documentURL?.standardizedFileURL
                let v = id == Self.mainID ? self.main : self.versions[id]
                // Independent expectation: the PDF of this kind inside this version's own folder.
                let expected = v?.pdfs.first { $0.kind == kind }?.url.standardizedFileURL
                let inFolder = shown?.deletingLastPathComponent().path == v?.folder.standardizedFileURL.path
                let kindOK = kind != "2 page" || (shown?.lastPathComponent.contains("2Page") ?? false)
                let ok = shown != nil && shown == expected && inFolder && kindOK
                if !ok { failures += 1 }
                let pages = self.pdfView?.document?.pageCount ?? 0
                print("\(ok ? "OK  " : "FAIL") \(id) [\(kind)] -> \(ok ? (shown?.lastPathComponent ?? "nil") : (shown?.path ?? "nil")) (\(pages) page\(pages == 1 ? "" : "s"))")
                if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
                    self.snapshotWindow(to: URL(fileURLWithPath: dir).appendingPathComponent("\(i)_\(id)_\(kind).png"))
                }
                step(i + 1)
            }
        }
        step(0)
    }
}
