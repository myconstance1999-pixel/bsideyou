import AppKit
import SwiftUI
import BSidePlatform
import BSideCore

/// One ordinary key-capable drawer owns search, folder grants and application shortcuts.
final class DesktopWorkspaceController: NSObject {
    private var window: NSWindow?
    let model: DesktopWorkspaceModel

    init(storeURL: URL) {
        model = DesktopWorkspaceModel(storeURL: storeURL)
        super.init()
        model.onOpened = { [weak self] in self?.close() }
    }

    func show(_ section: DesktopWorkspaceAction) {
        guard section == .applications || section == .files else { return }
        model.section = section
        model.search = ""
        if window == nil {
            let created = DesktopDrawerWindow(contentRect: CGRect(x: 0, y: 0, width: 552, height: 570),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            created.isReleasedWhenClosed = false
            created.titlebarAppearsTransparent = true
            created.appearance = NSAppearance(named: .aqua)
            created.backgroundColor = NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 1)
            created.contentView = NSHostingView(rootView: DesktopWorkspaceDrawer(model: model))
            created.center()
            window = created
        }
        window?.title = section == .applications ? "应用 · bsideyou" : "文件盒 · bsideyou"
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if section == .applications { model.scanApplications() } else { model.refreshFiles() }
    }

    func close() { window?.orderOut(nil) }
    func shutdown() { model.cancel(); window?.close(); window = nil }
}

private final class DesktopDrawerWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class DesktopWorkspaceModel: ObservableObject {
    @Published var section: DesktopWorkspaceAction = .applications
    @Published var search = ""
    @Published private(set) var applications: [URL] = []
    @Published private(set) var files: [URL] = []
    @Published private(set) var currentFolder: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var preferences = DesktopWorkspacePreferences()
    var onOpened: () -> Void = {}
    private let storeURL: URL
    private var storeWritable = true
    private var storageFailure: String?
    private var access: DirectoryAccessLease?
    private var root: URL?
    private var rootIdentity: DirectoryIdentitySnapshot?
    private var generation = 0

    init(storeURL: URL) {
        self.storeURL = storeURL
        do { preferences = try DesktopWorkspacePreferences.load(from: storeURL) }
        catch {
            storeWritable = false
            storageFailure = DesktopWorkspaceFileError.unsupportedStore.localizedDescription
            self.error = storageFailure
        }
        if let bookmark = preferences.folderBookmark {
            do {
                let restored = try DirectoryAccessLease.resolvePersistent(bookmark)
                install(restored.lease)
                // Bookmark renewal stays in this preview document; it never changes media roots.
                if let renewed = restored.renewedData {
                    preferences.folderBookmark = renewed
                    preferences.folderPath = restored.lease.url.path
                    persist()
                }
            } catch { self.error = "无法恢复文件盒，请重新选择文件夹。\(error.localizedDescription)" }
        }
    }

