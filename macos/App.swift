import AppKit

final class Channel {
    let id: Int, oldNumber: Int
    var number: Int
    let name: String, source: String, deleted: Bool
    init(_ j: [String: Any]) {
        id = j["id"] as! Int; number = j["number"] as! Int; oldNumber = j["oldNumber"] as! Int
        name = j["name"] as? String ?? ""; source = j["source"] as? String ?? ""; deleted = j["deleted"] as? Bool ?? false
    }
    var active: Bool { !deleted && oldNumber >= 0 }
    var json: [String: Any] { ["id": id, "number": number] }
}
final class ChannelList {
    let id: Int, name: String, readOnly: Bool
    var channels: [Channel]
    init(_ j: [String: Any]) {
        id = j["id"] as! Int; name = j["name"] as? String ?? "List"; readOnly = j["readOnly"] as? Bool ?? false
        channels = (j["channels"] as! [[String: Any]]).map(Channel.init)
    }
    var ordered: [Channel] { channels.sorted { ($0.active ? $0.number : Int.max, $0.id) < ($1.active ? $1.number : Int.max, $1.id) } }
    var json: [String: Any] { ["id": id, "channels": channels.map(\.json)] }
}
final class EngineClient {
    let process = Process(), input = Pipe(), output = Pipe()
    let queue = DispatchQueue(label: "ChanSort.Engine")
    let root: URL
    var pending = Data()
    init(root: URL) throws {
        self.root = root
        let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Engine/ChanSort.Engine")
        process.executableURL = exe; process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["CHANSORT_HOME"] = root.path; env["TMPDIR"] = root.appendingPathComponent("tmp").path
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"; env["DOTNET_EnableDiagnostics"] = "0"
        process.environment = env; process.standardInput = input; process.standardOutput = output
        let log = root.appendingPathComponent("logs/engine.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
        try process.run()
    }
    func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func read() throws -> [String: Any] {
        while true {
            if let end = pending.firstIndex(of: 10) {
                let line = pending[..<end]; pending.removeSubrange(...end)
                return try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
            }
            let next = output.fileHandleForReading.availableData
            guard !next.isEmpty else {
                throw NSError(domain: "ChanSort", code: 1, userInfo: [NSLocalizedDescriptionKey: "The engine stopped. See logs/engine.log."])
            }
            pending.append(next)
        }
    }
    func request(_ object: [String: Any], done: @escaping ([String: Any]) -> Void) {
        queue.async {
            do {
                try self.write(object)
                while true {
                    let result = try self.read()
                    if result["type"] as? String == "prompt" {
                        var choice = 0
                        DispatchQueue.main.sync {
                            let alert = NSAlert(); alert.messageText = result["title"] as? String ?? "ChanSort"
                            alert.informativeText = result["message"] as? String ?? ""
                            let actions = result["actions"] as? [[String: Any]] ?? []
                            for action in actions { alert.addButton(withTitle: action["text"] as? String ?? "OK") }
                            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                            choice = actions.indices.contains(index) ? actions[index]["result"] as? Int ?? 0 : 0
                        }
                        try self.write(["result": choice]); continue
                    }
                    DispatchQueue.main.async { done(result) }; return
                }
            } catch { DispatchQueue.main.async { done(["type": "error", "message": error.localizedDescription]) } }
        }
    }
    func stop() { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() } }
}
final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    var window: NSWindow!
    let table = NSTableView(), listPicker = NSPopUpButton(), search = NSSearchField()
    let status = NSTextField(labelWithString: "Open a TV channel export to begin."), fileLabel = NSTextField(labelWithString: "No export open")
    var buttons: [NSButton] = [], engine: EngineClient?, lists: [ChannelList] = [], visible: [Channel] = []
    var dirty = false, busy = false, currentPath = ""
    let root = Bundle.main.bundleURL.deletingLastPathComponent()
    var selectedList: ChannelList? { lists.indices.contains(listPicker.indexOfSelectedItem) ? lists[listPicker.indexOfSelectedItem] : nil }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
        for dir in ["tmp", "logs", "backups"] { try? FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1050,height: 720), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "ChanSort — macOS"; window.minSize = NSSize(width: 800,height: 480); window.center(); window.delegate = self
        let content = window.contentView!
        let open = button("Open export…", #selector(openFile)); open.keyEquivalent = "o"
        let save = button("Save with backup", #selector(saveFile)); save.keyEquivalent = "s"
        listPicker.target = self; listPicker.action = #selector(changeList); listPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.placeholderString = "Search channel name"; search.delegate = self; search.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let top = NSStackView(views: [open, save, listPicker, search]); top.spacing = 12
        let actions = NSStackView(views: [button("↑ Up", #selector(moveUp)), button("↓ Down", #selector(moveDown)), button("Move to top", #selector(moveTop)), button("Move to bottom", #selector(moveBottom)), button("Sort A–Z", #selector(sortNames)), button("Renumber from 1", #selector(renumber))]); actions.spacing = 8
        fileLabel.font = .systemFont(ofSize: 12); fileLabel.textColor = .secondaryLabelColor; fileLabel.lineBreakMode = .byTruncatingMiddle
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        for (id,title,width) in [("number","Number",90.0),("old","Original",90.0),("name","Channel name",420.0),("source","Source",300.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.isEditable = id == "number"
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 25
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let hint = NSTextField(labelWithString: "Double-click a number to move a channel. Occupied numbers are swapped. Backups stay in this folder.")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let stack = NSStackView(views: [top, fileLabel, actions, scroll, hint, status]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 18),stack.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -18),stack.topAnchor.constraint(equalTo: content.topAnchor,constant: 18),stack.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant: -16),top.widthAnchor.constraint(equalTo: stack.widthAnchor),scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        do { engine = try EngineClient(root: root) } catch { showError(error.localizedDescription) }
        refresh()
        if let index = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.count > index+1 { load(CommandLine.arguments[index+1]) }
    }
    func makeMenu() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem); let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit ChanSort", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Cut",action: #selector(NSText.cut(_:)),keyEquivalent: "x"); edit.addItem(withTitle: "Copy",action: #selector(NSText.copy(_:)),keyEquivalent: "c"); edit.addItem(withTitle: "Paste",action: #selector(NSText.paste(_:)),keyEquivalent: "v"); edit.addItem(withTitle: "Select All",action: #selector(NSText.selectAll(_:)),keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
    func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title,target: self,action: action); b.bezelStyle = .rounded; buttons.append(b); return b }
    func refresh() {
        let query = search.stringValue
        visible = selectedList?.ordered.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } ?? []
        table.reloadData()
        listPicker.isEnabled = !busy; search.isEnabled = !busy
        for (i,b) in buttons.enumerated() { b.isEnabled = !busy && (i == 0 || (selectedList != nil && selectedList?.readOnly == false)) }
        window.isDocumentEdited = dirty
        if !busy { status.stringValue = selectedList.map { "\(visible.count) of \($0.channels.count) channels\($0.readOnly ? " • read only" : "")\(dirty ? " • unsaved changes" : "")" } ?? "Open a TV channel export to begin." }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let c = visible[row]
        switch tableColumn?.identifier.rawValue { case "number": return c.number < 0 ? "—" : String(c.number); case "old": return c.oldNumber < 0 ? "—" : String(c.oldNumber); case "name": return c.name + (c.deleted ? " [deleted]" : ""); default: return c.source }
    }
    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { !busy && selectedList?.readOnly == false && visible[row].active && tableColumn?.identifier.rawValue == "number" }
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let nr = Int("\(object ?? "")"), nr >= 0, nr <= 65534, let list = selectedList else { NSSound.beep(); return }
        let c = visible[row]; if nr == c.number { return }
        if let other = list.channels.first(where: { $0.active && $0.number == nr }) { other.number = c.number }
        c.number = nr; dirty = true; refresh(); select(c)
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    @objc func changeList() { refresh() }
    func confirmDiscard() -> Bool {
        guard dirty else { return true }; let a = NSAlert(); a.messageText = "Discard unsaved changes?"; a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Discard"); return a.runModal() == .alertSecondButtonReturn
    }
    @objc func openFile() {
        guard !busy, confirmDiscard() else { return }; let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.title = "Open TV channel export"
        if panel.runModal() == .OK, let url = panel.url { load(url.path) }
    }
    func load(_ path: String) {
        guard let engine else { return }; busy = true; status.stringValue = "Reading export…"; refresh()
        engine.request(["command":"load", "path":path]) { j in
            self.busy = false
            if j["type"] as? String == "loaded" {
                self.lists = (j["lists"] as? [[String: Any]] ?? []).map(ChannelList.init); self.listPicker.removeAllItems(); self.listPicker.addItems(withTitles: self.lists.map(\.name)); self.dirty = false; self.currentPath = path; self.fileLabel.stringValue = path
                if let warning = j["warnings"] as? String, !warning.isEmpty { self.showMessage("Export warnings", warning) }
            } else { self.lists = []; self.listPicker.removeAllItems(); self.currentPath = ""; self.fileLabel.stringValue = "No export open"; self.showError(j["message"] as? String ?? "Unable to open export") }
            self.refresh()
        }
    }
    func select(_ channel: Channel) { if let row = visible.firstIndex(where: { $0 === channel }) { table.selectRowIndexes(IndexSet(integer: row),byExtendingSelection: false); table.scrollRowToVisible(row) } }
    func move(_ destination: (Int,Int)->Int) {
        guard !busy, let list = selectedList, !list.readOnly, visible.indices.contains(table.selectedRow) else { return }
        let c = visible[table.selectedRow]; guard c.active else { return }
        var ordered = list.ordered.filter(\.active); guard let index = ordered.firstIndex(where: { $0 === c }) else { return }
        let target = max(0,min(ordered.count-1,destination(index,ordered.count))); guard target != index else { return }
        let numbers = ordered.map(\.number); ordered.remove(at: index); ordered.insert(c,at: target)
        for (i,item) in ordered.enumerated() { item.number = numbers[i] }; dirty = true; refresh(); select(c)
    }
    @objc func moveUp() { move { i,_ in i-1 } }
    @objc func moveDown() { move { i,_ in i+1 } }
    @objc func moveTop() { move { _,_ in 0 } }
    @objc func moveBottom() { move { _,count in count-1 } }
    @objc func sortNames() {
        guard !busy, let list = selectedList, !list.readOnly else { return }
        let ordered = list.ordered.filter(\.active); let numbers = ordered.map(\.number)
        let sorted = ordered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for (i,c) in sorted.enumerated() { c.number = numbers[i] }; dirty = true; refresh()
    }
    @objc func renumber() {
        guard !busy, let list = selectedList, !list.readOnly else { return }
        for (i,c) in list.ordered.filter(\.active).enumerated() { c.number = i+1 }; dirty = true; refresh()
    }
    @objc func saveFile() {
        guard !busy, !lists.isEmpty, let engine else { return }; window.makeFirstResponder(nil)
        let alert = NSAlert(); alert.messageText = "Save channel order?"; alert.informativeText = "The selected export will be updated. A backup of the source files will be saved in:\n\(root.appendingPathComponent("backups").path)"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; status.stringValue = "Backing up and saving…"; refresh()
        engine.request(["command":"save", "lists":lists.map(\.json)]) { j in
            self.busy = false
            if j["type"] as? String == "saved" { self.dirty = false; self.showMessage("Export saved", "Backup: \(j["backup"] as? String ?? "")") } else { self.showError(j["message"] as? String ?? "Save failed") }
            self.refresh()
        }
    }
    func showError(_ message: String) { showMessage("ChanSort",message) }
    func showMessage(_ title: String, _ message: String) { let a = NSAlert(); a.messageText = title; a.informativeText = message; a.addButton(withTitle: "OK"); a.runModal() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy && confirmDiscard() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { !busy && confirmDiscard() ? .terminateNow : .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { engine?.stop() }
}
let app = NSApplication.shared
let delegate = App()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
