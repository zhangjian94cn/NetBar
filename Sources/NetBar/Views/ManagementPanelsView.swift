import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ManagementPanelsCard: View {
    @ObservedObject var store: ManagementPanelsStore
    var body: some View {
        PopoverCard(icon: "rectangle.grid.2x2", title: "管理面板") {
            Button("管理") { ManagementPanelsWindowController.shared.show(store: store) }
                .buttonStyle(.plain).foregroundColor(.accentColor)
                .help("添加面板与管理登录信息")
        } content: {
            VStack(alignment: .leading, spacing: 9) {
                if store.busy && !store.loaded { Text("正在读取钥匙串…").foregroundColor(.secondary) }
                ForEach(store.panels) { panel in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(panel.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(panel.name)
                            Text(panel.access.title + " · " + panel.credentialsSummary)
                                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 2)
                        Button { ManagementPanelsWindowController.shared.show(store: store, panel: panel) } label: {
                            Image(systemName: "key.horizontal")
                        }.buttonStyle(.plain).foregroundColor(.secondary)
                            .accessibilityLabel("\(panel.name)登录信息").help("查看或编辑登录信息")
                        Button { store.open(panel) } label: {
                            Label(store.openingID == panel.id ? "连接中" : "打开", systemImage: "arrow.up.right")
                        }.buttonStyle(.plain).foregroundColor(.accentColor)
                            .disabled(store.openingID != nil).accessibilityLabel("打开\(panel.name)")
                    }
                    if panel.id != store.panels.last?.id { Divider() }
                }
                if store.loaded && store.panels.isEmpty { Text("添加管理面板，随时打开查看状态。").foregroundColor(.secondary) }
                if let message = store.message {
                    Text(message).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !store.loaded { Button("重新读取") { Task { await store.load() } } }
                }
            }
        }
        .task { await store.load() }
    }
}

