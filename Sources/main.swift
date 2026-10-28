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

/// 规则窗口的内容视图：只做一件事——接受 first responder，好让窗口打开时
/// 焦点落在空白处而不是第一条规则的输入框上（否则一进去文字就是选中态，误触即改）。
private final class FocusSinkView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
}

final class Watcher: NSObject, NSApplicationDelegate {
    private let home: String
    private let rootDir: String
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
    private var lastPreviewSound: String?
    private var settingsWindow: NSWindow?
    private var settingsColumn: NSStackView?
    private var ruleRowsStack: NSStackView?
    private var rulePopups: [NSPopUpButton] = []
    private var volumeLabels: [Int: NSTextField] = [:]
    private var allPopup: NSPopUpButton?
    private var didMigrateLegacy = false

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = "\(home)/Library/Application Support/NotifSound"
        self.home = home
        rootDir = root
        configPath = "\(root)/rules.json"
        logPath = "\(root)/logs/notif.log"
        lockPath = "\(root)/notifsound.lock"
        soundsDir = "\(root)/sounds"
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
        installShortcuts()
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
            log("no config; app=\(appName)")
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
            log("skip app=\(appName)")
            return
        }

        play(sound: chosen.sound, volume: chosen.volume)
        log("play app=\(appName) rule=\(chosen.source) sound=\(chosen.sound)")
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
        menu.addItem(NSMenuItem(title: "规则设置…", action: #selector(showSettingsAction), keyEquivalent: "s"))
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

    /// LSUIElement 应用没有主菜单，`cmd+w` 的系统菜单快捷键不会生效，
    /// 直接在本地事件里截住 `cmd+w`，关掉当前窗口。
    private func installShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "w",
                  let window = NSApp.keyWindow else { return event }
            window.performClose(nil)
            return nil
        }
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
            showAlert(title: "读取配置失败", message: configPath)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotifSound · 规则"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = FocusSinkView(frame: NSRect(x: 0, y: 0, width: 780, height: 480))
        window.contentView = content
        // 别让第一个规则行的输入框自动成为 first responder：窗口一开就进编辑态，
        // 提交出来的空串会把那条规则的应用名抹掉。
        window.initialFirstResponder = content

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)
        ])
        settingsColumn = column

        let sounds = availableSounds()
        rulePopups = []
        volumeLabels = [:]

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        for (title, width) in [("应用（横幅里的名字）", 140.0), ("关键词", 120.0), ("声音", 210.0), ("音量", 128.0)] {
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
            header.addArrangedSubview(label)
        }
        column.addArrangedSubview(header)

        let ruleRows = NSStackView()
        ruleRows.orientation = .vertical
        ruleRows.alignment = .leading
        ruleRows.spacing = 8
        ruleRowsStack = ruleRows
        column.addArrangedSubview(ruleRows)

        for (index, rule) in rules.enumerated() {
            ruleRows.addArrangedSubview(makeRuleRow(rule, index: index, sounds: sounds))
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 740).isActive = true
        column.addArrangedSubview(divider)

        let allRow = NSStackView()
        allRow.orientation = .horizontal
        allRow.spacing = 8
        let addButton = NSButton(title: "＋ 新增规则", target: self, action: #selector(addRulePressed(_:)))
        addButton.bezelStyle = .rounded
        let allLabel = NSTextField(labelWithString: "全部设为")
        allLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: sounds)
        popup.widthAnchor.constraint(equalToConstant: 210).isActive = true
        allPopup = popup
        let applyAll = NSButton(title: "应用到全部", target: self, action: #selector(applySoundToAll(_:)))
        applyAll.bezelStyle = .rounded
        allRow.addArrangedSubview(addButton)
        allRow.addArrangedSubview(allLabel)
        allRow.addArrangedSubview(popup)
        allRow.addArrangedSubview(applyAll)
        column.addArrangedSubview(allRow)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let refresh = NSButton(title: "重新读取配置", target: self, action: #selector(refreshSettingsWindow))
        refresh.bezelStyle = .rounded
        let reveal = NSButton(title: "在 Finder 中显示配置", target: self, action: #selector(showConfigInFinder))
        reveal.bezelStyle = .rounded
        let close = NSButton(title: "关闭", target: self, action: #selector(closeSettingsWindow))
        close.bezelStyle = .rounded
        buttons.addArrangedSubview(refresh)
        buttons.addArrangedSubview(reveal)
        buttons.addArrangedSubview(close)
        column.addArrangedSubview(buttons)

        settingsWindow = window
        resizeSettingsWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(content)
    }

    /// 一条规则一行：应用名 / 关键词 / 声音 / 音量 / 试听 / 删除。
    /// 行内的 tag 是规则下标，增删后整段重建，别手动攒下标。
    private func makeRuleRow(_ rule: Rule, index: Int, sounds: [String]) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let appField = NSTextField(string: rule.app ?? "")
        appField.placeholderString = "匹配所有通知"
        appField.tag = index
        appField.target = self
        appField.action = #selector(ruleAppChanged(_:))
        appField.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let textField = NSTextField(string: rule.text ?? "")
        textField.placeholderString = "关键词（可空）"
        textField.tag = index
        textField.target = self
        textField.action = #selector(ruleTextChanged(_:))
        textField.widthAnchor.constraint(equalToConstant: 120).isActive = true

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
        popup.widthAnchor.constraint(equalToConstant: 210).isActive = true
        rulePopups.append(popup)

        let volume = rule.volume ?? 1
        let slider = NSSlider(
            value: volume,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(ruleVolumeChanged(_:))
        )
        slider.isContinuous = false
        slider.tag = index
        slider.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let percent = NSTextField(labelWithString: "\(Int((volume * 100).rounded()))%")
        percent.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.widthAnchor.constraint(equalToConstant: 40).isActive = true
        volumeLabels[index] = percent

        let preview = NSButton(title: "▶", target: self, action: #selector(previewRuleSound(_:)))
        preview.bezelStyle = .rounded
        preview.tag = index

        let remove = NSButton(title: "✕", target: self, action: #selector(deleteRule(_:)))
        remove.bezelStyle = .rounded
        remove.tag = index

        row.addArrangedSubview(appField)
        row.addArrangedSubview(textField)
        row.addArrangedSubview(popup)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(percent)
        row.addArrangedSubview(preview)
        row.addArrangedSubview(remove)
        return row
    }

    private func rebuildRuleRows() {
        guard let ruleRows = ruleRowsStack, let config = readConfig(), let rules = config.rules else { return }
        for view in ruleRows.arrangedSubviews { view.removeFromSuperview() }
        rulePopups = []
        volumeLabels = [:]
        let sounds = availableSounds()
        for (index, rule) in rules.enumerated() {
            ruleRows.addArrangedSubview(makeRuleRow(rule, index: index, sounds: sounds))
        }
        resizeSettingsWindow()
    }

    private func resizeSettingsWindow() {
        guard let window = settingsWindow, let column = settingsColumn else { return }
        column.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 780, height: max(column.fittingSize.height + 40, 220)))
    }

    /// 新增规则：菜单里列出运行中的 App（横幅里的名字通常就是 localisedName），
    /// 也可以手输；已有的名字不重复添加。
    @objc private func addRulePressed(_ sender: NSButton) {
        let existing = Set((readConfig()?.rules ?? []).compactMap { $0.app?.lowercased() })
        let names = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .filter { !existing.contains($0.lowercased()) })

        let menu = NSMenu()
        for name in names.sorted() {
            let item = NSMenuItem(title: name, action: #selector(addRuleForApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "没有可添加的运行中 App", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "手动输入名称…", action: #selector(addRuleCustom(_:)), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func addRuleForApp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        appendRule(app: name)
    }

    @objc private func addRuleCustom(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "新增规则"
        alert.informativeText = "输入横幅里显示的应用名，和「系统设置 → 通知」里的名字一致。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "例如 微信 / kitty"
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        appendRule(app: name)
    }

    private func appendRule(app: String) {
        guard var config = readConfig() else { return }
        var rules = config.rules ?? []
        guard !rules.contains(where: { $0.app?.caseInsensitiveCompare(app) == .orderedSame }) else {
            showAlert(title: "规则已存在", message: "「\(app)」已经有一条规则了。")
            return
        }
        let sound = lastPreviewSound ?? rules.first?.sound ?? "Glass"
        rules.append(Rule(app: app, text: nil, sound: sound, volume: nil))
        config.rules = rules
        writeConfig(config)
        loadConfig(force: true)
        rebuildRuleRows()
        log("settings: added rule \(app) sound=\(sound)")
    }

    @objc private func deleteRule(_ sender: NSButton) {
        guard var config = readConfig(), var rules = config.rules, sender.tag < rules.count else { return }
        let removed = rules.remove(at: sender.tag)
        config.rules = rules
        writeConfig(config)
        loadConfig(force: true)
        rebuildRuleRows()
        log("settings: removed rule \(removed.app ?? "(any)")")
    }

    @objc private func ruleAppChanged(_ sender: NSTextField) {
        guard var config = readConfig(), var rules = config.rules, sender.tag < rules.count else { return }
        let name = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只是切走焦点、内容没变就不要写盘，否则空提交会悄悄改掉规则。
        guard name != (rules[sender.tag].app ?? "") else { return }
        rules[sender.tag].app = name.isEmpty ? nil : name
        config.rules = rules
        writeConfig(config)
        loadConfig(force: true)
        log("settings: rule \(sender.tag) app=\(name.isEmpty ? "(any)" : name)")
    }

    @objc private func ruleTextChanged(_ sender: NSTextField) {
        guard var config = readConfig(), var rules = config.rules, sender.tag < rules.count else { return }
        let keyword = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyword != (rules[sender.tag].text ?? "") else { return }
        rules[sender.tag].text = keyword.isEmpty ? nil : keyword
        config.rules = rules
        writeConfig(config)
        loadConfig(force: true)
        log("settings: rule \(sender.tag) text=\(keyword.isEmpty ? "(any)" : keyword)")
    }

    @objc private func ruleVolumeChanged(_ sender: NSSlider) {
        guard var config = readConfig(), var rules = config.rules, sender.tag < rules.count else { return }
        let value = sender.doubleValue
        let rounded = value >= 0.999 ? nil : (value * 100).rounded() / 100
        guard rounded != rules[sender.tag].volume else { return }
        // 满音量就写回 nil，配置文件里不出现没意义的 volume: 1。
        rules[sender.tag].volume = rounded
        config.rules = rules
        writeConfig(config)
        loadConfig(force: true)
        let shown = value >= 0.999 ? 1 : value
        volumeLabels[sender.tag]?.stringValue = "\(Int((shown * 100).rounded()))%"
        log("settings: rule \(sender.tag) volume=\(rules[sender.tag].volume.map { String(format: "%.2f", $0) } ?? "1.00")")
    }

    @objc private func showConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)])
    }

    @objc private func ruleSoundChanged(_ sender: NSPopUpButton) {
        guard let sound = sender.titleOfSelectedItem else { return }
        guard var config = readConfig(), var rules = config.rules, sender.tag < rules.count else { return }
        rules[sender.tag].sound = sound
        config.rules = rules
        writeConfig(config)
        loadConfig(force: true)
        lastPreviewSound = sound
        log("settings: rule \(rules[sender.tag].app ?? "(any)") -> \(sound)")
    }

    @objc private func previewRuleSound(_ sender: NSButton) {
        guard let config = readConfig(), let rules = config.rules, sender.tag < rules.count else { return }
        lastPreviewSound = rules[sender.tag].sound
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
        lastPreviewSound = sound
        log("settings: applied \(sound) to all rules")
    }

    @objc private func refreshSettingsWindow() {
        loadConfig(force: true)
        rebuildRuleRows()
    }

    @objc private func closeSettingsWindow() {
        settingsWindow?.close()
        settingsWindow = nil
        rulePopups = []
        volumeLabels = [:]
        allPopup = nil
    }

    /// 命令行模式：NotifSound --test-sound
    func testSoundFromCLI() -> String {
        ensureDirectories()
        let sound = readConfig()?.rules?.first?.sound ?? "Glass"
        play(sound: sound, volume: nil)
        log("test sound: \(sound)")
        return sound
    }

    /// 命令行模式：NotifSound --play <应用名>
    /// 给跑在终端里的 agent（Codex、Claude）用：横幅的应用名永远是终端，按应用名匹配不到，
    /// 所以由 agent 自己触发，直接取该应用的规则播放。带 text 条件的规则在命令行下跳过。
    func playFromCLI(app: String) -> Bool {
        ensureDirectories()
        guard let config = readConfig() else { return false }
        let name = app.trimmingCharacters(in: .whitespacesAndNewlines)

        var chosen: (sound: String, volume: Double?, source: String)?
        for rule in config.rules ?? [] {
            if let ruleApp = rule.app, !ruleApp.isEmpty,
               !name.localizedCaseInsensitiveContains(ruleApp) {
                continue
            }
            if let ruleText = rule.text, !ruleText.isEmpty { continue }
            chosen = (rule.sound, rule.volume, rule.app ?? "rule")
            break
        }
        if chosen == nil, let fallback = config.fallback, !fallback.isEmpty {
            chosen = (fallback, nil, "fallback")
        }
        guard let chosen else {
            log("cli play skip app=\(name) (no matching rule)")
            return false
        }

        play(sound: chosen.sound, volume: chosen.volume)
        log("cli play app=\(name) rule=\(chosen.source) sound=\(chosen.sound)")
        return true
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
        guard let config = readConfig(), let rules = config.rules, !rules.isEmpty else {
            play(sound: "Glass", volume: nil)
            log("test sound: Glass (no rules)")
            return
        }
        let rule = rules.first { $0.sound == lastPreviewSound } ?? rules[0]
        lastPreviewSound = rule.sound
        play(sound: rule.sound, volume: rule.volume)
        log("test sound: \(rule.sound)")
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
            rootDir,
            (configPath as NSString).deletingLastPathComponent,
            (logPath as NSString).deletingLastPathComponent,
            soundsDir
        ] {
            try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        migrateLegacyLayout()
    }

    /// 旧版本把配置放在 `~/.config/notif-sound`、声音和日志放在 `~/data/notif-sound`。
    /// 现在统一收进 `~/Library/Application Support/NotifSound`：启动时把旧文件搬过来，
    /// 旧目录搬空后删掉。只在目标不存在时搬，避免覆盖新位置已有的内容。
    private func migrateLegacyLayout() {
        guard !didMigrateLegacy else { return }
        didMigrateLegacy = true
        let fileManager = FileManager.default
        let legacyConfigDir = "\(home)/.config/notif-sound"
        let legacyDataDir = "\(home)/data/notif-sound"
        var moved: [String] = []

        let pairs = [
            ("\(legacyConfigDir)/rules.json", configPath),
            ("\(legacyDataDir)/logs/notif.log", logPath)
        ]
        for (source, target) in pairs {
            guard fileManager.fileExists(atPath: source),
                  !fileManager.fileExists(atPath: target) else { continue }
            if (try? fileManager.moveItem(atPath: source, toPath: target)) != nil {
                moved.append((source as NSString).lastPathComponent)
            }
        }

        if let names = try? fileManager.contentsOfDirectory(atPath: "\(legacyDataDir)/sounds") {
            for name in names {
                let source = "\(legacyDataDir)/sounds/\(name)"
                let target = "\(soundsDir)/\(name)"
                guard !fileManager.fileExists(atPath: target) else { continue }
                if (try? fileManager.moveItem(atPath: source, toPath: target)) != nil {
                    moved.append(name)
                }
            }
        }

        // 旧锁文件留着只会让旧目录搬不空；进程已经不在了就直接删掉。
        let legacyLock = "\(legacyDataDir)/notifsound.lock"
        if let text = try? String(contentsOfFile: legacyLock, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) != 0 {
            try? fileManager.removeItem(atPath: legacyLock)
        }

        for directory in [
            legacyConfigDir,
            "\(legacyDataDir)/sounds",
            "\(legacyDataDir)/logs",
            legacyDataDir
        ] {
            removeIfEmpty(directory)
        }

        if !moved.isEmpty {
            log("migrated \(moved.count) item(s) into Application Support: \(moved.joined(separator: ", "))")
        }
    }

    private func removeIfEmpty(_ path: String) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: path), names.isEmpty else { return }
        try? fileManager.removeItem(atPath: path)
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
        settingsColumn = nil
        ruleRowsStack = nil
        rulePopups = []
        volumeLabels = [:]
        allPopup = nil
    }
}

// MARK: - 入口

let arguments = CommandLine.arguments
if arguments.contains("--test-sound") {
    let watcher = Watcher()
    print(watcher.testSoundFromCLI())
    exit(0)
}
if arguments.count == 3, arguments[1] == "--play" {
    let watcher = Watcher()
    exit(watcher.playFromCLI(app: arguments[2]) ? 0 : 1)
}
if arguments.count == 4, arguments[1] == "--set-sound" {
    let watcher = Watcher()
    exit(watcher.assignFromCLI(filePath: arguments[2], app: arguments[3]) ? 0 : 1)
}

let application = NSApplication.shared
let watcher = Watcher()
application.delegate = watcher
application.run()
