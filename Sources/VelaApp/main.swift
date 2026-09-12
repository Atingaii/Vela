import Cocoa
import WebKit
import UniformTypeIdentifiers
import UserNotifications
import ServiceManagement

// MARK: - Native Draggable View for Window Dragging

final class DraggableTitlebarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        self.window?.performDrag(with: event)
    }
}

// MARK: - Application Entry & Delegate

final class VelaApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, UNUserNotificationCenterDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    
    // Helper Process & Stdin/Stdout Queues
    private var helperProcess: Process?
    private var helperStdin: Pipe?
    private var helperStdout: Pipe?
    private var helperStderr: Pipe?
    private var isHelperRunning = false
    
    private let stdinQueue = DispatchQueue(label: "ai.vela.host.stdin", qos: .userInitiated)
    private let stdoutQueue = DispatchQueue(label: "ai.vela.host.stdout", qos: .userInitiated)
    private var readBuffer = Data()
    private let maxStdoutBufferSize = 32 * 1024 * 1024 // 32 MiB
    
    // Request tracking & limits (Max 128 pending calls)
    private var pendingRequestIds = Set<String>()
    private var pendingTimers: [String: DispatchSourceTimer] = [:]
    private let requestLock = NSLock()
    private let maxPendingRequests = 128
    
    // Unsolicited event debouncing (~150ms)
    private var eventDebounceWorkItem: DispatchWorkItem?
    private let eventQueue = DispatchQueue(label: "ai.vela.host.events", qos: .utility)
    
    // Internal Host Polling Timer (when window is hidden)
    private var hiddenPollTimer: Timer?
    
    // Registered Projects & Security Bounds
    private var registeredProjects: [String] = []
    private var trustedUIRoot: URL?
    private var trustedIndexURL: URL?
    
    // Status tracking for menu bar
    private var currentRunningCount = 0
    private var currentApprovalsCount = 0
    
    // Notification & State Tracking
    private var isNotificationsUserEnabled = false
    private var isNotificationsEffective = false
    private var hasInitializedNotificationBaseline = false
    private var previousSessionStates: [String: String] = [:]
    private var previousRunStates: [String: String] = [:]
    private var previousApprovalStates: [String: String] = [:]
    
    private var isAppBundle: Bool {
        guard let id = Bundle.main.bundleIdentifier, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return Bundle.main.bundleURL.pathExtension == "app"
    }
    
    // Channel and Home Directory
    private var currentChannel: String = {
        return Bundle.main.object(forInfoDictionaryKey: "VelaChannel") as? String ?? "dev"
    }()
    
    private lazy var velaHome: URL = {
        if let env = ProcessInfo.processInfo.environment["VELA_HOME"], !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true).resolvingSymlinksInPath().standardized
        }
        let home = NSHomeDirectory()
        switch currentChannel {
        case "stable":
            return URL(fileURLWithPath: home + "/.vela", isDirectory: true).resolvingSymlinksInPath().standardized
        case "canary":
            return URL(fileURLWithPath: home + "/.vela-canary", isDirectory: true).resolvingSymlinksInPath().standardized
        default:
            return URL(fileURLWithPath: home + "/.vela-dev", isDirectory: true).resolvingSymlinksInPath().standardized
        }
    }()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAppBundle {
            UNUserNotificationCenter.current().delegate = self
        }
        setupMainMenu()
        setupStatusBar()
        setupWindow()
        launchVelaHelper()
        loadWebContent()
        startHiddenPollTimer()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        hiddenPollTimer?.invalidate()
        terminateVelaHelper()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
    
    private func postLocalNotification(title: String, body: String) {
        guard isAppBundle && isNotificationsEffective else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    private func syncNotificationPreference(from dictionary: [String: Any]) {
        var notifPref: Bool? = nil
        if let settings = dictionary["settings"] as? [String: Any] {
            if let val = settings["notifications"] as? Bool {
                notifPref = val
            }
        }
        if notifPref == nil, let val = dictionary["notifications"] as? Bool {
            notifPref = val
        }
        
        guard let userEnabled = notifPref else { return }
        self.isNotificationsUserEnabled = userEnabled
        
        guard isAppBundle else {
            self.isNotificationsEffective = false
            return
        }
        
        guard userEnabled else {
            self.isNotificationsEffective = false
            return
        }
        
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let granted = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
                self.isNotificationsEffective = self.isNotificationsUserEnabled && granted
            }
        }
    }
    
    private func trackTransitionsAndNotify(result: [String: Any]) {
        let sessions = result["sessions"] as? [[String: Any]]
        let runs = result["runs"] as? [[String: Any]]
        let approvals = result["approvals"] as? [[String: Any]]
        
        // Initial baseline snapshot establishes baseline only from an actual dashboard containing sessions/runs/approvals
        guard sessions != nil || runs != nil || approvals != nil else {
            return
        }
        
        if !hasInitializedNotificationBaseline {
            if let sessions = sessions {
                for s in sessions {
                    if let id = s["id"] as? String ?? s["sessionId"] as? String,
                       let st = s["state"] as? String {
                        previousSessionStates[id] = st.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                }
            }
            if let runs = runs {
                for r in runs {
                    if let id = r["id"] as? String,
                       let st = r["state"] as? String {
                        previousRunStates[id] = st.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                }
            }
            if let approvals = approvals {
                for a in approvals {
                    if let id = a["id"] as? String,
                       let st = a["state"] as? String {
                        previousApprovalStates[id] = st.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                }
            }
            hasInitializedNotificationBaseline = true
            return
        }
        
        // Notify on newly observed state transitions
        if let sessions = result["sessions"] as? [[String: Any]] {
            for s in sessions {
                guard let id = s["id"] as? String ?? s["sessionId"] as? String,
                      let st = s["state"] as? String else { continue }
                let norm = st.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let oldNorm = previousSessionStates[id]
                previousSessionStates[id] = norm
                
                if let old = oldNorm, old != norm {
                    let agentName = (s["agent"] as? String) ?? (s["provider"] as? String) ?? "Agent"
                    if norm == "completed" {
                        postLocalNotification(title: "会话已完成", body: "会话 [\(agentName)] 运行已成功完成")
                    } else if norm == "error" || norm == "failed" {
                        postLocalNotification(title: "会话异常终止", body: "会话 [\(agentName)] 遇到错误或异常中断")
                    } else if norm == "needs approval" || norm == "pending_approval" {
                        postLocalNotification(title: "需要人工审批", body: "会话 [\(agentName)] 等待您的操作授权")
                    }
                }
            }
        }
        
        if let runs = result["runs"] as? [[String: Any]] {
            for r in runs {
                guard let id = r["id"] as? String,
                      let st = r["state"] as? String else { continue }
                let norm = st.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let oldNorm = previousRunStates[id]
                previousRunStates[id] = norm
                
                if let old = oldNorm, old != norm {
                    let wfTitle = (r["title"] as? String) ?? (r["workflowId"] as? String) ?? "工作流"
                    if norm == "completed" {
                        postLocalNotification(title: "工作流已完成", body: "工作流 [\(wfTitle)] 执行成功")
                    } else if norm == "error" || norm == "failed" {
                        postLocalNotification(title: "工作流执行失败", body: "工作流 [\(wfTitle)] 遇到错误")
                    } else if norm == "needs approval" || norm == "pending_approval" {
                        postLocalNotification(title: "需要人工审批", body: "工作流 [\(wfTitle)] 等待操作审批")
                    }
                }
            }
        }
        
        if let approvals = result["approvals"] as? [[String: Any]] {
            for a in approvals {
                guard let id = a["id"] as? String,
                      let st = a["state"] as? String else { continue }
                let norm = st.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let oldNorm = previousApprovalStates[id]
                previousApprovalStates[id] = norm
                
                let isPending = (norm == "pending" || norm == "pending approval" || norm == "pending_approval" || norm.isEmpty)
                if isPending && (oldNorm == nil || oldNorm != norm) {
                    let title = (a["title"] as? String) ?? (a["id"] as? String) ?? "操作"
                    postLocalNotification(title: "需要人工审批", body: "待执行操作 [\(title)] 等待审批")
                }
            }
        }
    }
    
    // MARK: - Window Setup
    
    private func setupWindow() {
        let initialRect = NSRect(x: 0, y: 0, width: 1250, height: 800)
        window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 900, height: 620)
        window.title = "Vela"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        
        // Native bridge injection (forMainFrameOnly: true)
        let bridgeScript = """
        (function() {
            let nextId = 1;
            const pendingCalls = new Map();
            
            window.vela = {
                call: function(method, params = {}) {
                    return new Promise(function(resolve, reject) {
                        if (pendingCalls.size >= 128) {
                            return reject(new Error('超出待处理请求上限 (128)'));
                        }
                        const callId = String(nextId++);
                        
                        // Bounded timeout: 30 mins for long actions, 180s for ordinary
                        const isLong = (
                            method === 'workflows.run' ||
                            method === 'lab.run' ||
                            method === 'improve.analyze' ||
                            method === 'approvals.decide' ||
                            method === 'workflows.replay' ||
                            method === 'improve.apply' ||
                            method === 'improve.undo'
                        );
                        const timeoutMs = isLong ? 1800000 : 180000;
                        
                        const timer = setTimeout(function() {
                            if (pendingCalls.has(callId)) {
                                pendingCalls.delete(callId);
                                reject(new Error('请求超时 (' + method + ')'));
                            }
                        }, timeoutMs);
                        
                        pendingCalls.set(callId, { resolve: resolve, reject: reject, timer: timer });
                        try {
                            window.webkit.messageHandlers.vela.postMessage({
                                id: callId,
                                method: String(method),
                                params: (typeof params === 'object' && params !== null) ? params : {}
                            });
                        } catch (err) {
                            clearTimeout(timer);
                            pendingCalls.delete(callId);
                            reject(err);
                        }
                    });
                }
            };
            
            window.__velaReceive = function(response) {
                if (!response || typeof response !== 'object') return;
                const id = String(response.id);
                if (!pendingCalls.has(id)) return;
                const handler = pendingCalls.get(id);
                pendingCalls.delete(id);
                if (handler.timer) clearTimeout(handler.timer);
                
                if (response.error) {
                    const message = (response.error && response.error.message) ? response.error.message : String(response.error);
                    handler.reject(new Error(message));
                } else {
                    handler.resolve(response.result !== undefined ? response.result : null);
                }
            };
            
            window.__velaRejectAll = function(reason) {
                pendingCalls.forEach(function(handler) {
                    if (handler.timer) clearTimeout(handler.timer);
                    handler.reject(new Error(reason || 'Vela 辅助进程已终止'));
                });
                pendingCalls.clear();
            };
        })();
        """
        let userScript = WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        userContentController.addUserScript(userScript)
        userContentController.add(self, name: "vela")
        config.userContentController = userContentController
        
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        
        window.contentView?.addSubview(webView)
        
        // Native narrow draggable strip at top of window
        let dragStrip = DraggableTitlebarView(frame: NSRect(x: 80, y: window.contentView!.bounds.height - 38, width: window.contentView!.bounds.width - 240, height: 38))
        dragStrip.autoresizingMask = [.width, .minYMargin]
        window.contentView?.addSubview(dragStrip)
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
    
    // MARK: - Menu Bar Status Item
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemDisplay()
        
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "打开 Vela (Show Window)", action: #selector(showMainWindow), keyEquivalent: "o")
        showItem.target = self
        menu.addItem(showItem)
        
        let summaryItem = NSMenuItem(title: "状态: 就绪", action: nil, keyEquivalent: "")
        summaryItem.tag = 100
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        
        let inboxItem = NSMenuItem(title: "待执行操作 (Inbox)", action: #selector(openInbox), keyEquivalent: "i")
        inboxItem.target = self
        menu.addItem(inboxItem)
        
        let refreshItem = NSMenuItem(title: "刷新数据 (Refresh)", action: #selector(triggerRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出 Vela (Quit)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    private func updateStatusItemDisplay() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            // Compact monochrome symbols/text: e.g. "V", "V · 2", "V · !1", "V · 2 · !1"
            var parts: [String] = ["V"]
            if self.currentRunningCount > 0 {
                parts.append("\(self.currentRunningCount)")
            }
            if self.currentApprovalsCount > 0 {
                parts.append("!\(self.currentApprovalsCount)")
            }
            button.title = parts.joined(separator: " · ")
            
            if let menu = self.statusItem.menu, let summaryItem = menu.item(withTag: 100) {
                summaryItem.title = "运行中: \(self.currentRunningCount) · 待审批: \(self.currentApprovalsCount)"
            }
        }
    }
    
    @objc private func showMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func openInbox() {
        showMainWindow()
        dispatchWebEvent(name: "vela:navigate", detail: ["page": "inbox"])
    }
    
    @objc private func triggerRefresh() {
        dispatchWebEvent(name: "vela:refresh", detail: [:])
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
    
    // MARK: - Main Application Menu
    
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 Vela (About Vela)", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "设置... (Settings)", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        
        let hideItem = NSMenuItem(title: "隐藏 Vela", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        let showAllItem = NSMenuItem(title: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(hideItem)
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(showAllItem)
        appMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出 Vela", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        // Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        // View Menu (⌘1..⌘6 and ⌘K)
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        
        let pages = [
            ("Agents 会话", "1", "agents"),
            ("Workflows 工作流", "2", "workflows"),
            ("Setup 项目配置", "3", "setup"),
            ("Usage 用量追踪", "4", "usage"),
            ("Improve 调优建议", "5", "improve"),
            ("Lab 对照实验", "6", "lab")
        ]
        for (title, key, page) in pages {
            let item = NSMenuItem(title: title, action: #selector(navigateToPageMenuItem(_:)), keyEquivalent: key)
            item.representedObject = page
            item.target = self
            viewMenu.addItem(item)
        }
        viewMenu.addItem(NSMenuItem.separator())
        let searchItem = NSMenuItem(title: "搜索本地项目上下文 (Search)...", action: #selector(triggerSearch), keyEquivalent: "k")
        searchItem.target = self
        viewMenu.addItem(searchItem)
        
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)
        
        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        let showWindowItem = NSMenuItem(title: "主窗口 (Show Window)", action: #selector(showMainWindow), keyEquivalent: "0")
        showWindowItem.target = self
        windowMenu.addItem(showWindowItem)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Vela 0.1.0"
        alert.informativeText = "The engineering layer for coding agents.\n本地优先 · 无遥测 · 确定性架构"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
    
    @objc private func openSettings() {
        showMainWindow()
        dispatchWebEvent(name: "vela:navigate", detail: ["page": "settings"])
    }
    
    @objc private func navigateToPageMenuItem(_ sender: NSMenuItem) {
        if let page = sender.representedObject as? String {
            showMainWindow()
            dispatchWebEvent(name: "vela:navigate", detail: ["page": page])
        }
    }
    
    @objc private func triggerSearch() {
        showMainWindow()
        dispatchWebEvent(name: "vela:search", detail: [:])
    }
    
    private func dispatchWebEvent(name: String, detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        let js = "window.dispatchEvent(new CustomEvent('\(name)', { detail: \(jsonString) }));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    // MARK: - Resource Resolution & Content Loading
    
    private func loadWebContent() {
        let fm = FileManager.default
        var targetURL: URL?
        var readAccessURL: URL?
        
        // 1. Contents/Resources/UI/index.html (packaged bundle)
        if let resURL = Bundle.main.resourceURL {
            let candidate1 = resURL.appendingPathComponent("UI/index.html")
            if fm.fileExists(atPath: candidate1.path) {
                targetURL = candidate1
                readAccessURL = candidate1.deletingLastPathComponent()
            }
        }
        
        // 2. Bundle.module.resourceURL fallback (SwiftPM resource)
        #if !VELA_PACKAGED
        if targetURL == nil {
            if let moduleRes = Bundle.module.resourceURL {
                let candidate2 = moduleRes.appendingPathComponent("Resources/UI/index.html")
                if fm.fileExists(atPath: candidate2.path) {
                    targetURL = candidate2
                    readAccessURL = candidate2.deletingLastPathComponent()
                } else {
                    let candidate3 = moduleRes.appendingPathComponent("UI/index.html")
                    if fm.fileExists(atPath: candidate3.path) {
                        targetURL = candidate3
                        readAccessURL = candidate3.deletingLastPathComponent()
                    }
                }
            }
        }
        #endif
        
        // 3. Debug development cwd fallback only
        #if DEBUG
        if targetURL == nil {
            let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
            let devCandidate = cwd.appendingPathComponent("Sources/VelaApp/Resources/UI/index.html")
            if fm.fileExists(atPath: devCandidate.path) {
                targetURL = devCandidate
                readAccessURL = devCandidate.deletingLastPathComponent()
            }
        }
        #endif
        
        if let target = targetURL, let access = readAccessURL {
            self.trustedIndexURL = target.resolvingSymlinksInPath().standardized
            self.trustedUIRoot = access.resolvingSymlinksInPath().standardized
            webView.loadFileURL(target, allowingReadAccessTo: access)
        } else {
            let errorHtml = """
            <!DOCTYPE html>
            <html>
            <head><meta charset="utf-8"><title>Vela Error</title>
            <style>body{font-family:system-ui;padding:40px;background:#101017;color:#f5f5f7;line-height:1.6;}</style>
            </head>
            <body>
            <h2>无法加载 Vela 用户界面资源</h2>
            <p>未找到 Contents/Resources/UI/index.html 或 Bundle.module/Resources/UI/index.html。</p>
            </body>
            </html>
            """
            webView.loadHTMLString(errorHtml, baseURL: nil)
        }
    }
    
    // MARK: - Navigation Policy & Safe Descendant Check
    
    private func isSafeDescendant(targetPath: String, of rootURL: URL) -> Bool {
        let rootResolved = rootURL.resolvingSymlinksInPath().standardized.path
        let targetResolved = URL(fileURLWithPath: (targetPath as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardized.path
        return targetResolved == rootResolved || targetResolved.hasPrefix(rootResolved + "/")
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame ?? false else {
            decisionHandler(.cancel)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.isFileURL {
            let standardized = url.resolvingSymlinksInPath().standardized
            if let trusted = trustedIndexURL, standardized.path == trusted.path {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.cancel)
    }
    
    // MARK: - Helper RPC Process
    
    private func locateVelaExecutable() -> URL? {
        let fm = FileManager.default
        // 1. Packaged inside app: Contents/MacOS/vela
        if let bundleExec = Bundle.main.executableURL {
            let sibling = bundleExec.deletingLastPathComponent().appendingPathComponent("vela")
            if fm.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        // 2. Alongside bundle (e.g. SwiftPM adjacent executable sibling)
        let bundleAdjacent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("vela")
        if fm.isExecutableFile(atPath: bundleAdjacent.path) {
            return bundleAdjacent
        }
        #if DEBUG
        // 3. Optional cwd .build debug fallback only #if DEBUG
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let buildCandidate = cwd.appendingPathComponent(".build/debug/vela")
        if fm.isExecutableFile(atPath: buildCandidate.path) {
            return buildCandidate
        }
        #endif
        return nil
    }
    
    private func launchVelaHelper() {
        guard let velaURL = locateVelaExecutable() else {
            fputs("Vela host: 'vela' executable not found. Helper RPC disabled.\n", stderr)
            isHelperRunning = false
            return
        }
        
        let proc = Process()
        proc.executableURL = velaURL
        proc.arguments = ["rpc", "--home", velaHome.path]
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isHelperRunning = false
                fputs("Vela host: helper process terminated with code \(p.terminationStatus)\n", stderr)
                // Reject all pending calls immediately
                self.webView?.evaluateJavaScript("if (window.__velaRejectAll) window.__velaRejectAll('Vela 辅助服务已退出');", completionHandler: nil)
                self.requestLock.lock()
                for (_, t) in self.pendingTimers {
                    t.cancel()
                }
                self.pendingTimers.removeAll()
                self.pendingRequestIds.removeAll()
                self.requestLock.unlock()
            }
        }
        
        do {
            try proc.run()
            self.helperProcess = proc
            self.helperStdin = inPipe
            self.helperStdout = outPipe
            self.helperStderr = errPipe
            self.isHelperRunning = true
            startStdoutReader(outPipe)
            drainStderrSafely(errPipe)
        } catch {
            fputs("Vela host: failed to launch helper: \(error.localizedDescription)\n", stderr)
            self.isHelperRunning = false
        }
    }
    
    private func terminateVelaHelper() {
        if let proc = helperProcess, proc.isRunning {
            proc.terminate()
        }
        helperProcess = nil
        isHelperRunning = false
    }
    
    private func startStdoutReader(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        stdoutQueue.async { [weak self] in
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                guard let self = self else { break }
                self.processStdoutChunk(data)
            }
        }
    }
    
    private func processStdoutChunk(_ data: Data) {
        if readBuffer.count + data.count > maxStdoutBufferSize {
            // Buffer overflow protection: bound partial buffer
            fputs("Vela host: stdout buffer exceeded 32 MiB limit. Resetting helper.\n", stderr)
            readBuffer.removeAll()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.webView?.evaluateJavaScript("if (window.__velaRejectAll) window.__velaRejectAll('Vela 辅助服务输出超出 32 MiB 限制，请求已拒绝并重置连接');", completionHandler: nil)
                self.requestLock.lock()
                for (_, t) in self.pendingTimers {
                    t.cancel()
                }
                self.pendingTimers.removeAll()
                self.pendingRequestIds.removeAll()
                self.requestLock.unlock()
                self.terminateVelaHelper()
                self.launchVelaHelper()
            }
            return
        }
        readBuffer.append(data)
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) { // '\n'
            let lineData = readBuffer.subdata(in: 0..<newlineIndex)
            readBuffer.removeSubrange(0...newlineIndex)
            if lineData.isEmpty { continue }
            
            // Validate JSON safely on background queue before injecting into JS
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                continue
            }
            
            // Check for unsolicited notification e.g. { "event": "data.changed" }
            if let eventName = obj["event"] as? String {
                self.handleUnsolicitedEvent(eventName)
                continue
            }
            
            // Re-serialize strictly validated JSON object
            guard let sanitizedData = try? JSONSerialization.data(withJSONObject: obj),
                  let jsonString = String(data: sanitizedData, encoding: .utf8) else {
                continue
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.handleHelperOutputLine(obj: obj, jsonString: jsonString)
            }
        }
    }
    
    private func handleUnsolicitedEvent(_ eventName: String) {
        eventQueue.async { [weak self] in
            guard let self = self else { return }
            self.eventDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.dispatchWebEvent(name: "vela:refresh", detail: ["source": eventName])
            }
            self.eventDebounceWorkItem = workItem
            self.eventQueue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }
    }
    
    private func drainStderrSafely(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
            }
        }
    }
    
    private func handleHelperOutputLine(obj: [String: Any], jsonString: String) {
        let rawId = obj["id"]
        let idStr = (rawId as? String) ?? (rawId != nil ? String(describing: rawId!) : "")
        
        requestLock.lock()
        pendingRequestIds.remove(idStr)
        if let timer = pendingTimers.removeValue(forKey: idStr) {
            timer.cancel()
        }
        requestLock.unlock()
        
        // Internal Host Polling Response
        if idStr.hasPrefix("host-poll-") {
            if let result = obj["result"] as? [String: Any] {
                extractCountsAndUpdateStatus(result: result)
            }
            return
        }
        
        // Inspect response to capture registered projects, counts and observe transitions
        if let result = obj["result"] as? [String: Any] {
            extractCountsAndUpdateStatus(result: result)
        }
        
        // Pass strictly re-serialized JSON string to JS
        let js = "window.__velaReceive(\(jsonString));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    private func extractCountsAndUpdateStatus(result: [String: Any]) {
        self.syncNotificationPreference(from: result)
        if let projects = result["projects"] as? [[String: Any]] {
            self.registeredProjects = projects.compactMap { $0["path"] as? String }
        }
        // Extract real running and pending approval counts with normalized case
        if let sessions = result["sessions"] as? [[String: Any]] {
            self.currentRunningCount = sessions.filter {
                let st = ($0["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                return st == "running"
            }.count
        }
        if let approvals = result["approvals"] as? [[String: Any]] {
            self.currentApprovalsCount = approvals.filter {
                let st = ($0["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                return st == "pending" || st == "pending approval" || st.isEmpty
            }.count
        }
        self.updateStatusItemDisplay()
        self.trackTransitionsAndNotify(result: result)
    }
    
    private func sendToHelper(id: Any, method: String, params: [String: Any]) {
        let idStr = String(describing: id)
        
        requestLock.lock()
        if pendingRequestIds.count >= maxPendingRequests {
            requestLock.unlock()
            respondToJS(id: id, result: nil, error: "达到最大并发请求限制 (128)")
            return
        }
        pendingRequestIds.insert(idStr)
        requestLock.unlock()
        
        guard isHelperRunning, let stdin = helperStdin else {
            requestLock.lock()
            pendingRequestIds.remove(idStr)
            requestLock.unlock()
            respondToJS(id: id, result: nil, error: "Vela 辅助程序 (vela) 不可用或未找到。请检查应用程序打包完整性。")
            return
        }
        
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            requestLock.lock()
            pendingRequestIds.remove(idStr)
            requestLock.unlock()
            respondToJS(id: id, result: nil, error: "请求数据序列化失败")
            return
        }
        
        // Native timeout cleanup matching JS timeout (30min for long actions, 180s for ordinary)
        let isLongAction = (
            method == "workflows.run" ||
            method == "lab.run" ||
            method == "improve.analyze" ||
            method == "approvals.decide" ||
            method == "workflows.replay" ||
            method == "improve.apply" ||
            method == "improve.undo"
        )
        let timeoutSeconds: Double = isLongAction ? 1800.0 : 180.0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.requestLock.lock()
            let wasPending = self.pendingRequestIds.remove(idStr) != nil
            self.pendingTimers.removeValue(forKey: idStr)
            self.requestLock.unlock()
            if wasPending {
                self.respondToJS(id: idStr, result: nil, error: "请求超时 (\(method))")
            }
        }
        requestLock.lock()
        pendingTimers[idStr] = timer
        requestLock.unlock()
        timer.resume()
        
        // Serialized stdin write queue
        stdinQueue.async { [weak self] in
            do {
                var lineData = data
                lineData.append(0x0A)
                try stdin.fileHandleForWriting.write(contentsOf: lineData)
            } catch {
                DispatchQueue.main.async {
                    self?.requestLock.lock()
                    self?.pendingRequestIds.remove(idStr)
                    if let t = self?.pendingTimers.removeValue(forKey: idStr) {
                        t.cancel()
                    }
                    self?.requestLock.unlock()
                    self?.respondToJS(id: id, result: nil, error: "无法写入 Vela 辅助服务: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func respondToJS(id: Any, result: Any?, error: String?) {
        var resp: [String: Any] = ["id": id]
        if let error = error {
            resp["error"] = ["message": error]
        } else {
            resp["result"] = result ?? NSNull()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: resp),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript("window.__velaReceive(\(jsonString));", completionHandler: nil)
        }
    }
    
    // MARK: - Script Message Handler
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "vela" else { return }
        
        // Restrict to main frame messages only
        guard message.frameInfo.isMainFrame else {
            fputs("Vela host: rejected non-main-frame bridge call\n", stderr)
            return
        }
        
        // Exact resolved URL guard: message.frameInfo.request.url must match trustedIndexURL
        guard let requestURL = message.frameInfo.request.url?.resolvingSymlinksInPath().standardized,
              let trusted = trustedIndexURL,
              requestURL.path == trusted.path else {
            fputs("Vela host: rejected untrusted frame URL bridge call\n", stderr)
            return
        }
        
        guard let body = message.body as? [String: Any] else { return }
        
        guard let rawId = body["id"] else {
            fputs("Vela host: missing request id\n", stderr)
            return
        }
        
        // Validate id is non-empty String or finite NSNumber (reject booleans, arrays, dictionaries, null)
        let idStr: String
        if let num = rawId as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                fputs("Vela host: rejected boolean request id\n", stderr)
                return
            }
            if num.doubleValue.isNaN || num.doubleValue.isInfinite {
                fputs("Vela host: rejected non-finite numeric request id\n", stderr)
                return
            }
            idStr = num.stringValue
        } else if let s = rawId as? String {
            idStr = s
        } else {
            fputs("Vela host: rejected invalid request id type\n", stderr)
            return
        }
        
        if idStr.isEmpty || idStr.count > 128 || idStr.hasPrefix("host-poll-") {
            fputs("Vela host: rejected invalid id pattern or length\n", stderr)
            return
        }
        
        guard let method = body["method"] as? String else {
            respondToJS(id: idStr, result: nil, error: "缺少 method 字段")
            return
        }
        
        // Validate params is a dictionary
        guard let params = body["params"] as? [String: Any] else {
            respondToJS(id: idStr, result: nil, error: "params 必须为有效字典对象")
            return
        }
        
        // Forward system.version to backend helper first before generic system.* handling
        if method == "system.version" {
            sendToHelper(id: idStr, method: method, params: params)
            return
        }
        
        // Handle native system methods
        if method.hasPrefix("system.") {
            handleSystemMethod(id: idStr, method: method, params: params)
            return
        }
        
        // Intercept native settings.save before forwarding to helper
        if method == "settings.save" {
            handleSettingsSave(id: idStr, params: params)
            return
        }
        
        // Allowlisted RPC methods
        let allowlistedMethods: Set<String> = [
            "dashboard.get", "projects.list", "projects.add", "projects.remove",
            "agents.list", "sessions.list", "sessions.get", "sessions.refresh",
            "setup.list", "setup.scan", "setup.audit", "usage.get",
            "memory.list", "memory.save", "memory.transition", "recall", "search",
            "checkpoint.save", "checkpoint.list", "checkpoint.export",
            "library.add", "library.list",
            "workflows.list", "workflows.save", "workflows.run", "runs.list", "runs.get",
            "workflows.health", "workflows.replay", "workflows.build",
            "guidelines.list", "guidelines.save", "regression.list",
            "inbox.list", "approvals.decide",
            "improve.analyze", "improve.list", "improve.preview", "improve.apply", "improve.undo", "improve.dismiss",
            "lab.list", "lab.run", "lab.compare",
            "evidence.get", "settings.get"
        ]
        
        if allowlistedMethods.contains(method) {
            sendToHelper(id: idStr, method: method, params: params)
        } else {
            respondToJS(id: idStr, result: nil, error: "不支持的 RPC 方法：\(method)")
        }
    }
    
    // MARK: - Settings Save Interception
    
    private func handleSettingsSave(id: String, params: [String: Any]) {
        let requestedNotif = params["notifications"] as? Bool
        let requestedLogin = params["launchAtLogin"] as? Bool
        
        let proceedWithLoginAndForward = { [weak self] (notifGranted: Bool?) in
            guard let self = self else { return }
            if let granted = notifGranted {
                self.isNotificationsUserEnabled = granted
                self.isNotificationsEffective = granted
            }
            
            if let reqLogin = requestedLogin {
                if !self.isAppBundle {
                    if reqLogin {
                        self.respondToJS(id: id, result: nil, error: "开机自启功能需要以 macOS 应用程序包 (.app) 形式运行")
                        return
                    }
                } else {
                    if #available(macOS 13.0, *) {
                        let currentStatus = SMAppService.mainApp.status
                        do {
                            if reqLogin {
                                if currentStatus != .enabled && currentStatus != .requiresApproval {
                                    try SMAppService.mainApp.register()
                                }
                            } else {
                                if currentStatus == .enabled || currentStatus == .requiresApproval {
                                    try SMAppService.mainApp.unregister()
                                }
                            }
                        } catch {
                            self.respondToJS(id: id, result: nil, error: "配置开机自启动失败: \(error.localizedDescription)")
                            return
                        }
                    } else {
                        if reqLogin {
                            self.respondToJS(id: id, result: nil, error: "开机自启需要 macOS 13 及更高版本系统支持")
                            return
                        }
                    }
                }
            }
            
            // Forward validated settings to backend helper preserving all fields
            self.sendToHelper(id: id, method: "settings.save", params: params)
        }
        
        if requestedNotif == true {
            guard isAppBundle else {
                respondToJS(id: id, result: nil, error: "系统通知功能需要以 macOS 应用程序包 (.app) 形式运行")
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let error = error {
                        self.respondToJS(id: id, result: nil, error: "申请系统通知权限失败: \(error.localizedDescription)")
                        return
                    }
                    if !granted {
                        self.respondToJS(id: id, result: nil, error: "系统通知权限已被用户拒绝，请在 macOS 系统设置中开启")
                        return
                    }
                    proceedWithLoginAndForward(true)
                }
            }
        } else {
            if requestedNotif == false {
                self.isNotificationsUserEnabled = false
                self.isNotificationsEffective = false
            }
            proceedWithLoginAndForward(requestedNotif)
        }
    }
    
    // MARK: - System Methods
    
    private func handleSystemMethod(id: Any, method: String, params: [String: Any]) {
        switch method {
        case "system.ready":
            respondToJS(id: id, result: true, error: nil)
            
        case "system.info":
            let notifSupported = isAppBundle
            let notifStatus: String
            if !notifSupported {
                notifStatus = "unsupported"
            } else if isNotificationsEffective {
                notifStatus = "enabled"
            } else if isNotificationsUserEnabled {
                notifStatus = "denied"
            } else {
                notifStatus = "disabled"
            }
            
            var loginStatus = "unsupported"
            let hasBundle = isAppBundle
            if hasBundle {
                if #available(macOS 13.0, *) {
                    switch SMAppService.mainApp.status {
                    case .enabled:
                        loginStatus = "enabled"
                    case .requiresApproval:
                        loginStatus = "pending_approval"
                    case .notRegistered:
                        loginStatus = "notRegistered"
                    case .notFound:
                        loginStatus = "notFound"
                    @unknown default:
                        loginStatus = "unknown"
                    }
                } else {
                    loginStatus = "unsupported"
                }
            }
            
            respondToJS(id: id, result: [
                "channel": currentChannel,
                "home": velaHome.path,
                "version": "0.1.0",
                "helperRunning": isHelperRunning,
                "notificationsSupported": notifSupported,
                "notificationsStatus": notifStatus,
                "launchAtLoginStatus": loginStatus,
                "launchAtLoginSupported": hasBundle
            ], error: nil)
            
        case "system.chooseProject":
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "选择项目"
                panel.message = "选择一个本地 Git 或工程目录以连接到 Vela"
                
                panel.beginSheetModal(for: self.window) { response in
                    if response == .OK, let url = panel.url {
                        self.respondToJS(id: id, result: url.path, error: nil)
                    } else {
                        self.respondToJS(id: id, result: NSNull(), error: nil)
                    }
                }
            }
            
        case "system.openExternal":
            guard let urlString = params["url"] as? String,
                  let url = URL(string: urlString),
                  url.scheme?.lowercased() == "https" else {
                respondToJS(id: id, result: nil, error: "system.openExternal 仅支持 HTTPS 链接")
                return
            }
            NSWorkspace.shared.open(url)
            respondToJS(id: id, result: true, error: nil)
            
        case "system.reveal":
            guard let path = params["path"] as? String else {
                respondToJS(id: id, result: nil, error: "缺少路径参数")
                return
            }
            let isInsideStore = isSafeDescendant(targetPath: path, of: velaHome)
            let isInsideKnownProject = registeredProjects.contains { proj in
                let pURL = URL(fileURLWithPath: (proj as NSString).expandingTildeInPath, isDirectory: true)
                return isSafeDescendant(targetPath: path, of: pURL)
            }
            
            if isInsideStore || isInsideKnownProject {
                let resolvedURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
                if FileManager.default.fileExists(atPath: resolvedURL.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([resolvedURL])
                    respondToJS(id: id, result: true, error: nil)
                } else {
                    respondToJS(id: id, result: nil, error: "文件不存在：\(path)")
                }
            } else {
                respondToJS(id: id, result: nil, error: "拒绝访问：路径不在 Vela 存储或已知项目范围内")
            }
            
        case "system.updateStatus":
            if let running = params["running"] as? Int {
                self.currentRunningCount = running
            }
            if let approvals = params["approvals"] as? Int {
                self.currentApprovalsCount = approvals
            }
            self.updateStatusItemDisplay()
            respondToJS(id: id, result: true, error: nil)
            
        default:
            respondToJS(id: id, result: nil, error: "未知系统方法：\(method)")
        }
    }
    
    // MARK: - Background Host Polling
    
    private func startHiddenPollTimer() {
        hiddenPollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Only poll internally if window is ordered out / hidden
            if self.isHelperRunning && !(self.window?.isVisible ?? false) {
                let internalId = "host-poll-\(UUID().uuidString)"
                self.sendToHelper(id: internalId, method: "dashboard.get", params: [:])
            }
        }
    }
}

// MARK: - Main Runner

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = VelaApplicationDelegate()
app.delegate = delegate
app.run()