    var filteredApplications: [URL] {
        applications.filter { matches($0) }.sorted {
            let left = preferences.pinnedApplications.contains($0.path)
            let right = preferences.pinnedApplications.contains($1.path)
            if left != right { return left }
            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
    var filteredFiles: [URL] { files.filter { matches($0) } }
    var canGoBack: Bool { currentFolder != nil && currentFolder?.path != root?.path }

    private func matches(_ url: URL) -> Bool {
        search.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(search)
    }

    func scanApplications() {
        generation += 1
        let token = generation
        isLoading = true
        let roots = ["/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [String: URL] = [:]
            var readableRoots = 0
            for path in roots {
                guard let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                readableRoots += 1
                for url in entries.prefix(1000) where url.pathExtension.lowercased() == "app" {
                    found[url.standardizedFileURL.path] = url
                }
            }
            let result = Array(found.values)
            let failed = readableRoots == 0
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.isLoading = false
                self.applications = result
                if failed { self.error = "无法读取应用文件夹。" }
            }
        }
    }

    func togglePin(_ url: URL) {
        guard applications.contains(url) else { return }
        if preferences.pinnedApplications.contains(url.path) {
            preferences.pinnedApplications.removeAll { $0 == url.path }
        } else { preferences.pinnedApplications.append(url.path) }
        persist()
    }

    func openApplication(_ url: URL) {
        guard applications.contains(url) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, failure in
            DispatchQueue.main.async {
                if let failure { self?.error = failure.localizedDescription }
                else { self?.onOpened() }
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择放入文件盒的文件夹"
        panel.prompt = "选择文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let currentFolder { panel.directoryURL = currentFolder }
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                let selected = try DirectoryAccessLease.fromSelectedURL(url)
                _ = try DesktopWorkspaceFiles.children(of: selected.lease.url, within: selected.lease.url)
                self.install(selected.lease)
                self.preferences.folderPath = url.path
                self.preferences.folderBookmark = selected.persistentData
                self.error = nil
                self.persist()
                self.refreshFiles()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func install(_ lease: DirectoryAccessLease) {
        access = lease
        root = lease.url.resolvingSymlinksInPath().standardizedFileURL
        rootIdentity = lease.identitySnapshot(provenance: .explicitSelection)
        currentFolder = root
    }

    private func checkRoot() throws -> URL {
        guard let root, let access else { throw DesktopWorkspaceFileError.notDirectory }
        if let previous = rootIdentity {
            guard let fresh = access.identitySnapshot(provenance: .explicitSelection) else {
                throw DesktopWorkspaceFileError.notDirectory
            }
            if case .conflict = previous.comparison(with: fresh) { throw DesktopWorkspaceFileError.notDirectory }
            // Within one process, a known inode must remain the same even on a volume that
            // does not advertise persistent IDs across restarts.
            if let inode = previous.inode, fresh.inode != inode { throw DesktopWorkspaceFileError.notDirectory }
        }
        return root
    }

    func refreshFiles() {
        generation += 1
        let token = generation
        files = []
        guard let currentFolder, let access else { isLoading = false; return }
        do {
            let root = try checkRoot()
            isLoading = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self, access] in
                let result = Result { try withExtendedLifetime(access) { try DesktopWorkspaceFiles.children(of: currentFolder, within: root) } }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.isLoading = false
                    switch result {
                    case .success(let listing):
                        self.files = listing.entries
                        self.notice = listing.isTruncated ? "此文件夹仅显示前 1000 项。" : nil
                        self.error = self.storageFailure
                    case .failure(let failure): self.files = []; self.error = failure.localizedDescription
                    }
                }
            }
        } catch { files = []; isLoading = false; self.error = error.localizedDescription }
    }

    func openFile(_ url: URL) {
        do {
            let valid = try DesktopWorkspaceFiles.validatedURL(url, within: checkRoot())
            let values = try valid.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values.isDirectory == true && values.isPackage != true {
                currentFolder = valid
                search = ""
                refreshFiles()
            } else if NSWorkspace.shared.open(valid) { onOpened() }
            else { error = "无法打开这个文件。" }
        } catch { self.error = error.localizedDescription }
    }

    func reveal(_ url: URL) {
        do {
            let valid = try DesktopWorkspaceFiles.validatedURL(url, within: checkRoot())
            NSWorkspace.shared.activateFileViewerSelecting([valid])
            onOpened()
        } catch { self.error = error.localizedDescription }
    }

    func goBack() {
        guard canGoBack, let currentFolder else { return }
        do {
            self.currentFolder = try DesktopWorkspaceFiles.validatedURL(currentFolder.deletingLastPathComponent(), within: checkRoot())
            search = ""
            refreshFiles()
        } catch { self.error = error.localizedDescription }
    }

    private func persist() {
        guard storeWritable else { error = DesktopWorkspaceFileError.unsupportedStore.localizedDescription; return }
        do {
            try preferences.save(to: storeURL)
            storageFailure = nil
        } catch {
            storageFailure = "文件盒设置尚未保存：\(error.localizedDescription)"
            self.error = storageFailure
        }
    }

    func cancel() { generation += 1; access = nil; files = []; isLoading = false }
}

