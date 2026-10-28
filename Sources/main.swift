import Cocoa
import ApplicationServices
import UniformTypeIdentifiers
import CryptoKit

private let notificationCenterBundleID = "com.apple.notificationcenterui"

// MARK: - 配置

struct Rule: Codable {
    var app: String?
    var text: String?
    var sound: String
    var volume: Double?
}

struct Config: Codable {
    var fallback: String?
    var rules: [Rule]?
}

// MARK: - AX 工具

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
        return []
    }
    return (value as? [AXUIElement]) ?? []
}

private func collectText(_ element: AXUIElement, into result: inout [String]) {
    for attribute in [kAXValueAttribute, kAXTitleAttribute] {
        if let text = axString(element, attribute), !text.isEmpty, !result.contains(text) {
            result.append(text)
        }
    }
    for child in axChildren(element) {
        collectText(child, into: &result)
    }
}

/// 找出 AX 树里的通知横幅。Ventura 的结构：
/// AXWindow/AXSystemDialog -> AXGroup/AXHostingView -> AXScrollArea
///   -> AXOpaqueProviderGroup -> AXGroup/AXNotificationCenterBanner (desc = 应用名)
///        -> AXStaticText (标题 / 副标题 / 正文)
private func collectBanners(_ element: AXUIElement, into result: inout [(String, [String])]) {
    let role = axString(element, kAXRoleAttribute) ?? ""
    let subrole = axString(element, kAXSubroleAttribute) ?? ""
    if role == "AXGroup" && subrole == "AXNotificationCenterBanner" {
        let app = axString(element, kAXDescriptionAttribute) ?? ""
        var texts: [String] = []
        collectText(element, into: &texts)
        result.append((app, texts))
        return
    }
    for child in axChildren(element) {
        collectBanners(child, into: &result)
    }
}

// MARK: - AX 回调

private func notificationCenterCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let watcher = Unmanaged<Watcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handle(notification: notification as String, element: element)
}

// MARK: - 主程序

final class Watcher: NSObject, NSApplicationDelegate {
    private let configPath: String
    private let logPath: String
    private let lockPath: String
    private let soundsDir: String