final class ManagementPanelEditor: ObservableObject {
    @Published var draft = ManagementPanel()
    @Published var original: ManagementPanel?
    @Published var hasSelection = false
    @Published var showPassword = false
    @Published var feedback: String?
    var dirty: Bool { hasSelection && draft != original }
    func select(_ panel: ManagementPanel?) -> Bool {
        if dirty {
            let alert = NSAlert()
            alert.messageText = "放弃未保存的面板修改？"
            alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃修改")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        original = panel; draft = panel ?? ManagementPanel(); hasSelection = true; showPassword = false; feedback = nil
        return true
    }
    @MainActor func save(store: ManagementPanelsStore) async -> Bool {
        if let original, store.panels.first(where: { $0.id == original.id }) != original {
            feedback = PanelError.conflict.localizedDescription; return false
        }
        var candidate = store.panels
        if let i = candidate.firstIndex(where: { $0.id == draft.id }) { candidate[i] = draft }
        else { candidate.append(draft) }
        guard await store.save(candidate) else { feedback = store.message; return false }
        original = store.panels.first(where: { $0.id == draft.id }); draft = original ?? draft
        feedback = "已保存到系统钥匙串"; showPassword = false; return true
    }
}

struct ManagementPanelsView: View {
    @ObservedObject var store: ManagementPanelsStore
    @ObservedObject var editor: ManagementPanelEditor
    @State private var deleting: ManagementPanel?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("管理面板").font(.system(size: 16, weight: .semibold))
                    Text("快捷打开后台，登录信息仅保存在本机钥匙串。").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                Button("导入…") {
                    guard !editor.dirty else { editor.feedback = "请先保存或取消当前修改，再导入面板。"; return }
                    let picker = NSOpenPanel()
                    picker.allowedContentTypes = [.json]; picker.allowsMultipleSelection = false
                    picker.message = "选择本机面板记录。登录信息会存入系统钥匙串。"
                    if picker.runModal() == .OK, let url = picker.url {
                        do {
                            let data = try Data(contentsOf: url)
                            Task { await store.importRecord(data) }
                        } catch { store.message = "无法读取导入文件，请检查文件权限。" }
                    }
                }.disabled(store.busy || !store.loaded)
                Button { _ = editor.select(nil) } label: { Label("添加面板", systemImage: "plus") }.disabled(store.busy || !store.loaded)
            }.padding(18)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(store.panels) { panel in
                            Button { _ = editor.select(panel) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(panel.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(panel.credentialsSummary).font(.system(size: 10)).foregroundColor(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background(editor.hasSelection && editor.draft.id == panel.id ? Color.accentColor.opacity(0.1) : Color.clear)
                                    .cornerRadius(8)
                            }.buttonStyle(.plain).disabled(store.busy)
                        }
                    }.padding(10)
                }.frame(width: 190)
                Divider()
                if editor.hasSelection { form }
                else {
                    VStack(spacing: 12) {
                        Image(systemName: "key.horizontal").font(.system(size: 30)).foregroundColor(.secondary)
                        Text("选择一个面板，或添加新的入口").foregroundColor(.secondary)
                        if let message = store.message { Text(message).font(.system(size: 12)).foregroundColor(.orange) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.tint(.accentColor).frame(minWidth: 700, minHeight: 520)
        .task { await store.load() }
        .alert("删除这个面板？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                guard let target = deleting else { return }
                Task { @MainActor in
                    if await store.save(store.panels.filter { $0.id != target.id }) {
                        editor.hasSelection = false; editor.original = nil; editor.showPassword = false
                    } else { editor.feedback = store.message }
                    deleting = nil
                }
            }
        } message: { Text("将删除“\(deleting?.name ?? "")”的本机快捷入口及其登录信息。远端服务和原 VPS 监控配置保持原样。") }
    }
    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    field("名称") { TextField("面板名称", text: $editor.draft.name) }
                    field("面板地址") { TextField("https://…", text: $editor.draft.address) }
                    field("访问方式") {
                        Picker("访问方式", selection: $editor.draft.access) {
                            ForEach(ManagementPanel.Access.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().onChange(of: editor.draft.access) { access in
                            if access == .sub2apiBWG { editor.draft.address = "http://127.0.0.1:8080" }
                            if access == .sub2apiNKG { editor.draft.address = "http://127.0.0.1:8082" }
                        }
                    }
                    if editor.draft.access != .browser {
                        field("已有隧道入口脚本") { TextField("sub2api-tunnel.sh 的完整路径", text: $editor.draft.tunnelScript) }
                        Text("按需复用原服务的管理隧道。Lite 请先在终端建立隧道。").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Divider()
                    field("登录账号") {
                        HStack {
                            TextField("账号、邮箱或 VPS IP", text: $editor.draft.username)
                            Button("复制") { copy(editor.draft.username) }.disabled(editor.draft.username.isEmpty).accessibilityLabel("复制账号")
                        }
                    }
                    field("登录密码") {
                        HStack {
                            Group {
                                if editor.showPassword { TextField("密码", text: $editor.draft.password) }
                                else { SecureField("密码", text: $editor.draft.password) }
                            }
                            Button { editor.showPassword.toggle() } label: { Image(systemName: editor.showPassword ? "eye.slash" : "eye") }
                                .help(editor.showPassword ? "隐藏密码" : "显示密码").accessibilityLabel(editor.showPassword ? "隐藏密码" : "显示密码")
                            Button("复制") { copy(editor.draft.password) }.disabled(editor.draft.password.isEmpty).accessibilityLabel("复制密码")
                        }
                    }
                    Text("打开后由浏览器完成登录及验证码。凭据不会拼入链接；复制内容 30 秒后清理，期间复制的新内容会保留。").font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let feedback = editor.feedback { Text(feedback).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let message = store.message, message != editor.feedback { Text(message).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.textFieldStyle(.roundedBorder)
            }
            Divider()
            HStack {
                if let original = editor.original {
                    Button(role: .destructive) { deleting = original } label: { Image(systemName: "trash") }.help("删除面板").accessibilityLabel("删除面板")
                }
                Button("打开") { store.open(editor.draft) }.disabled(store.openingID != nil)
                Spacer()
                Button("取消修改") {
                    editor.draft = editor.original ?? ManagementPanel(); editor.hasSelection = editor.original != nil
                    editor.showPassword = false; editor.feedback = nil
                }.disabled(!editor.dirty)
                Button(store.busy ? "保存中…" : "保存") { Task { await editor.save(store: store) } }
                    .buttonStyle(.borderedProminent).disabled(!editor.dirty || store.busy)
            }
        }.padding(18).disabled(store.busy)
    }
    private func field<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12, weight: .medium)); content() }
    }
    private func copy(_ value: String) { CredentialClipboard.copy(value); editor.feedback = "已复制，30 秒后清理本次剪贴板内容" }
}

final class ManagementPanelsWindowController: NSObject, NSWindowDelegate {
    static let shared = ManagementPanelsWindowController()
    private var window: NSWindow?
    private let editor = ManagementPanelEditor()
    private weak var store: ManagementPanelsStore?
    func allowQuitting() -> Bool {
        guard !editor.dirty else {
            if let window { window.makeKeyAndOrderFront(nil); window.performClose(nil) }
            return !editor.dirty
        }
        return store?.busy != true
    }
    func windowDidResignKey(_ notification: Notification) { editor.showPassword = false }
    func show(store: ManagementPanelsStore, panel: ManagementPanel? = nil) {
        self.store = store
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ManagementPanelsView(store: store, editor: editor)))
            w.title = "NetBar 管理面板"; w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 720, height: 550)); w.minSize = NSSize(width: 700, height: 540)
            w.center(); w.setFrameAutosaveName("NetBarManagementPanelsWindow"); w.isReleasedWhenClosed = false; w.delegate = self
            window = w
        }
        if let panel { _ = editor.select(panel) }
        window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store?.busy != true else { return false }
        guard editor.dirty else { editor.showPassword = false; return true }
        let alert = NSAlert(); alert.messageText = "保存面板的修改？"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "放弃修改"); alert.addButton(withTitle: "继续编辑")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let store { Task { @MainActor in if await editor.save(store: store) { sender.close() } } }
            return false
        case .alertSecondButtonReturn:
            editor.draft = editor.original ?? ManagementPanel(); editor.hasSelection = editor.original != nil; editor.showPassword = false; return true
        default: return false
        }
    }
}
