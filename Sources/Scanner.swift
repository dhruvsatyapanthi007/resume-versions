import Foundation

/// One PDF inside a version folder. `kind` is "1 page" / "2 page" (or the file name if ambiguous).
struct PDFFile: Hashable {
    let url: URL
    let kind: String
    let modified: Date?
}

struct ResumeVersion: Identifiable, Hashable {
    let id: String          // full folder name (unique even when two folders share a number)
    let number: Int
    let numberText: String  // "v03"
    let date: String
    let label: String
    let folder: URL
    let pdfs: [PDFFile]
    let changes: String
    let searchText: String
    var parentID: String? = nil
    var children: [String] = []
    var isMain = false
}

struct ScanResult {
    var versions: [String: ResumeVersion] = [:]
    var roots: [String] = []
    var main: ResumeVersion?
}

/// Read-only scan of the Resume folder. Never writes anything.
enum Scanner {
    static let mainID = "__current_main__"

    private static let folderRegex = try! NSRegularExpression(pattern: #"^v(\d+)_(\d{4}-\d{2}-\d{2})_(.+)$"#)
    private static let strictBase = try! NSRegularExpression(pattern: #"\bBase:\s*v(\d+)\b"#)
    private static let looseBase = try! NSRegularExpression(pattern: #"\bBase\b[^\n]*?\bv(\d+)\b"#)

    private static func capture(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map {
            m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0))
        }
    }

    private static func readText(_ url: URL) -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        return ""
    }

    private static func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func pdfs(in folder: URL) -> [PDFFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var files = urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { u -> PDFFile in
                let kind = u.lastPathComponent.lowercased().contains("2page") ? "2 page" : "1 page"
                return PDFFile(url: u, kind: kind, modified: modDate(u))
            }
        // If two PDFs land on the same kind, label them by file name instead.
        let counts = Dictionary(grouping: files, by: \.kind).mapValues(\.count)
        files = files.map {
            (counts[$0.kind] ?? 0) > 1
                ? PDFFile(url: $0.url, kind: $0.url.deletingPathExtension().lastPathComponent, modified: $0.modified)
                : $0
        }
        return files.sorted { $0.kind < $1.kind }
    }

    static func scan(root: URL) -> ScanResult {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("versions")
        let entries = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        var list: [ResumeVersion] = []
        var parentNumber: [String: Int] = [:]
        for u in entries {
            guard (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = u.lastPathComponent
            guard let c = capture(folderRegex, name), let num = Int(c[0]) else { continue }
            let changes = readText(u.appendingPathComponent("CHANGES.txt"))
            let tailoredLines = changes.split(separator: "\n")
                .filter { $0.localizedCaseInsensitiveContains("tailored") }
                .joined(separator: " ")
            let search = [name, c[2].replacingOccurrences(of: "-", with: " "), tailoredLines]
                .joined(separator: " ").lowercased()
            list.append(ResumeVersion(id: name, number: num, numberText: "v" + c[0], date: c[1], label: c[2],
                                      folder: u, pdfs: pdfs(in: u), changes: changes, searchText: search))
            if let b = capture(strictBase, changes) ?? capture(looseBase, changes), let bn = Int(b[0]), bn != num {
                parentNumber[name] = bn
            }
        }
        list.sort { ($0.number, $0.date, $0.id) < ($1.number, $1.date, $1.id) }

        func firstID(_ n: Int) -> String? { list.first { $0.number == n }?.id }
        var byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })

        // Parent: "Base: vNN" in CHANGES.txt; v01 is the root; v02 (no Base line) hangs off v01;
        // anything else without a Base line hangs off v02.
        for v in list {
            var p = parentNumber[v.id].flatMap(firstID)
            if p == nil {
                if v.number <= 1 { p = nil }
                else if v.number == 2 { p = firstID(1) }
                else { p = firstID(2) ?? firstID(1) }
            }
            if p == v.id { p = nil }
            byID[v.id]?.parentID = p
        }
        // Break any cycle so every version stays reachable.
        for v in list {
            var seen: Set<String> = []
            var cur = byID[v.id]?.parentID
            while let c = cur, !seen.contains(c) {
                if c == v.id { byID[v.id]?.parentID = nil; break }
                seen.insert(c)
                cur = byID[c]?.parentID
            }
        }
        for v in list {
            if let p = byID[v.id]?.parentID { byID[p]?.children.append(v.id) }
        }

        var result = ScanResult()
        result.versions = byID
        result.roots = list.filter { byID[$0.id]?.parentID == nil }.map(\.id)

        let mainURL = root.appendingPathComponent("Dhruv_Resume.pdf")
        if fm.fileExists(atPath: mainURL.path) {
            let mod = modDate(mainURL)
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let stamp = DateFormatter()
            stamp.dateStyle = .medium
            stamp.timeStyle = .short
            result.main = ResumeVersion(
                id: mainID, number: 0, numberText: "Main", date: mod.map(df.string) ?? "",
                label: "Current main", folder: root,
                pdfs: [PDFFile(url: mainURL, kind: "1 page", modified: mod)],
                changes: "Current main resume\n\(mainURL.path)\nLast modified: \(mod.map(stamp.string) ?? "unknown")",
                searchText: "current main", isMain: true)
        }
        return result
    }
}