    private var statusItem: NSStatusItem?
    private var observer: AXObserver?
    private var attachedPid: pid_t = 0
    private var config: Config?
    private var configModified: Date?
    private var recent: [String: Date] = [:]
    private var retryTimer: Timer?
    private var settingsWindow: NSWindow?
    private var rulePopups: [NSPopUpButton] = []
    private var allPopup: NSPopUpButton?

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        configPath = "\(home)/.config/notif-sound/rules.json"
        logPath = "\(home)/data/notif-sound/logs/notif.log"
        lockPath = "\(home)/data/notif-sound/notifsound.lock"
        soundsDir = "\(home)/data/notif-sound/sounds"
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ensureDirectories()
        guard acquireLock() else {
            log("another instance is already running; exiting")
            NSApp.terminate(nil)
            return
        }
        installMenu()
        loadConfig(force: true)
        log("started (pid \(ProcessInfo.processInfo.processIdentifier))")
        requestAccessibilityIfNeeded()
        attachIfPossible()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.attachIfPossible()
        }

        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showSettingsWindow()
            }
        }
    }

    // MARK: 生命周期 / 连接

    private func requestAccessibilityIfNeeded() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            log("accessibility permission missing")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func attachIfPossible() {
        guard AXIsProcessTrusted() else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterBundleID).first else {
            return
        }
        let pid = app.processIdentifier
        if observer != nil && attachedPid == pid { return }

        observer = nil
        let appElement = AXUIElementCreateApplication(pid)
        var newObserver: AXObserver?
        let error = AXObserverCreate(pid, notificationCenterCallback, &newObserver)
        guard error == .success, let observer = newObserver else {
            log("AXObserverCreate failed: \(error.rawValue)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let added = AXObserverAddNotification(
            observer,
            appElement,
            kAXWindowCreatedNotification as CFString,
            refcon
        )
        guard added == .success else {
            log("AXObserverAddNotification failed: \(added.rawValue)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        attachedPid = pid
        log("attached to NotificationCenter pid \(pid)")
    }

    func handle(notification: String, element: AXUIElement) {
        guard notification == (kAXWindowCreatedNotification as String) else { return }
        log("ax window created")
        scan(element, attempt: 0)
    }

    /// 横幅窗口刚创建时子节点可能还没填好，重试几次再放弃。
    private func scan(_ element: AXUIElement, attempt: Int) {
        var banners: [(String, [String])] = []
        collectBanners(element, into: &banners)
        if banners.isEmpty {
            if attempt < 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.scan(element, attempt: attempt + 1)
                }
            } else {
                log("window event without banner (attempt \(attempt))")
            }
            return
        }
        for (app, texts) in banners {
            process(app: app, texts: texts)
        }
    }

    // MARK: 通知处理

    private func process(app: String, texts: [String]) {
        let appName = app.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = texts.joined(separator: " ")
        guard !appName.isEmpty || !body.isEmpty else { return }

        let key = appName + "\u{1}" + body
        let now = Date()
        if let last = recent[key], now.timeIntervalSince(last) < 2 {
            return
        }
        recent[key] = now
        if recent.count > 300 {
            recent = recent.filter { now.timeIntervalSince($0.value) < 60 }
        }

        reloadConfigIfChanged()
        guard let config else {
            log("no config; app=\(appName) text=\(body)")
            return
        }

        var chosen: (sound: String, volume: Double?, source: String)?
        for rule in config.rules ?? [] {
            if let ruleApp = rule.app, !ruleApp.isEmpty,
               !appName.localizedCaseInsensitiveContains(ruleApp) {
                continue
            }
            if let ruleText = rule.text, !ruleText.isEmpty,
               !body.localizedCaseInsensitiveContains(ruleText) {
                continue
            }
            chosen = (rule.sound, rule.volume, rule.app ?? rule.text ?? "rule")
            break
        }
        if chosen == nil, let fallback = config.fallback, !fallback.isEmpty {
            chosen = (fallback, nil, "fallback")
        }
        guard let chosen else {
            log("skip app=\(appName) text=\(body)")
            return
        }

        play(sound: chosen.sound, volume: chosen.volume)
        log("play app=\(appName) rule=\(chosen.source) sound=\(chosen.sound) text=\(body)")
    }

    private func play(sound: String, volume: Double?) {
        guard let path = resolveSound(sound) else {
            log("sound not found: \(sound)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        if let volume {
            process.arguments = ["-v", String(volume), path]
        } else {
            process.arguments = [path]
        }
        do {
            try process.run()
        } catch {
            log("afplay failed: \(error.localizedDescription)")
        }
    }

    private func resolveSound(_ sound: String) -> String? {
        let fileManager = FileManager.default
        if sound.hasPrefix("/") {
            return fileManager.fileExists(atPath: sound) ? sound : nil
        }

        // 先找导入的声音目录：带扩展名按原名找，不带扩展名按常见音频后缀找。
        var candidates: [String] = []
        if sound.contains(".") {
            candidates.append(sound)
        } else {
            for ext in ["aiff", "wav", "mp3", "m4a", "caf"] {
                candidates.append("\(sound).\(ext)")
            }
        }
        for name in candidates {
            let path = "\(soundsDir)/\(name)"
            if fileManager.fileExists(atPath: path) { return path }
        }

        // 再退回系统声音。
        let system = "/System/Library/Sounds/\(sound).aiff"
        return fileManager.fileExists(atPath: system) ? system : nil
    }

    // MARK: 配置

    private func loadConfig(force: Bool) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: configPath) {
            writeDefaultConfig()
        }
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: configPath),
            let modified = attributes[.modificationDate] as? Date
        else { return }
        if !force, let current = configModified, current == modified { return }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let decoded = try JSONDecoder().decode(Config.self, from: data)
            config = decoded
            configModified = modified
            log("config loaded: \(decoded.rules?.count ?? 0) rules")
        } catch {
            log("config error: \(error.localizedDescription)")
        }
    }

    private func reloadConfigIfChanged() {
        loadConfig(force: false)
    }

    private func writeDefaultConfig() {
        let json = """
        {
          "fallback": "",
          "rules": [
            { "app": "微信", "sound": "Glass" },
            { "app": "邮件", "sound": "Hero" },
            { "app": "滴答清单", "sound": "Ping" },
            { "app": "kitty", "sound": "Pop" },
            { "app": "Claude", "sound": "Submarine" }
          ]
        }
        """
        try? json.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: 菜单

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🔔"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "重载配置", action: #selector(reloadConfigAction), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "打开配置", action: #selector(openConfigAction), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "打开日志", action: #selector(openLogAction), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "导入音频…", action: #selector(importSoundsAction), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "设置提示音…", action: #selector(showSettingsAction), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "打开声音目录", action: #selector(openSoundsAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "测试声音", action: #selector(testSoundAction), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "重新连接通知中心", action: #selector(reconnectAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q"))
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func reloadConfigAction() {
        loadConfig(force: true)
        log("config reloaded manually")
    }

    @objc private func openConfigAction() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc private func openLogAction() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func openSoundsAction() {
        NSWorkspace.shared.open(URL(fileURLWithPath: soundsDir))
    }

    // MARK: 音频导入 / 设置

    /// 复制进声音目录：按内容哈希去重；同路径直接复用；重名不同内容用 -2 后缀。
    @discardableResult
    private func copyIntoLibrary(_ url: URL) -> String? {
        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: soundsDir).appendingPathComponent(url.lastPathComponent)
        if url.standardizedFileURL == destination.standardizedFileURL {
            return destination.lastPathComponent
        }
        guard let hash = fileHash(url) else {
            log("import failed \(url.lastPathComponent): cannot read")
            return nil
        }
        if let existing = existingSound(withHash: hash) {
            log("dedupe: \(url.lastPathComponent) == \(existing)")
            return existing
        }

        var name = url.lastPathComponent
        var target = URL(fileURLWithPath: soundsDir).appendingPathComponent(name)
        var counter = 2
        while fileManager.fileExists(atPath: target.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            target = URL(fileURLWithPath: soundsDir).appendingPathComponent(name)
            counter += 1
        }
        do {
            try fileManager.copyItem(at: url, to: target)
            return name
        } catch {
            log("import failed \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private func fileHash(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func existingSound(withHash hash: String) -> String? {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: soundsDir) else { return nil }
        for name in names.sorted() where isAudioFile(name) {
            let path = "\(soundsDir)/\(name)"
            if fileHash(URL(fileURLWithPath: path)) == hash { return name }
        }
        return nil
    }

    private func isAudioFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["aiff", "aif", "wav", "mp3", "m4a", "caf", "flac"].contains(ext)
    }

    private func availableSounds() -> [String] {
        var names: [String] = []
        if let files = try? FileManager.default.contentsOfDirectory(atPath: soundsDir) {
            names.append(contentsOf: files.filter(isAudioFile).sorted())
        }
        if let system = try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds") {
            names.append(contentsOf: system
                .filter { $0.hasSuffix(".aiff") }
                .map { ($0 as NSString).deletingPathExtension }
                .sorted())
        }
        return names
    }

    @objc private func importSoundsAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        panel.message = "选择要复制到声音目录的音频"
        panel.prompt = "导入"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importFiles(panel.urls)
        }
    }

    private func importFiles(_ urls: [URL]) {
        var imported: [String] = []
        for url in urls {
            if let name = copyIntoLibrary(url) { imported.append(name) }
        }
        guard !imported.isEmpty else { return }
        log("imported: \(imported.joined(separator: ", "))")
        if settingsWindow != nil { refreshSettingsWindow() }
        showAlert(title: "已处理 \(imported.count) 个音频", message: imported.joined(separator: "\n"))
    }

    @objc private func showSettingsAction() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let config = readConfig(), let rules = config.rules else {
            showAlert(title: "读取配置失败", message: "~/.config/notif-sound/rules.json")
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotifSound · 设置提示音"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 560))
        window.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)
        ])

        let sounds = availableSounds()
        rulePopups = []

        for (index, rule) in rules.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8

            let label = NSTextField(labelWithString: rule.app ?? "(匹配所有通知)")
            label.widthAnchor.constraint(equalToConstant: 160).isActive = true

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: sounds)
            if !rule.sound.isEmpty {
                if popup.item(withTitle: rule.sound) == nil {
                    popup.addItem(withTitle: rule.sound)
                }
                popup.selectItem(withTitle: rule.sound)
            }
            popup.tag = index
            popup.target = self
            popup.action = #selector(ruleSoundChanged(_:))
            popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
            rulePopups.append(popup)

            let preview = NSButton(title: "▶", target: self, action: #selector(previewRuleSound(_:)))
            preview.bezelStyle = .rounded
            preview.tag = index

            row.addArrangedSubview(label)
            row.addArrangedSubview(popup)
            row.addArrangedSubview(preview)
            stack.addArrangedSubview(row)
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(divider)

        let allRow = NSStackView()
        allRow.orientation = .horizontal
        allRow.spacing = 8
        let allLabel = NSTextField(labelWithString: "全部设为")
        allLabel.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: sounds)
        popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        allPopup = popup
        let applyAll = NSButton(title: "应用到全部", target: self, action: #selector(applySoundToAll(_:)))
        applyAll.bezelStyle = .rounded
        allRow.addArrangedSubview(allLabel)
        allRow.addArrangedSubview(popup)
        allRow.addArrangedSubview(applyAll)
        stack.addArrangedSubview(allRow)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let refresh = NSButton(title: "刷新列表", target: self, action: #selector(refreshSettingsWindow))
        refresh.bezelStyle = .rounded
        let close = NSButton(title: "关闭", target: self, action: #selector(closeSettingsWindow))
        close.bezelStyle = .rounded
        buttons.addArrangedSubview(refresh)
        buttons.addArrangedSubview(close)
        stack.addArrangedSubview(buttons)

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func ruleSoundChanged(_ sender: NSPopUpButton) {
        guard let sound = sender.titleOfSelectedItem else { return }
        guard var config = readConfig(), var rules = config.rules, sender.tag < rules.count else { return }
        rules[sender.tag].sound = sound
        config.rules = rules
        writeConfig(config)
        loadConfig(force: true)
        log("settings: rule \(rules[sender.tag].app ?? "(any)") -> \(sound)")
    }

    @objc private func previewRuleSound(_ sender: NSButton) {
        guard let config = readConfig(), let rules = config.rules, sender.tag < rules.count else { return }
        play(sound: rules[sender.tag].sound, volume: rules[sender.tag].volume)
    }

    @objc private func applySoundToAll(_ sender: Any?) {
        guard let sound = allPopup?.titleOfSelectedItem, !sound.isEmpty else { return }
        guard var config = readConfig(), var rules = config.rules else { return }
        for index in rules.indices { rules[index].sound = sound }
        config.rules = rules
        writeConfig(config)
        loadConfig(force: true)
        for popup in rulePopups {
            if popup.item(withTitle: sound) == nil { popup.addItem(withTitle: sound) }
            popup.selectItem(withTitle: sound)
        }
        log("settings: applied \(sound) to all rules")
    }

    @objc private func refreshSettingsWindow() {
        settingsWindow?.close()
        settingsWindow = nil
        rulePopups = []
        allPopup = nil
        showSettingsWindow()
    }

    @objc private func closeSettingsWindow() {
        settingsWindow?.close()
        settingsWindow = nil
        rulePopups = []
        allPopup = nil
    }

    /// 命令行模式：NotifSound --set-sound <文件> <应用名>
    func assignFromCLI(filePath: String, app: String) -> Bool {
        ensureDirectories()
        let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("file not found: \(filePath)\n".utf8))
            return false
        }
        guard let name = copyIntoLibrary(url) else { return false }
        guard var config = readConfig() else { return false }
        var rules = config.rules ?? []
        var updated = false
        for index in rules.indices {
            if let ruleApp = rules[index].app,
               ruleApp.caseInsensitiveCompare(app) == .orderedSame {
                rules[index].sound = name
                updated = true
            }
        }
        if !updated { rules.append(Rule(app: app, text: nil, sound: name, volume: nil)) }
        config.rules = rules
        writeConfig(config)
        log("cli assigned sound=\(name) to=\(app)")
        return true
    }

    private func readConfig() -> Config? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    private func writeConfig(_ config: Config) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func testSoundAction() {
        play(sound: "Glass", volume: nil)
        log("test sound")
    }

    @objc private func reconnectAction() {
        observer = nil
        attachedPid = 0
        attachIfPossible()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    @objc private func workspaceApplicationLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == notificationCenterBundleID {
            attachIfPossible()
        }
    }

    @objc private func workspaceApplicationTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == notificationCenterBundleID {
            observer = nil
            attachedPid = 0
        }
    }

    // MARK: 工具

    private func ensureDirectories() {
        let fileManager = FileManager.default
        for directory in [
            (configPath as NSString).deletingLastPathComponent,
            (logPath as NSString).deletingLastPathComponent,
            soundsDir
        ] {
            try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }

    /// 简单单实例：同一时间只允许一个 watcher，避免重复播放。
    private func acquireLock() -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: lockPath) {
            if let contents = try? String(contentsOfFile: lockPath, encoding: .utf8),
               let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(pid, 0) == 0 {
                return false
            }
        }

        try? String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: lockPath,
            atomically: true,
            encoding: .utf8
        )
        return true
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}

extension Watcher: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        settingsWindow = nil
        rulePopups = []
        allPopup = nil
    }
}

// MARK: - 入口

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "--set-sound" {
    let watcher = Watcher()
    exit(watcher.assignFromCLI(filePath: arguments[2], app: arguments[3]) ? 0 : 1)
}

let application = NSApplication.shared
let watcher = Watcher()
application.delegate = watcher
application.run()
