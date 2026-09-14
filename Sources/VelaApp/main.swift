import Cocoa
import WebKit
import UniformTypeIdentifiers
import UserNotifications
import ServiceManagement
import VelaCore

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
    private var pendingRequestMethods: [String: String] = [:]
    private var pendingTimers: [String: DispatchSourceTimer] = [:]
    private let requestLock = NSLock()
    private let maxPendingRequests = 128

    // Unsolicited event debouncing (~150ms)
    private var eventDebounceWorkItem: DispatchWorkItem?
    private let eventQueue = DispatchQueue(label: "ai.vela.host.events", qos: .utility)

    // Internal Host Polling Timer (5s global dashboard poll)
    private var hostPollTimer: Timer?
    private var isHostPollInFlight = false

    // Registered Projects & Security Bounds
    private var registeredProjects: [String] = []
    private var trustedUIRoot: URL?
    private var trustedIndexURL: URL?

    // Status tracking for menu bar
    private var currentRunningCount = 0
    private var currentApprovalsCount = 0

    // Authoritative Core Locale & In-flight language switching
    private var currentLocale: String = VelaLocale.defaultLocale
    private var isLanguageChangeInFlight = false
    private var activeLanguageChangeRequestId: String?
    private var pendingLanguageChangeLocale: String?

    // Retained menu references for instant in-place localized label updates
    private var appMenuItem: NSMenuItem?
    private var aboutMenuItem: NSMenuItem?
    private var languageMenuItem: NSMenuItem?
    private var languageMenu: NSMenu?
    private var zhLanguageMenuItem: NSMenuItem?
    private var enLanguageMenuItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?
    private var hideMenuItem: NSMenuItem?
    private var hideOthersMenuItem: NSMenuItem?
    private var showAllMenuItem: NSMenuItem?
    private var quitMenuItem: NSMenuItem?

    private var editMenuItem: NSMenuItem?
    private var editMenu: NSMenu?
    private var undoMenuItem: NSMenuItem?
    private var redoMenuItem: NSMenuItem?
    private var cutMenuItem: NSMenuItem?
    private var copyMenuItem: NSMenuItem?
    private var pasteMenuItem: NSMenuItem?
    private var selectAllMenuItem: NSMenuItem?

    private var viewMenuItem: NSMenuItem?
    private var viewMenu: NSMenu?
    private var pageMenuItems: [String: NSMenuItem] = [:]
    private var searchMenuItem: NSMenuItem?

    private var windowMenuItem: NSMenuItem?
    private var windowMenu: NSMenu?
    private var miniaturizeMenuItem: NSMenuItem?
    private var zoomMenuItem: NSMenuItem?
    private var mainWindowMenuItem: NSMenuItem?

    #if !VELA_PACKAGED
    private var devMenuItem: NSMenuItem?
    private var devMenu: NSMenu?
    private var captureMenuItem: NSMenuItem?
    #endif

    private var statusShowItem: NSMenuItem?
    private var statusSummaryItem: NSMenuItem?
    private var statusInboxItem: NSMenuItem?
    private var statusRefreshItem: NSMenuItem?
    private var statusQuitItem: NSMenuItem?

    // Notification & State Tracking via VelaNotificationPolicy
    private var notificationPolicy = VelaNotificationPolicy()
    private var isNotificationsEffective = false
    private var currentNotificationSettings: [String: Bool] = [
        "notifications": false,
        "notificationSound": true,
        "notifyApprovals": true,
        "notifyCompleted": true,
        "notifyErrors": true
    ]
    private var pendingNotificationRoute: [String: Any]?
    private var isWebReady = false
    private var currentSoundPreview: NSSound?

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
        startHostPollTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hostPollTimer?.invalidate()
        currentSoundPreview?.stop()
        currentSoundPreview = nil
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
        let soundEnabled = (currentNotificationSettings["notificationSound"] ?? true) && (notification.request.content.sound != nil)
        if #available(macOS 11.0, *) {
            completionHandler(soundEnabled ? [.banner, .sound] : [.banner])
        } else {
            completionHandler(soundEnabled ? [.alert, .sound] : [.alert])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let userInfo = response.notification.request.content.userInfo
            let count = userInfo["count"] as? Int ?? 1
            if let source = userInfo["source"] as? String {
                let sources: [String]
                if let existingSources = userInfo["sources"] as? [String] {
                    sources = existingSources
                } else if ["session", "run", "approval"].contains(source) {
                    sources = [source]
                } else {
                    sources = []
                }
                let spansProjects = userInfo["spansProjects"] as? Bool ?? false
                let isAggregate = userInfo["isAggregate"] as? Bool ?? (count > 1)

                let routeDetail: [String: Any] = [
                    "source": source,
                    "recordID": userInfo["recordID"] as? String ?? "",
                    "project": userInfo["project"] as? String ?? "",
                    "kind": userInfo["kind"] as? String ?? "",
                    "count": count,
                    "sources": sources,
                    "spansProjects": spansProjects,
                    "isAggregate": isAggregate
                ]
                self.dispatchNotificationRoute(routeDetail)
            }
        }
        completionHandler()
    }

    private func dispatchNotificationRoute(_ route: [String: Any]) {
        if isWebReady {
            dispatchWebEvent(name: "vela:notificationRoute", detail: route)
        } else {
            pendingNotificationRoute = route
        }
    }

    private func postLocalNotification(event: VelaNotificationEvent, title: String, body: String) {
        guard isAppBundle && isNotificationsEffective else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let soundEnabled = currentNotificationSettings["notificationSound"] ?? true
        if soundEnabled {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(event.kind.soundFilename))
        } else {
            content.sound = nil
        }
        content.userInfo = [
            "source": event.source,
            "recordID": event.recordID,
            "project": event.project,
            "kind": event.kind.rawValue,
            "count": event.count,
            "sources": event.sources,
            "spansProjects": event.spansProjects,
            "isAggregate": event.isAggregate
        ]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func syncNotificationPreference(from dictionary: [String: Any], method: String?) {
        let settings: [String: Any]?
        if method == "settings.get" || method == "settings.save" {
            if let s = dictionary["settings"] as? [String: Any] {
                settings = s
            } else if dictionary["id"] as? String == "preferences" {
                settings = dictionary
            } else {
                settings = dictionary
            }
        } else if method == "dashboard.get" {
            settings = dictionary["settings"] as? [String: Any]
        } else {
            settings = nil
        }

        guard let settings = settings else { return }
        if let val = settings["notifications"] as? Bool { currentNotificationSettings["notifications"] = val }
        if let val = settings["notificationSound"] as? Bool { currentNotificationSettings["notificationSound"] = val }
        if let val = settings["notifyApprovals"] as? Bool { currentNotificationSettings["notifyApprovals"] = val }
        if let val = settings["notifyCompleted"] as? Bool { currentNotificationSettings["notifyCompleted"] = val }
        if let val = settings["notifyErrors"] as? Bool { currentNotificationSettings["notifyErrors"] = val }

        let userEnabled = currentNotificationSettings["notifications"] ?? false
        guard isAppBundle && userEnabled else {
            self.isNotificationsEffective = false
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let granted = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
                self.isNotificationsEffective = (self.currentNotificationSettings["notifications"] ?? false) && granted
            }
        }
    }

    private func trackTransitionsAndNotify(result: [String: Any]) {
        guard result["notificationScope"] as? String == "*" else { return }
        let events = notificationPolicy.events(from: result)
        guard !events.isEmpty else { return }

        for event in events {
            let title: String
            let body: String
            switch event.kind {
            case .approval:
                title = VelaLocalization.string("notif.approval.title", locale: currentLocale)
                if event.count > 1 {
                    body = VelaLocalization.string("notif.approval.bodyMulti", locale: currentLocale, placeholders: ["count": "\(event.count)"])
                } else {
                    body = VelaLocalization.string("notif.approval.bodySingle", locale: currentLocale, placeholders: ["title": event.title])
                }
            case .completed:
                if event.count > 1 {
                    title = VelaLocalization.string("notif.completed.statusUpdateTitle", locale: currentLocale)
                    body = VelaLocalization.string("notif.completed.statusUpdateBody", locale: currentLocale, placeholders: ["count": "\(event.count)"])
                } else if event.inferred {
                    title = VelaLocalization.string("notif.completed.inferredTitle", locale: currentLocale)
                    body = VelaLocalization.string("notif.completed.inferredBody", locale: currentLocale, placeholders: ["title": event.title])
                } else if event.source == "run" {
                    title = VelaLocalization.string("notif.completed.workflowTitle", locale: currentLocale)
                    body = VelaLocalization.string("notif.completed.workflowBody", locale: currentLocale, placeholders: ["title": event.title])
                } else {
                    title = VelaLocalization.string("notif.completed.taskTitle", locale: currentLocale)
                    body = VelaLocalization.string("notif.completed.taskBody", locale: currentLocale, placeholders: ["title": event.title])
                }
            case .error:
                if event.count > 1 {
                    title = VelaLocalization.string("notif.error.statusUpdateTitle", locale: currentLocale)
                    body = VelaLocalization.string("notif.error.statusUpdateBody", locale: currentLocale, placeholders: ["count": "\(event.count)"])
                } else if event.inferred {
                    title = VelaLocalization.string("notif.error.inferredTitle", locale: currentLocale)
                    body = VelaLocalization.string("notif.error.inferredBody", locale: currentLocale, placeholders: ["title": event.title])
                } else if event.source == "run" {
                    title = VelaLocalization.string("notif.error.workflowTitle", locale: currentLocale)
                    body = VelaLocalization.string("notif.error.workflowBody", locale: currentLocale, placeholders: ["title": event.title])
                } else {
                    title = VelaLocalization.string("notif.error.taskTitle", locale: currentLocale)
                    body = VelaLocalization.string("notif.error.taskBody", locale: currentLocale, placeholders: ["title": event.title])
                }
            }
            postLocalNotification(event: event, title: title, body: body)
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
        #if !VELA_PACKAGED
        if ProcessInfo.processInfo.environment["VELA_NATIVE_QA"] == "1" {
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }
        #endif
        let userContentController = WKUserContentController()

        // Native bridge injection (forMainFrameOnly: true)
        let bridgeTable: [String: [String: String]] = [
            "limit": [
                VelaLocale.zhCN: VelaLocalization.string("error.maxPendingRequests", locale: VelaLocale.zhCN),
                VelaLocale.en: VelaLocalization.string("error.maxPendingRequests", locale: VelaLocale.en)
            ],
            "timeout": [
                VelaLocale.zhCN: VelaLocalization.string("error.timeout", locale: VelaLocale.zhCN),
                VelaLocale.en: VelaLocalization.string("error.timeout", locale: VelaLocale.en)
            ],
            "terminated": [
                VelaLocale.zhCN: VelaLocalization.string("error.helperProcessTerminated", locale: VelaLocale.zhCN),
                VelaLocale.en: VelaLocalization.string("error.helperProcessTerminated", locale: VelaLocale.en)
            ]
        ]
        let bridgeTableData = (try? JSONSerialization.data(withJSONObject: bridgeTable, options: [.sortedKeys])) ?? Data()
        let bridgeTableJSON = String(data: bridgeTableData, encoding: .utf8) ?? "{}"
        let initialLocaleLiteral = (VelaLocale.canonical(currentLocale) == VelaLocale.en) ? "\"en\"" : "\"zh-CN\""

        let bridgeScript = """
        (function() {
            let nextId = 1;
            const pendingCalls = new Map();
            let currentBridgeLocale = \(initialLocaleLiteral);
            const bridgeI18n = \(bridgeTableJSON);

            function getBridgeString(key, method) {
                const rawLoc = (typeof window.__velaLocale === 'string') ? window.__velaLocale : '';
                const loc = (rawLoc === 'zh-CN' || rawLoc === 'en') ? rawLoc : currentBridgeLocale;
                const entry = bridgeI18n[key] || {};
                let text = entry[loc] || entry['\(VelaLocale.defaultLocale)'] || '';
                if (method !== undefined && method !== null) {
                    text = text.split('{method}').join(String(method));
                }
                return text;
            }

            window.__velaSetLocale = function(newLocale) {
                if (newLocale === 'zh-CN' || newLocale === 'en') {
                    currentBridgeLocale = newLocale;
                    window.__velaLocale = newLocale;
                }
            };

            window.addEventListener('vela:localeChanged', function(evt) {
                if (evt && evt.detail && typeof evt.detail.locale === 'string') {
                    window.__velaSetLocale(evt.detail.locale);
                }
            });

            window.vela = {
                call: function(method, params = {}) {
                    return new Promise(function(resolve, reject) {
                        if (pendingCalls.size >= 128) {
                            return reject(new Error(getBridgeString('limit')));
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
                                reject(new Error(getBridgeString('timeout', method)));
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
                const defaultMsg = reason || getBridgeString('terminated');
                pendingCalls.forEach(function(handler) {
                    if (handler.timer) clearTimeout(handler.timer);
                    handler.reject(new Error(defaultMsg));
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
        // Sized to x: 80 .. (windowWidth - 320), excluding the full wide search affordance on the right
        let dragStripWidth = max(100, window.contentView!.bounds.width - 400)
        let dragStrip = DraggableTitlebarView(frame: NSRect(x: 80, y: window.contentView!.bounds.height - 38, width: dragStripWidth, height: 38))
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

        let menu = NSMenu()
        let showItem = NSMenuItem(title: VelaLocalization.string("status.open", locale: currentLocale), action: #selector(showMainWindow), keyEquivalent: "o")
        showItem.target = self
        menu.addItem(showItem)
        self.statusShowItem = showItem

        let summaryItem = NSMenuItem(title: VelaLocalization.string("status.ready", locale: currentLocale), action: nil, keyEquivalent: "")
        summaryItem.tag = 100
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        self.statusSummaryItem = summaryItem

        let inboxItem = NSMenuItem(title: VelaLocalization.string("status.inbox", locale: currentLocale), action: #selector(openInbox), keyEquivalent: "i")
        inboxItem.target = self
        menu.addItem(inboxItem)
        self.statusInboxItem = inboxItem

        let refreshItem = NSMenuItem(title: VelaLocalization.string("status.refresh", locale: currentLocale), action: #selector(triggerRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        self.statusRefreshItem = refreshItem

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: VelaLocalization.string("status.quit", locale: currentLocale), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        self.statusQuitItem = quitItem

        statusItem.menu = menu
        updateStatusItemDisplay()
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

            if let summaryItem = self.statusSummaryItem {
                if self.currentRunningCount == 0 && self.currentApprovalsCount == 0 {
                    summaryItem.title = VelaLocalization.string("status.ready", locale: self.currentLocale)
                } else {
                    summaryItem.title = VelaLocalization.string(
                        "status.summary",
                        locale: self.currentLocale,
                        placeholders: [
                            "running": "\(self.currentRunningCount)",
                            "approvals": "\(self.currentApprovalsCount)"
                        ]
                    )
                }
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
        self.appMenuItem = appMenuItem
        let appMenu = NSMenu(title: "Vela")

        let aboutItem = NSMenuItem(title: VelaLocalization.string("menu.app.about", locale: currentLocale), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        self.aboutMenuItem = aboutItem
        appMenu.addItem(NSMenuItem.separator())

        // Language Submenu
        let langMenuItem = NSMenuItem(title: VelaLocalization.string("menu.language", locale: currentLocale), action: nil, keyEquivalent: "")
        let langMenu = NSMenu(title: VelaLocalization.string("menu.language", locale: currentLocale))

        let zhItem = NSMenuItem(title: "简体中文", action: #selector(selectLanguageMenuItem(_:)), keyEquivalent: "")
        zhItem.representedObject = VelaLocale.zhCN
        zhItem.target = self
        zhItem.state = (currentLocale == VelaLocale.zhCN) ? .on : .off
        langMenu.addItem(zhItem)
        self.zhLanguageMenuItem = zhItem

        let enItem = NSMenuItem(title: "English", action: #selector(selectLanguageMenuItem(_:)), keyEquivalent: "")
        enItem.representedObject = VelaLocale.en
        enItem.target = self
        enItem.state = (currentLocale == VelaLocale.en) ? .on : .off
        langMenu.addItem(enItem)
        self.enLanguageMenuItem = enItem

        langMenuItem.submenu = langMenu
        appMenu.addItem(langMenuItem)
        self.languageMenuItem = langMenuItem
        self.languageMenu = langMenu
        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: VelaLocalization.string("menu.app.settings", locale: currentLocale), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        self.settingsMenuItem = settingsItem
        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: VelaLocalization.string("menu.app.hide", locale: currentLocale), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: VelaLocalization.string("menu.app.hideOthers", locale: currentLocale), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        let showAllItem = NSMenuItem(title: VelaLocalization.string("menu.app.showAll", locale: currentLocale), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(hideItem)
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(showAllItem)
        self.hideMenuItem = hideItem
        self.hideOthersMenuItem = hideOthersItem
        self.showAllMenuItem = showAllItem
        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: VelaLocalization.string("menu.app.quit", locale: currentLocale), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        self.quitMenuItem = quitItem

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu
        let editMenuItem = NSMenuItem()
        self.editMenuItem = editMenuItem
        let editMenu = NSMenu(title: VelaLocalization.string("menu.edit", locale: currentLocale))
        self.editMenu = editMenu

        let undoItem = NSMenuItem(title: VelaLocalization.string("menu.edit.undo", locale: currentLocale), action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: VelaLocalization.string("menu.edit.redo", locale: currentLocale), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        self.undoMenuItem = undoItem
        self.redoMenuItem = redoItem
        editMenu.addItem(NSMenuItem.separator())

        let cutItem = NSMenuItem(title: VelaLocalization.string("menu.edit.cut", locale: currentLocale), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copyItem = NSMenuItem(title: VelaLocalization.string("menu.edit.copy", locale: currentLocale), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: VelaLocalization.string("menu.edit.paste", locale: currentLocale), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(title: VelaLocalization.string("menu.edit.selectAll", locale: currentLocale), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(cutItem)
        editMenu.addItem(copyItem)
        editMenu.addItem(pasteItem)
        editMenu.addItem(selectAllItem)
        self.cutMenuItem = cutItem
        self.copyMenuItem = copyItem
        self.pasteMenuItem = pasteItem
        self.selectAllMenuItem = selectAllItem

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View Menu (⌘1..⌘6 and ⌘K)
        let viewMenuItem = NSMenuItem()
        self.viewMenuItem = viewMenuItem
        let viewMenu = NSMenu(title: VelaLocalization.string("menu.view", locale: currentLocale))
        self.viewMenu = viewMenu

        let pages = [
            ("agents", "1", "nav.sessions"),
            ("workflows", "2", "nav.workflows"),
            ("setup", "3", "nav.setup"),
            ("usage", "4", "nav.usage"),
            ("improve", "5", "nav.improve"),
            ("lab", "6", "nav.lab")
        ]
        self.pageMenuItems.removeAll()
        for (page, key, locKey) in pages {
            let item = NSMenuItem(title: VelaLocalization.string(locKey, locale: currentLocale), action: #selector(navigateToPageMenuItem(_:)), keyEquivalent: key)
            item.representedObject = page
            item.target = self
            viewMenu.addItem(item)
            self.pageMenuItems[page] = item
        }
        viewMenu.addItem(NSMenuItem.separator())
        let searchItem = NSMenuItem(title: VelaLocalization.string("menu.view.search", locale: currentLocale), action: #selector(triggerSearch), keyEquivalent: "k")
        searchItem.target = self
        viewMenu.addItem(searchItem)
        self.searchMenuItem = searchItem

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        self.windowMenuItem = windowMenuItem
        let windowMenu = NSMenu(title: VelaLocalization.string("menu.window", locale: currentLocale))
        self.windowMenu = windowMenu

        let miniaturizeItem = NSMenuItem(title: VelaLocalization.string("menu.window.miniaturize", locale: currentLocale), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let zoomItem = NSMenuItem(title: VelaLocalization.string("menu.window.zoom", locale: currentLocale), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(miniaturizeItem)
        windowMenu.addItem(zoomItem)
        self.miniaturizeMenuItem = miniaturizeItem
        self.zoomMenuItem = zoomItem
        windowMenu.addItem(NSMenuItem.separator())

        let showWindowItem = NSMenuItem(title: VelaLocalization.string("menu.window.mainWindow", locale: currentLocale), action: #selector(showMainWindow), keyEquivalent: "0")
        showWindowItem.target = self
        windowMenu.addItem(showWindowItem)
        self.mainWindowMenuItem = showWindowItem

        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        #if !VELA_PACKAGED
        if validatedCaptureEnvironment() != nil {
            let devMenuItem = NSMenuItem()
            self.devMenuItem = devMenuItem
            let devMenu = NSMenu(title: VelaLocalization.string("menu.dev", locale: currentLocale))
            self.devMenu = devMenu
            let captureItem = NSMenuItem(title: VelaLocalization.string("menu.dev.capture", locale: currentLocale), action: #selector(captureTestScreenshot), keyEquivalent: "s")
            captureItem.keyEquivalentModifierMask = [.control, .option, .command]
            captureItem.target = self
            devMenu.addItem(captureItem)
            self.captureMenuItem = captureItem
            devMenuItem.submenu = devMenu
            mainMenu.addItem(devMenuItem)
        }
        #endif

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Native Localization & In-Place UI Updates

    @objc private func selectLanguageMenuItem(_ sender: NSMenuItem) {
        guard let targetLocale = sender.representedObject as? String else { return }
        guard VelaLocale.isValid(targetLocale) else { return }
        if targetLocale == currentLocale {
            return
        }
        guard !isLanguageChangeInFlight else { return }

        let internalId = "host-lang-\(UUID().uuidString)"
        isLanguageChangeInFlight = true
        activeLanguageChangeRequestId = internalId
        pendingLanguageChangeLocale = targetLocale
        sendToHelper(id: internalId, method: "settings.save", params: ["locale": targetLocale])
    }

    private func showLanguageChangeError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let alert = NSAlert()
            alert.messageText = VelaLocalization.string("alert.languageChangeFailed.title", locale: self.currentLocale)
            alert.informativeText = VelaLocalization.string("alert.languageChangeFailed.message", locale: self.currentLocale, placeholders: ["error": message])
            alert.alertStyle = .warning
            alert.addButton(withTitle: VelaLocalization.string("common.ok", locale: self.currentLocale))
            alert.runModal()
        }
    }

    private func updateLocalizedUI() {
        zhLanguageMenuItem?.state = (currentLocale == VelaLocale.zhCN) ? .on : .off
        enLanguageMenuItem?.state = (currentLocale == VelaLocale.en) ? .on : .off

        aboutMenuItem?.title = VelaLocalization.string("menu.app.about", locale: currentLocale)
        languageMenuItem?.title = VelaLocalization.string("menu.language", locale: currentLocale)
        languageMenu?.title = VelaLocalization.string("menu.language", locale: currentLocale)
        settingsMenuItem?.title = VelaLocalization.string("menu.app.settings", locale: currentLocale)
        hideMenuItem?.title = VelaLocalization.string("menu.app.hide", locale: currentLocale)
        hideOthersMenuItem?.title = VelaLocalization.string("menu.app.hideOthers", locale: currentLocale)
        showAllMenuItem?.title = VelaLocalization.string("menu.app.showAll", locale: currentLocale)
        quitMenuItem?.title = VelaLocalization.string("menu.app.quit", locale: currentLocale)

        editMenu?.title = VelaLocalization.string("menu.edit", locale: currentLocale)
        undoMenuItem?.title = VelaLocalization.string("menu.edit.undo", locale: currentLocale)
        redoMenuItem?.title = VelaLocalization.string("menu.edit.redo", locale: currentLocale)
        cutMenuItem?.title = VelaLocalization.string("menu.edit.cut", locale: currentLocale)
        copyMenuItem?.title = VelaLocalization.string("menu.edit.copy", locale: currentLocale)
        pasteMenuItem?.title = VelaLocalization.string("menu.edit.paste", locale: currentLocale)
        selectAllMenuItem?.title = VelaLocalization.string("menu.edit.selectAll", locale: currentLocale)

        viewMenu?.title = VelaLocalization.string("menu.view", locale: currentLocale)
        pageMenuItems["agents"]?.title = VelaLocalization.string("nav.sessions", locale: currentLocale)
        pageMenuItems["workflows"]?.title = VelaLocalization.string("nav.workflows", locale: currentLocale)
        pageMenuItems["setup"]?.title = VelaLocalization.string("nav.setup", locale: currentLocale)
        pageMenuItems["usage"]?.title = VelaLocalization.string("nav.usage", locale: currentLocale)
        pageMenuItems["improve"]?.title = VelaLocalization.string("nav.improve", locale: currentLocale)
        pageMenuItems["lab"]?.title = VelaLocalization.string("nav.lab", locale: currentLocale)
        searchMenuItem?.title = VelaLocalization.string("menu.view.search", locale: currentLocale)

        windowMenu?.title = VelaLocalization.string("menu.window", locale: currentLocale)
        miniaturizeMenuItem?.title = VelaLocalization.string("menu.window.miniaturize", locale: currentLocale)
        zoomMenuItem?.title = VelaLocalization.string("menu.window.zoom", locale: currentLocale)
        mainWindowMenuItem?.title = VelaLocalization.string("menu.window.mainWindow", locale: currentLocale)

        #if !VELA_PACKAGED
        devMenu?.title = VelaLocalization.string("menu.dev", locale: currentLocale)
        captureMenuItem?.title = VelaLocalization.string("menu.dev.capture", locale: currentLocale)
        #endif

        statusShowItem?.title = VelaLocalization.string("status.open", locale: currentLocale)
        statusInboxItem?.title = VelaLocalization.string("status.inbox", locale: currentLocale)
        statusRefreshItem?.title = VelaLocalization.string("status.refresh", locale: currentLocale)
        statusQuitItem?.title = VelaLocalization.string("status.quit", locale: currentLocale)
        updateStatusItemDisplay()
    }

    private func updateConfirmedLocale(_ newLocale: String) {
        let changed = (newLocale != self.currentLocale)
        self.currentLocale = newLocale
        updateLocalizedUI()
        if let locData = try? JSONSerialization.data(withJSONObject: [newLocale]),
           let locJSON = String(data: locData, encoding: .utf8) {
            let script = "if (window.__velaSetLocale) window.__velaSetLocale(\(locJSON)[0]);"
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }
        if changed {
            dispatchWebEvent(name: "vela:localeChanged", detail: ["locale": newLocale])
        }
    }

    private func syncConfirmedLocaleFromPreferences(_ dictionary: [String: Any], method: String?) {
        let prefs: [String: Any]?
        if method == "settings.get" || method == "settings.save" {
            if let s = dictionary["settings"] as? [String: Any] {
                prefs = s
            } else if dictionary["id"] as? String == "preferences" || dictionary["locale"] is String {
                prefs = dictionary
            } else {
                prefs = nil
            }
        } else if method == "dashboard.get" {
            prefs = dictionary["settings"] as? [String: Any]
        } else {
            prefs = nil
        }

        guard let confirmedPrefs = prefs,
              let rawLocale = confirmedPrefs["locale"] as? String else { return }
        let canonical = VelaLocale.canonical(rawLocale)
        updateConfirmedLocale(canonical)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = VelaLocalization.string("about.title", locale: currentLocale)
        alert.informativeText = VelaLocalization.string("about.informative", locale: currentLocale)
        alert.alertStyle = .informational
        alert.addButton(withTitle: VelaLocalization.string("common.ok", locale: currentLocale))
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
            <h2>\(VelaLocalization.string("error.html.title", locale: currentLocale))</h2>
            <p>\(VelaLocalization.string("error.html.body", locale: currentLocale))</p>
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
                if let current = self.helperProcess, current !== p {
                    return
                }
                if self.helperProcess === p {
                    self.helperProcess = nil
                }
                let hadActiveLanguageChange = (self.activeLanguageChangeRequestId != nil)
                self.isHelperRunning = false
                self.isHostPollInFlight = false
                self.isLanguageChangeInFlight = false
                self.activeLanguageChangeRequestId = nil
                self.pendingLanguageChangeLocale = nil
                fputs("Vela host: helper process terminated with code \(p.terminationStatus)\n", stderr)
                // Reject all pending calls immediately
                let rejectMsg = VelaLocalization.string("error.helperTerminated", locale: self.currentLocale)
                if let msgData = try? JSONSerialization.data(withJSONObject: [rejectMsg]),
                   let msgJSON = String(data: msgData, encoding: .utf8) {
                    self.webView?.evaluateJavaScript("if (window.__velaRejectAll) window.__velaRejectAll(\(msgJSON)[0]);", completionHandler: nil)
                } else {
                    self.webView?.evaluateJavaScript("if (window.__velaRejectAll) window.__velaRejectAll();", completionHandler: nil)
                }
                self.requestLock.lock()
                for (_, t) in self.pendingTimers {
                    t.cancel()
                }
                self.pendingTimers.removeAll()
                self.pendingRequestIds.removeAll()
                self.pendingRequestMethods.removeAll()
                self.requestLock.unlock()

                if hadActiveLanguageChange {
                    self.showLanguageChangeError(rejectMsg)
                }
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

            // Query confirmed settings immediately on helper launch
            let initSettingsId = "host-init-settings-\(UUID().uuidString)"
            sendToHelper(id: initSettingsId, method: "settings.get", params: [:])
        } catch {
            fputs("Vela host: failed to launch helper: \(error.localizedDescription)\n", stderr)
            self.isHelperRunning = false
            self.isHostPollInFlight = false
        }
    }

    private func terminateVelaHelper() {
        if let proc = helperProcess, proc.isRunning {
            proc.terminate()
        }
        helperProcess = nil
        isHelperRunning = false
        isHostPollInFlight = false
        isLanguageChangeInFlight = false
        activeLanguageChangeRequestId = nil
        pendingLanguageChangeLocale = nil
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
                let hadActiveLanguageChange = (self.activeLanguageChangeRequestId != nil)
                self.isHostPollInFlight = false
                self.isLanguageChangeInFlight = false
                self.activeLanguageChangeRequestId = nil
                self.pendingLanguageChangeLocale = nil
                let overflowMsg = VelaLocalization.string("error.bufferOverflow", locale: self.currentLocale)
                if let msgData = try? JSONSerialization.data(withJSONObject: [overflowMsg]),
                   let msgJSON = String(data: msgData, encoding: .utf8) {
                    self.webView?.evaluateJavaScript("if (window.__velaRejectAll) window.__velaRejectAll(\(msgJSON)[0]);", completionHandler: nil)
                } else {
                    self.webView?.evaluateJavaScript("if (window.__velaRejectAll) window.__velaRejectAll();", completionHandler: nil)
                }
                self.requestLock.lock()
                for (_, t) in self.pendingTimers {
                    t.cancel()
                }
                self.pendingTimers.removeAll()
                self.pendingRequestIds.removeAll()
                self.pendingRequestMethods.removeAll()
                self.requestLock.unlock()
                self.terminateVelaHelper()
                self.launchVelaHelper()
                if hadActiveLanguageChange {
                    self.showLanguageChangeError(overflowMsg)
                }
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
        let wasPending = pendingRequestIds.remove(idStr) != nil
        let reqMethod = pendingRequestMethods.removeValue(forKey: idStr)
        if let timer = pendingTimers.removeValue(forKey: idStr) {
            timer.cancel()
        }
        requestLock.unlock()

        guard wasPending else {
            // Stale or timed-out request; ignore completely
            return
        }

        // Internal Language Change Response
        if idStr.hasPrefix("host-lang-") {
            guard self.activeLanguageChangeRequestId == idStr else {
                // Superseded by a newer language change request; ignore stale response
                return
            }
            self.activeLanguageChangeRequestId = nil
            self.isLanguageChangeInFlight = false
            self.pendingLanguageChangeLocale = nil
            if let errorObj = obj["error"] as? [String: Any] {
                let errorMsg = errorObj["message"] as? String ?? "\(errorObj)"
                showLanguageChangeError(errorMsg)
                return
            }
            if let errorMsg = obj["error"] as? String {
                showLanguageChangeError(errorMsg)
                return
            }
            if let result = obj["result"] as? [String: Any] {
                syncConfirmedLocaleFromPreferences(result, method: "settings.save")
            }
            return
        }

        // Internal Initial Settings Response
        if idStr.hasPrefix("host-init-settings-") {
            if let result = obj["result"] as? [String: Any] {
                syncConfirmedLocaleFromPreferences(result, method: "settings.get")
                syncNotificationPreference(from: result, method: "settings.get")
            }
            return
        }

        // Internal Host Polling Response
        if idStr.hasPrefix("host-poll-") {
            self.isHostPollInFlight = false
            if let result = obj["result"] as? [String: Any] {
                extractCountsAndUpdateStatus(result: result, method: reqMethod ?? "dashboard.get")
            }
            return
        }

        // Inspect response to capture registered projects, counts, locale and observe transitions
        if let result = obj["result"] as? [String: Any] {
            extractCountsAndUpdateStatus(result: result, method: reqMethod)
        }

        // Pass strictly re-serialized JSON string to JS
        let js = "window.__velaReceive(\(jsonString));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func extractCountsAndUpdateStatus(result: [String: Any], method: String?) {
        self.syncNotificationPreference(from: result, method: method)
        self.syncConfirmedLocaleFromPreferences(result, method: method)
        if let projects = result["projects"] as? [[String: Any]] {
            self.registeredProjects = projects.compactMap { $0["path"] as? String }
        }
        guard result["notificationScope"] as? String == "*" else { return }
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
        let isHostPoll = idStr.hasPrefix("host-poll-")
        let isHostLang = idStr.hasPrefix("host-lang-")

        requestLock.lock()
        if pendingRequestIds.count >= maxPendingRequests {
            requestLock.unlock()
            if isHostPoll {
                self.isHostPollInFlight = false
            } else if isHostLang {
                if self.activeLanguageChangeRequestId == idStr {
                    self.activeLanguageChangeRequestId = nil
                    self.isLanguageChangeInFlight = false
                    self.pendingLanguageChangeLocale = nil
                    self.showLanguageChangeError(VelaLocalization.string("error.maxPendingRequests", locale: self.currentLocale))
                }
            } else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.maxPendingRequests", locale: self.currentLocale))
            }
            return
        }
        pendingRequestIds.insert(idStr)
        pendingRequestMethods[idStr] = method
        requestLock.unlock()

        guard isHelperRunning, let stdin = helperStdin else {
            requestLock.lock()
            pendingRequestIds.remove(idStr)
            pendingRequestMethods.removeValue(forKey: idStr)
            requestLock.unlock()
            if isHostPoll {
                self.isHostPollInFlight = false
            } else if isHostLang {
                if self.activeLanguageChangeRequestId == idStr {
                    self.activeLanguageChangeRequestId = nil
                    self.isLanguageChangeInFlight = false
                    self.pendingLanguageChangeLocale = nil
                    self.showLanguageChangeError(VelaLocalization.string("error.helperUnavailable", locale: self.currentLocale))
                }
            } else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.helperUnavailable", locale: self.currentLocale))
            }
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
            pendingRequestMethods.removeValue(forKey: idStr)
            requestLock.unlock()
            if isHostPoll {
                self.isHostPollInFlight = false
            } else if isHostLang {
                if self.activeLanguageChangeRequestId == idStr {
                    self.activeLanguageChangeRequestId = nil
                    self.isLanguageChangeInFlight = false
                    self.pendingLanguageChangeLocale = nil
                    self.showLanguageChangeError(VelaLocalization.string("error.serializationFailed", locale: self.currentLocale))
                }
            } else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.serializationFailed", locale: self.currentLocale))
            }
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
            let reqMethod = self.pendingRequestMethods.removeValue(forKey: idStr)
            self.pendingTimers.removeValue(forKey: idStr)
            self.requestLock.unlock()
            if isHostPoll {
                self.isHostPollInFlight = false
                return
            }
            if isHostLang {
                if self.activeLanguageChangeRequestId == idStr {
                    self.activeLanguageChangeRequestId = nil
                    self.isLanguageChangeInFlight = false
                    self.pendingLanguageChangeLocale = nil
                    if wasPending {
                        let timeoutMsg = VelaLocalization.string("error.timeout", locale: self.currentLocale, placeholders: ["method": method])
                        self.showLanguageChangeError(timeoutMsg)
                    }
                }
                return
            }
            if idStr.hasPrefix("host-init-settings-") {
                return
            }
            if wasPending {
                let timeoutMsg = VelaLocalization.string("error.timeout", locale: self.currentLocale, placeholders: ["method": reqMethod ?? method])
                self.respondToJS(id: idStr, result: nil, error: timeoutMsg)
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
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.requestLock.lock()
                    self.pendingRequestIds.remove(idStr)
                    self.pendingRequestMethods.removeValue(forKey: idStr)
                    if let t = self.pendingTimers.removeValue(forKey: idStr) {
                        t.cancel()
                    }
                    self.requestLock.unlock()
                    if isHostPoll {
                        self.isHostPollInFlight = false
                    } else if isHostLang {
                        if self.activeLanguageChangeRequestId == idStr {
                            self.activeLanguageChangeRequestId = nil
                            self.isLanguageChangeInFlight = false
                            self.pendingLanguageChangeLocale = nil
                            let writeErrMsg = VelaLocalization.string("error.stdinWriteFailed", locale: self.currentLocale, placeholders: ["error": error.localizedDescription])
                            self.showLanguageChangeError(writeErrMsg)
                        }
                    } else if idStr.hasPrefix("host-init-settings-") {
                        // ignore
                    } else {
                        let writeErrMsg = VelaLocalization.string("error.stdinWriteFailed", locale: self.currentLocale, placeholders: ["error": error.localizedDescription])
                        self.respondToJS(id: id, result: nil, error: writeErrMsg)
                    }
                }
            }
        }
    }

    private func respondToJS(id: Any, result: Any?, error: String?) {
        let idStr = String(describing: id)
        if idStr.hasPrefix("host-poll-") || idStr.hasPrefix("host-lang-") || idStr.hasPrefix("host-init-settings-") { return }
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
            respondToJS(id: idStr, result: nil, error: VelaLocalization.string("error.missingMethod", locale: currentLocale))
            return
        }

        // Validate params is a dictionary
        guard let params = body["params"] as? [String: Any] else {
            respondToJS(id: idStr, result: nil, error: VelaLocalization.string("error.invalidParams", locale: currentLocale))
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
            "setup.list", "setup.scan", "setup.audit", "setup.edit.get", "setup.edit.preview", "setup.edit.prepare", "setup.edit.undo", "usage.get",
            "memory.list", "memory.save", "memory.transition", "recall", "search",
            "memory.capture.prepare", "memory.capture",
            "checkpoint.save", "checkpoint.list", "checkpoint.export",
            "library.add", "library.list", "library.get", "library.update", "library.remove", "library.restore", "library.refresh", "library.history", "library.export", "library.index", "library.index.status", "library.search",
            "workflows.list", "workflows.save", "workflows.run", "runs.list", "runs.get",
            "runs.feedback.prepare", "runs.feedback.record",
            "runs.feedback.history.list", "runs.feedback.history.get",
            "runs.feedback.get", "runs.feedback.list",
            "workflows.health", "workflows.replay", "workflows.build",
            "workflows.health.proposal.get", "workflows.health.proposal.list", "workflows.health.proposeTimeout", "workflows.health.proposal.decide",
            "guidelines.list", "guidelines.save", "regression.list",
            "inbox.list", "approvals.decide",
            "improve.analyze", "improve.list", "improve.preview", "improve.apply", "improve.undo", "improve.dismiss",
            "lab.list", "lab.run", "lab.compare", "lab.promote",
            "reuse.preview", "reuse.outcomes",
            "evidence.get", "settings.get",
            "memory.archive.export", "memory.archive.validate", "memory.archive.import",
            "schedules.list", "schedules.resolve",
            "daemon.status", "daemon.plan", "daemon.start", "daemon.stop", "daemon.uninstall",
            "usage.quota.status", "usage.quota.read",
            "workflows.plan", "workflows.plan.get", "workflows.plan.list", "workflows.plan.cancel",
            "memory.semantic.status", "memory.semantic.index",
            "improve.model.describe", "improve.model.plan", "improve.model.list", "improve.model.get", "improve.model.transition",
            "connectors.status", "connectors.configure", "connectors.forget",
            "connectors.tools.search", "connectors.tools.get", "connectors.tools.list",
            "connectors.toolkits.list", "connectors.accounts.list", "connectors.authConfigs.list",
            "connectors.action.preview", "connectors.action.plan", "connectors.action.get", "connectors.action.list", "connectors.action.resolve",
            "runs.resume", "outputs.list", "outputs.get", "outputs.inbox", "outputs.markRead",
            "setup.catalog", "setup.get", "setup.history", "setup.diff", "setup.relations",
            "workflows.get", "workflows.validate", "workflows.clone", "workflows.setEnabled", "workflows.remove", "workflows.restore",
            "watches.describe", "watches.get", "watches.preview",
            "loops.describe", "loops.plan", "loops.list", "loops.get", "loops.cancel",
            "ask.describe", "ask.create", "ask.followup", "ask.get", "ask.list", "ask.cancel", "ask.citations",
            "history.describe", "history.discover", "history.sources", "history.start",
            "history.advance", "history.get", "history.jobs", "history.pause",
            "history.resume", "history.cancel", "history.page", "history.raw", "history.branch",
            "sessions.plan.describe", "sessions.plan.get", "sessions.plan.events",
            "sessions.relations.describe", "sessions.relations.get", "sessions.relations.children", "sessions.relations.events", "sessions.relations.resolve"
        ]

        if allowlistedMethods.contains(method) {
            sendToHelper(id: idStr, method: method, params: params)
        } else {
            let errMsg = VelaLocalization.string("error.unsupportedMethod", locale: currentLocale, placeholders: ["method": method])
            respondToJS(id: idStr, result: nil, error: errMsg)
        }
    }

    // MARK: - Settings Save Interception

    private func handleSettingsSave(id: String, params: [String: Any]) {
        // Explicitly validate locale if provided
        if let rawLocale = params["locale"] {
            guard let locStr = rawLocale as? String, VelaLocale.isValid(locStr) else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.invalidLocale", locale: currentLocale))
                return
            }
        }

        var booleanChanges = params
        booleanChanges.removeValue(forKey: "locale")
        if !booleanChanges.isEmpty {
            do {
                try VelaPreferences.validate(booleanChanges)
            } catch {
                respondToJS(id: id, result: nil, error: error.localizedDescription)
                return
            }
        }

        let requestedNotif = params["notifications"] as? Bool
        let requestedLogin = params["launchAtLogin"] as? Bool

        let proceedWithLoginAndForward = { [weak self] (notifGranted: Bool?) in
            guard let self = self else { return }
            if let granted = notifGranted {
                self.currentNotificationSettings["notifications"] = granted
                self.isNotificationsEffective = granted
            }
            if let sound = params["notificationSound"] as? Bool {
                self.currentNotificationSettings["notificationSound"] = sound
            }
            if let apprv = params["notifyApprovals"] as? Bool {
                self.currentNotificationSettings["notifyApprovals"] = apprv
            }
            if let comp = params["notifyCompleted"] as? Bool {
                self.currentNotificationSettings["notifyCompleted"] = comp
            }
            if let errs = params["notifyErrors"] as? Bool {
                self.currentNotificationSettings["notifyErrors"] = errs
            }

            if let reqLogin = requestedLogin {
                if !self.isAppBundle {
                    if reqLogin {
                        self.respondToJS(id: id, result: nil, error: VelaLocalization.string("error.launchAtLoginAppRequired", locale: self.currentLocale))
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
                            let msg = VelaLocalization.string("error.launchAtLoginConfigFailed", locale: self.currentLocale, placeholders: ["error": error.localizedDescription])
                            self.respondToJS(id: id, result: nil, error: msg)
                            return
                        }
                    } else {
                        if reqLogin {
                            self.respondToJS(id: id, result: nil, error: VelaLocalization.string("error.launchAtLoginOSRequired", locale: self.currentLocale))
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
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.notificationAppRequired", locale: self.currentLocale))
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let error = error {
                        let msg = VelaLocalization.string("error.notificationAuthFailed", locale: self.currentLocale, placeholders: ["error": error.localizedDescription])
                        self.respondToJS(id: id, result: nil, error: msg)
                        return
                    }
                    if !granted {
                        self.respondToJS(id: id, result: nil, error: VelaLocalization.string("error.notificationDenied", locale: self.currentLocale))
                        return
                    }
                    proceedWithLoginAndForward(true)
                }
            }
        } else {
            if requestedNotif == false {
                self.currentNotificationSettings["notifications"] = false
                self.isNotificationsEffective = false
            }
            proceedWithLoginAndForward(requestedNotif)
        }
    }

    // MARK: - System Methods

    private func handleSystemMethod(id: Any, method: String, params: [String: Any]) {
        switch method {
        case "system.ready":
            self.isWebReady = true
            if let pending = self.pendingNotificationRoute {
                self.dispatchWebEvent(name: "vela:notificationRoute", detail: pending)
                self.pendingNotificationRoute = nil
            }
            if let locData = try? JSONSerialization.data(withJSONObject: [self.currentLocale]),
               let locJSON = String(data: locData, encoding: .utf8) {
                let script = "if (window.__velaSetLocale) window.__velaSetLocale(\(locJSON)[0]);"
                webView?.evaluateJavaScript(script, completionHandler: nil)
            }
            // Emit confirmed locale to resolve ready-before/after-locale races
            dispatchWebEvent(name: "vela:localeChanged", detail: ["locale": self.currentLocale])
            respondToJS(id: id, result: true, error: nil)

        case "system.info":
            let notifSupported = isAppBundle
            let notifStatus: String
            if !notifSupported {
                notifStatus = "unsupported"
            } else if isNotificationsEffective {
                notifStatus = "enabled"
            } else if currentNotificationSettings["notifications"] == true {
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
                "version": "0.1.0-preview.2",
                "helperRunning": isHelperRunning,
                "notificationsSupported": notifSupported,
                "notificationsStatus": notifStatus,
                "launchAtLoginStatus": loginStatus,
                "launchAtLoginSupported": hasBundle,
                "locale": currentLocale
            ], error: nil)

        case "system.previewNotificationSound":
            guard params.count == 1 else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.soundSingleKind", locale: currentLocale))
                return
            }
            guard let rawKind = params["kind"] as? String else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.soundMissingKind", locale: currentLocale))
                return
            }
            guard let notifKind = VelaNotificationKind(rawValue: rawKind) else {
                let msg = VelaLocalization.string("error.soundUnsupportedKind", locale: currentLocale, placeholders: ["kind": rawKind])
                respondToJS(id: id, result: nil, error: msg)
                return
            }
            guard let resourceURL = Bundle.main.resourceURL else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.resourceDirUnavailable", locale: currentLocale))
                return
            }
            let soundURL = resourceURL.appendingPathComponent(notifKind.soundFilename)
            guard FileManager.default.fileExists(atPath: soundURL.path),
                  let sound = NSSound(contentsOf: soundURL, byReference: true) else {
                let msg = VelaLocalization.string("error.soundFileNotFound", locale: currentLocale, placeholders: ["filename": notifKind.soundFilename])
                respondToJS(id: id, result: nil, error: msg)
                return
            }
            currentSoundPreview?.stop()
            currentSoundPreview = sound
            if sound.play() {
                respondToJS(id: id, result: ["kind": notifKind.rawValue, "playing": true], error: nil)
            } else {
                currentSoundPreview = nil
                let msg = VelaLocalization.string("error.soundPlaybackFailed", locale: currentLocale, placeholders: ["filename": notifKind.soundFilename])
                respondToJS(id: id, result: nil, error: msg)
            }

        case "system.chooseProject":
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = VelaLocalization.string("panel.chooseProject.title", locale: self.currentLocale)
                panel.prompt = VelaLocalization.string("panel.chooseProject.prompt", locale: self.currentLocale)
                panel.message = VelaLocalization.string("panel.chooseProject.message", locale: self.currentLocale)

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
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.openExternalHttpsOnly", locale: currentLocale))
                return
            }
            NSWorkspace.shared.open(url)
            respondToJS(id: id, result: true, error: nil)

        case "system.reveal":
            guard let path = params["path"] as? String else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.missingPath", locale: currentLocale))
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
                    let msg = VelaLocalization.string("error.fileNotFound", locale: currentLocale, placeholders: ["path": path])
                    respondToJS(id: id, result: nil, error: msg)
                }
            } else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.accessDenied", locale: currentLocale))
            }

        case "system.updateStatus":
            // Authoritative global counts are tracked via 5s host poll with notificationScope == "*".
            // Acknowledge compatibility call without overwriting global counts with project-filtered counts.
            respondToJS(id: id, result: true, error: nil)

        case "system.saveMemoryArchive":
            guard let archive = params["archive"] as? [String: Any] else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.invalidArchivePayload", locale: currentLocale))
                return
            }
            guard archive["format"] as? String == "vela.memory-archive" else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.invalidArchiveFormat", locale: currentLocale))
                return
            }
            let versionNum = (archive["version"] as? NSNumber)?.intValue
            guard versionNum == 1 else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.unsupportedArchiveVersion", locale: currentLocale))
                return
            }
            guard let jsonData = try? JSONSerialization.data(withJSONObject: archive, options: [.prettyPrinted, .sortedKeys]) else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.serializationFailed", locale: currentLocale))
                return
            }
            guard jsonData.count <= 1024 * 1024 else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.archiveSizeLimitExceeded", locale: currentLocale))
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let panel = NSSavePanel()
                panel.title = VelaLocalization.string("panel.saveMemoryArchive.title", locale: self.currentLocale)
                panel.prompt = VelaLocalization.string("panel.saveMemoryArchive.prompt", locale: self.currentLocale)
                panel.message = VelaLocalization.string("panel.saveMemoryArchive.message", locale: self.currentLocale)
                if #available(macOS 11.0, *) {
                    panel.allowedContentTypes = [UTType.json]
                } else {
                    panel.allowedFileTypes = ["json"]
                }
                let sourceProj = (archive["source"] as? [String: Any])?["project"] as? String ?? "project"
                let projName = URL(fileURLWithPath: sourceProj).lastPathComponent
                let cleanProjName = projName.isEmpty ? "project" : projName
                panel.nameFieldStringValue = "vela-memory-archive-\(cleanProjName).json"

                panel.beginSheetModal(for: self.window) { response in
                    if response == .OK, let targetURL = panel.url {
                        do {
                            try jsonData.write(to: targetURL, options: .atomic)
                            self.respondToJS(id: id, result: ["saved": true, "path": targetURL.path, "bytes": jsonData.count], error: nil)
                        } catch {
                            self.respondToJS(id: id, result: nil, error: error.localizedDescription)
                        }
                    } else {
                        self.respondToJS(id: id, result: ["saved": false, "cancelled": true], error: nil)
                    }
                }
            }

        case "system.saveLibraryExport":
            guard let content = params["content"] as? String else {
                respondToJS(id: id, result: nil, error: VelaLocalization.string("error.serializationFailed", locale: currentLocale))
                return
            }
            let defaultName = params["filename"] as? String ?? "library-export.md"
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let panel = NSSavePanel()
                panel.title = VelaLocalization.string("panel.saveLibraryExport.title", locale: self.currentLocale)
                panel.prompt = VelaLocalization.string("panel.saveLibraryExport.prompt", locale: self.currentLocale)
                panel.message = VelaLocalization.string("panel.saveLibraryExport.message", locale: self.currentLocale)
                if #available(macOS 11.0, *) {
                    panel.allowedContentTypes = [UTType.plainText]
                } else {
                    panel.allowedFileTypes = ["md", "markdown", "txt"]
                }
                panel.nameFieldStringValue = defaultName

                panel.beginSheetModal(for: self.window) { response in
                    if response == .OK, let targetURL = panel.url {
                        do {
                            try content.write(to: targetURL, atomically: true, encoding: .utf8)
                            self.respondToJS(id: id, result: ["saved": true, "path": targetURL.path, "bytes": content.utf8.count], error: nil)
                        } catch {
                            self.respondToJS(id: id, result: nil, error: error.localizedDescription)
                        }
                    } else {
                        self.respondToJS(id: id, result: ["saved": false, "cancelled": true], error: nil)
                    }
                }
            }

        default:
            let msg = VelaLocalization.string("error.unknownSystemMethod", locale: currentLocale, placeholders: ["method": method])
            respondToJS(id: id, result: nil, error: msg)
        }
    }

    // MARK: - Periodic Host Polling (5s Global Snapshot)

    private func startHostPollTimer() {
        hostPollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Host must fetch a global dashboard at its 5s timer even when main window visible, to avoid missing other projects
            if self.isHelperRunning && !self.isHostPollInFlight {
                self.isHostPollInFlight = true
                let internalId = "host-poll-\(UUID().uuidString)"
                self.sendToHelper(id: internalId, method: "dashboard.get", params: [:])
            }
        }
    }

    // MARK: - Development UI Capture Hook (#if !VELA_PACKAGED)

    #if !VELA_PACKAGED
    private func validatedCaptureEnvironment() -> (captureURL: URL, homeURL: URL)? {
        guard let capDir = ProcessInfo.processInfo.environment["VELA_CAPTURE_DIRECTORY"],
              !capDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let vHome = ProcessInfo.processInfo.environment["VELA_HOME"],
              !vHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let captureDirURL = URL(fileURLWithPath: (capDir as NSString).expandingTildeInPath, isDirectory: true).resolvingSymlinksInPath().standardized
        let homeURL = URL(fileURLWithPath: (vHome as NSString).expandingTildeInPath, isDirectory: true).resolvingSymlinksInPath().standardized
        let fixtureURL = homeURL.appendingPathComponent(".vela-ui-fixture.json")

        guard let handle = try? FileHandle(forReadingFrom: fixtureURL) else {
            return nil
        }
        defer { try? handle.close() }

        let data: Data
        if #available(macOS 10.15.4, *) {
            do {
                data = try handle.read(upToCount: 4097) ?? Data()
            } catch {
                return nil
            }
        } else {
            data = handle.readData(ofLength: 4097)
        }
        guard !data.isEmpty,
              data.count <= 4096,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let format = json["format"] as? String,
              format == "vela-ui-fixture-v1",
              let syntheticNum = json["synthetic"] as? NSNumber,
              CFGetTypeID(syntheticNum) == CFBooleanGetTypeID(),
              syntheticNum.boolValue == true else {
            return nil
        }
        return (captureDirURL, homeURL)
    }

    @objc private func captureTestScreenshot() {
        guard let (captureURL, _) = validatedCaptureEnvironment() else {
            return
        }
        guard let webView = self.webView else { return }

        let metadataScript = """
        (function() {
            function bound(s, max) {
                if (s === null || s === undefined) return '';
                var str = typeof s === 'string' ? s : (s && typeof s.baseVal === 'string' ? s.baseVal : '');
                return str.length > max ? str.slice(0, max) : str;
            }
            function matchesPseudo(el, pseudo) {
                try {
                    if (el && el.matches) return el.matches(pseudo);
                    if (el && el.webkitMatchesSelector) return el.webkitMatchesSelector(pseudo);
                } catch (e) {}
                return false;
            }
            var page = bound(document.body && document.body.dataset && document.body.dataset.page !== undefined ? document.body.dataset.page : (document.body ? document.body.getAttribute('data-page') : ''), 200);
            var nav = [];
            var links = document.querySelectorAll('.nav-link');
            var limit = Math.min(links.length, 32);
            for (var i = 0; i < limit; i++) {
                var el = links[i];
                var dp = el.dataset && el.dataset.page !== undefined ? el.dataset.page : el.getAttribute('data-page');
                var ac = el.getAttribute('aria-current');
                var bg = '';
                try {
                    var cs = window.getComputedStyle(el);
                    if (cs && cs.backgroundColor) { bg = cs.backgroundColor; }
                } catch (e) {}
                nav.push({
                    page: bound(dp, 200),
                    className: bound(el.className, 200),
                    ariaCurrent: ac !== null ? bound(ac, 200) : null,
                    backgroundColor: bound(bg, 200),
                    hovered: matchesPseudo(el, ':hover'),
                    focused: matchesPseudo(el, ':focus'),
                    focusVisible: matchesPseudo(el, ':focus-visible')
                });
            }
            var active = null;
            var ae = document.activeElement;
            if (ae) {
                active = {
                    tagName: bound(ae.tagName, 100),
                    id: bound(ae.id, 200),
                    className: bound(ae.className, 200)
                };
                var aep = ae.dataset && ae.dataset.page !== undefined ? ae.dataset.page : ae.getAttribute('data-page');
                if (aep !== null && aep !== undefined) {
                    active['data-page'] = bound(aep, 200);
                }
            }
            var vp = {
                innerWidth: typeof window.innerWidth === 'number' ? window.innerWidth : 0,
                innerHeight: typeof window.innerHeight === 'number' ? window.innerHeight : 0,
                devicePixelRatio: typeof window.devicePixelRatio === 'number' ? window.devicePixelRatio : 1
            };
            return {
                page: page,
                navigation: nav,
                activeElement: active,
                viewport: vp
            };
        })()
        """

        webView.evaluateJavaScript(metadataScript) { [weak self] beforeResult, beforeError in
            guard let self = self, let webView = self.webView else { return }
            if let beforeError = beforeError {
                fputs("Vela capture: failed to collect before-metadata: \(beforeError.localizedDescription)\n", stderr)
            }
            let beforeObj = beforeResult as? [String: Any]

            let allowedPages: Set<String> = [
                "agents", "workflows", "setup", "memory", "usage", "improve", "lab", "inbox", "settings"
            ]
            let rawPage = (beforeObj?["page"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let page = allowedPages.contains(rawPage) ? rawPage : "dashboard"

            let captureId = UUID().uuidString
            let baseName = "vela-\(page)-\(captureId)"
            let pngFileURL = captureURL.appendingPathComponent("\(baseName).png").standardized
            let jsonFileURL = captureURL.appendingPathComponent("\(baseName).json").standardized

            guard pngFileURL.deletingLastPathComponent().path == captureURL.path,
                  jsonFileURL.deletingLastPathComponent().path == captureURL.path else {
                fputs("Vela capture: invalid target destination\n", stderr)
                return
            }

            let config = WKSnapshotConfiguration()
            webView.takeSnapshot(with: config) { image, snapshotError in
                if let image = image, snapshotError == nil {
                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        do {
                            try FileManager.default.createDirectory(at: captureURL, withIntermediateDirectories: true)
                            try pngData.write(to: pngFileURL, options: .withoutOverwriting)
                            fputs("Vela capture: saved snapshot to \(pngFileURL.path)\n", stderr)
                        } catch {
                            fputs("Vela capture: failed to write file: \(error.localizedDescription)\n", stderr)
                        }
                    } else {
                        fputs("Vela capture: PNG encoding failed\n", stderr)
                    }
                } else {
                    fputs("Vela capture: snapshot failed: \(snapshotError?.localizedDescription ?? "unknown error")\n", stderr)
                }

                webView.evaluateJavaScript(metadataScript) { afterResult, afterError in
                    if let afterError = afterError {
                        fputs("Vela capture: failed to collect after-metadata: \(afterError.localizedDescription)\n", stderr)
                    }
                    guard let before = beforeObj, let after = afterResult as? [String: Any] else {
                        fputs("Vela capture: incomplete metadata, skipped sidecar write\n", stderr)
                        return
                    }
                    let sidecar: [String: Any] = [
                        "format": "vela-ui-capture-metadata-v1",
                        "before": before,
                        "after": after
                    ]
                    guard let jsonData = try? JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys]) else {
                        fputs("Vela capture: metadata JSON serialization failed\n", stderr)
                        return
                    }
                    do {
                        try FileManager.default.createDirectory(at: captureURL, withIntermediateDirectories: true)
                        try jsonData.write(to: jsonFileURL, options: .withoutOverwriting)
                        fputs("Vela capture: saved metadata to \(jsonFileURL.path)\n", stderr)
                    } catch {
                        fputs("Vela capture: failed to write metadata file: \(error.localizedDescription)\n", stderr)
                    }
                }
            }
        }
    }
    #endif
}

// MARK: - Main Runner

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = VelaApplicationDelegate()
app.delegate = delegate
app.run()