private struct DesktopWorkspaceDrawer: View {
    @ObservedObject var model: DesktopWorkspaceModel
    private var isApps: Bool { model.section == .applications }
    private let ink = Color(red: 0.12, green: 0.13, blue: 0.13)
    private let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    private let orange = Color(red: 0.91, green: 0.34, blue: 0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        Rectangle().fill(orange).frame(width: 6, height: 6)
                        Text(isApps ? "APPLICATIONS" : "FILE BOX")
                            .font(.system(size: 9, weight: .semibold)).tracking(1.7)
                    }
                    Text(isApps ? "应用" : (model.currentFolder?.lastPathComponent ?? "文件盒"))
                        .font(.system(size: 28, weight: .semibold)).tracking(-0.7).lineLimit(1)
                }
                Spacer(minLength: 8)
                if isApps {
                    Button { model.scanApplications() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                    }.help("刷新应用").accessibilityLabel("刷新应用")
                } else { Button("选择文件夹…") { model.chooseFolder() } }
            }
            Rectangle().fill(ink.opacity(0.75)).frame(height: 1)
            if !isApps, let folder = model.currentFolder {
                HStack(spacing: 10) {
                    Button { model.goBack() } label: {
                        Image(systemName: "chevron.left").frame(width: 16, height: 16)
                    }.disabled(!model.canGoBack).help("返回上层").accessibilityLabel("返回上层")
                    Text(folder.path).font(.system(size: 11)).foregroundColor(ink.opacity(0.6))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { model.refreshFiles() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                    }.help("刷新文件").accessibilityLabel("刷新文件")
                }
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(ink.opacity(0.55))
                TextField(isApps ? "搜索应用名称" : "搜索当前文件夹", text: $model.search)
                    .textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(Color.white.opacity(0.6))
            .overlay(Rectangle().stroke(ink.opacity(0.28), lineWidth: 1))
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundColor(.red).textSelection(.enabled) }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundColor(ink.opacity(0.6)) }
            if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
            if !isApps && model.currentFolder == nil {
                VStack(spacing: 16) {
                    Image(systemName: "folder").font(.system(size: 38, weight: .light))
                    Text("选择一个文件夹").font(.system(size: 18, weight: .medium))
                    Text("仅浏览与打开，原文件保持原位。").font(.system(size: 12)).foregroundColor(ink.opacity(0.6))
                    Button("选择文件夹…") { model.chooseFolder() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(isApps ? model.filteredApplications : model.filteredFiles, id: \.path) { url in
                            HStack(spacing: 10) {
                                Button { isApps ? model.openApplication(url) : model.openFile(url) } label: {
                                    HStack(spacing: 13) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
                                        Text(isApps ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent)
                                            .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 11).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if isApps {
                                    Button { model.togglePin(url) } label: {
                                        Image(systemName: model.preferences.pinnedApplications.contains(url.path) ? "pin.fill" : "pin")
                                            .foregroundColor(model.preferences.pinnedApplications.contains(url.path) ? orange : ink.opacity(0.45))
                                            .frame(width: 28, height: 34).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help("置顶或取消置顶").accessibilityLabel("置顶或取消置顶")
                                } else {
                                    Button { model.reveal(url) } label: {
                                        Image(systemName: "folder").foregroundColor(ink.opacity(0.55))
                                            .frame(width: 28, height: 34).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示")
                                }
                            }
                            .padding(.horizontal, 10)
                            .modifier(DesktopDrawerRowFeedback())
                            .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.12)).frame(height: 1) }
                        }
                        if !model.isLoading && (isApps ? model.filteredApplications.isEmpty : model.filteredFiles.isEmpty) {
                            Text(model.search.isEmpty ? "这里暂无内容" : "没有匹配的名称")
                                .font(.system(size: 13)).foregroundColor(ink.opacity(0.6)).padding(30)
                        }
                    }
                }
            }
            Rectangle().fill(ink.opacity(0.3)).frame(height: 1)
            HStack {
                Text(isApps ? "本机应用" : "本机文件")
                Spacer()
                Text("ESC 关闭").tracking(0.7)
            }.font(.system(size: 9, weight: .medium)).foregroundColor(ink.opacity(0.55))
        }
        .buttonStyle(DesktopDrawerButtonStyle())
        .foregroundColor(ink)
        .tint(ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paper)
        .environment(\.colorScheme, .light)
    }
}

private struct DesktopDrawerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(configuration.isPressed ? 0.1 : 0.025))
            .overlay(Rectangle().stroke(Color.black.opacity(0.24), lineWidth: 1))
    }
}

private struct DesktopDrawerRowFeedback: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.background(Color.white.opacity(hovered ? 0.8 : 0.22))
            .onHover { hovered = $0 }
    }
}
