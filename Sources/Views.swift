import PDFKit
import SwiftUI

@main
struct ResumeVersionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel(root: AppModel.locateRoot())

    var body: some Scene {
        Window("Resume Versions", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1250, height: 900)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            DetailView()
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            SidebarView()
                .frame(minWidth: 270, idealWidth: 330, maxWidth: 480, maxHeight: .infinity)
        }
        .onAppear {
            model.installKeyMonitor()
            if CommandLine.arguments.contains("--selftest") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.runSelfTest() }
            }
        }
    }
}

// MARK: Sidebar (right)

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by company or label", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.3)))
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                List(selection: $model.selection) {
                    if let main = model.main {
                        Section("Pinned") {
                            VersionRow(version: main, depth: 0).tag(main.id).id(main.id)
                        }
                    }
                    Section(model.search.isEmpty ? "Versions" : "Matches") {
                        let rows = model.visibleRows
                        if rows.isEmpty {
                            Text("No matches").foregroundStyle(.secondary)
                        }
                        ForEach(rows) { r in
                            VersionRow(version: r.version, depth: r.depth).tag(r.id).id(r.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: model.selection) { _, s in
                    if let s { proxy.scrollTo(s) }
                }
            }

            Divider()
            Text("\(model.versions.count) versions · auto-refreshing")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }
}

struct VersionRow: View {
    @EnvironmentObject var model: AppModel
    let version: ResumeVersion
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            if depth > 0 { Color.clear.frame(width: CGFloat(depth) * 14, height: 1) }
            if !version.children.isEmpty && model.search.isEmpty {
                Button { model.toggle(version.id) } label: {
                    Image(systemName: model.collapsed.contains(version.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else if !version.isMain {
                Color.clear.frame(width: 12, height: 1)
            }
            if version.isMain {
                Image(systemName: "pin.fill").foregroundStyle(.orange).font(.caption)
            } else {
                Text(version.numberText)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(version.label).lineLimit(1).truncationMode(.middle)
                Text(version.date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if version.pdfs.count > 1 {
                Text("1p · 2p").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: Detail (left)

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let v = model.selected {
            VStack(spacing: 0) {
                header(v)
                Divider()
                VSplitView {
                    ScrollView {
                        Text(v.changes.isEmpty ? "No CHANGES.txt in this folder." : v.changes)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 70, idealHeight: 150, maxHeight: 420)
                    .background(Color(nsColor: .textBackgroundColor))

                    Group {
                        if model.selectedPDF != nil {
                            PDFKitView(file: model.selectedPDF, model: model)
                        } else {
                            Text("No PDF in this folder.").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minHeight: 300, maxHeight: .infinity)
                }
            }
        } else {
            Text("Select a version").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func header(_ v: ResumeVersion) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(v.isMain ? "Current main" : "\(v.numberText) · \(v.label)").font(.headline)
                Text([model.selectedPDF?.url.lastPathComponent, v.date].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if v.pdfs.count > 1 {
                Picker("Pages", selection: Binding(
                    get: { model.selectedPDF?.kind ?? "" },
                    set: { model.preferredKind = $0 })) {
                    ForEach(v.pdfs, id: \.kind) { Text($0.kind).tag($0.kind) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ControlGroup {
                Button { model.pdfView?.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                Button { model.pdfView?.autoScales = true } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Fit width")
                Button { model.pdfView?.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
            }
            .fixedSize()
            Button("Show in Finder") { model.showInFinder() }
                .disabled(model.selectedPDF == nil)
            Button("Open in Preview") { model.openInPreview() }
                .disabled(model.selectedPDF == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct PDFKitView: NSViewRepresentable {
    let file: PDFFile?
    let model: AppModel

    final class Coordinator { var key = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .underPageBackgroundColor
        model.pdfView = v
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        model.pdfView = v
        // Reload when the file changes or is re-saved.
        let key = (file?.url.path ?? "") + "|" + String(file?.modified?.timeIntervalSince1970 ?? 0)
        guard key != context.coordinator.key else { return }
        context.coordinator.key = key
        v.document = file.flatMap { PDFDocument(url: $0.url) }
        v.autoScales = true
    }
}
