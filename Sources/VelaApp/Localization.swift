import Foundation
import VelaCore

// MARK: - Canonical Locale Support

public enum VelaLocale {
    public static let zhCN = VelaPreferences.defaultLocale
    public static let en = "en"
    public static let defaultLocale = VelaPreferences.defaultLocale
    public static let supportedLocales: Set<String> = VelaPreferences.supportedLocales

    public static func canonical(_ raw: String?) -> String {
        guard let raw = raw, supportedLocales.contains(raw) else {
            return defaultLocale
        }
        return raw
    }

    public static func isValid(_ raw: String?) -> Bool {
        guard let raw = raw else {
            return false
        }
        return supportedLocales.contains(raw)
    }
}

// MARK: - Explicit Native Locale Dictionary & Formatter

public enum VelaLocalization {
    private static let table: [String: [String: String]] = [
        // Navigation Glossary (shared contract with renderer)
        "nav.sessions": [
            VelaLocale.zhCN: "会话",
            VelaLocale.en: "Sessions"
        ],
        "nav.workflows": [
            VelaLocale.zhCN: "工作流",
            VelaLocale.en: "Workflows"
        ],
        "nav.approvals": [
            VelaLocale.zhCN: "待办审批",
            VelaLocale.en: "Approvals"
        ],
        "nav.memory": [
            VelaLocale.zhCN: "工程记忆",
            VelaLocale.en: "Memory"
        ],
        "nav.setup": [
            VelaLocale.zhCN: "配置与资产",
            VelaLocale.en: "Setup"
        ],
        "nav.usage": [
            VelaLocale.zhCN: "用量追踪",
            VelaLocale.en: "Usage"
        ],
        "nav.improve": [
            VelaLocale.zhCN: "调优建议",
            VelaLocale.en: "Improve"
        ],
        "nav.lab": [
            VelaLocale.zhCN: "对照实验",
            VelaLocale.en: "Lab"
        ],
        "nav.settings": [
            VelaLocale.zhCN: "设置",
            VelaLocale.en: "Settings"
        ],

        // Language Names (always 简体中文 / English)
        "language.zhCN": [
            VelaLocale.zhCN: "简体中文",
            VelaLocale.en: "简体中文"
        ],
        "language.en": [
            VelaLocale.zhCN: "English",
            VelaLocale.en: "English"
        ],
        "menu.language": [
            VelaLocale.zhCN: "语言",
            VelaLocale.en: "Language"
        ],

        // App Menu
        "menu.app.about": [
            VelaLocale.zhCN: "关于 Vela",
            VelaLocale.en: "About Vela"
        ],
        "menu.app.settings": [
            VelaLocale.zhCN: "设置...",
            VelaLocale.en: "Settings..."
        ],
        "menu.app.hide": [
            VelaLocale.zhCN: "隐藏 Vela",
            VelaLocale.en: "Hide Vela"
        ],
        "menu.app.hideOthers": [
            VelaLocale.zhCN: "隐藏其他",
            VelaLocale.en: "Hide Others"
        ],
        "menu.app.showAll": [
            VelaLocale.zhCN: "显示全部",
            VelaLocale.en: "Show All"
        ],
        "menu.app.quit": [
            VelaLocale.zhCN: "退出 Vela",
            VelaLocale.en: "Quit Vela"
        ],

        // Edit Menu
        "menu.edit": [
            VelaLocale.zhCN: "编辑",
            VelaLocale.en: "Edit"
        ],
        "menu.edit.undo": [
            VelaLocale.zhCN: "撤销",
            VelaLocale.en: "Undo"
        ],
        "menu.edit.redo": [
            VelaLocale.zhCN: "重做",
            VelaLocale.en: "Redo"
        ],
        "menu.edit.cut": [
            VelaLocale.zhCN: "剪切",
            VelaLocale.en: "Cut"
        ],
        "menu.edit.copy": [
            VelaLocale.zhCN: "复制",
            VelaLocale.en: "Copy"
        ],
        "menu.edit.paste": [
            VelaLocale.zhCN: "粘贴",
            VelaLocale.en: "Paste"
        ],
        "menu.edit.selectAll": [
            VelaLocale.zhCN: "全选",
            VelaLocale.en: "Select All"
        ],

        // View Menu
        "menu.view": [
            VelaLocale.zhCN: "视图",
            VelaLocale.en: "View"
        ],
        "menu.view.search": [
            VelaLocale.zhCN: "搜索工程上下文...",
            VelaLocale.en: "Search Engineering Context..."
        ],

        // Window Menu
        "menu.window": [
            VelaLocale.zhCN: "窗口",
            VelaLocale.en: "Window"
        ],
        "menu.window.miniaturize": [
            VelaLocale.zhCN: "最小化",
            VelaLocale.en: "Minimize"
        ],
        "menu.window.zoom": [
            VelaLocale.zhCN: "缩放",
            VelaLocale.en: "Zoom"
        ],
        "menu.window.mainWindow": [
            VelaLocale.zhCN: "主窗口",
            VelaLocale.en: "Main Window"
        ],

        // Dev Menu (#if !VELA_PACKAGED)
        "menu.dev": [
            VelaLocale.zhCN: "开发",
            VelaLocale.en: "Development"
        ],
        "menu.dev.capture": [
            VelaLocale.zhCN: "保存测试截图",
            VelaLocale.en: "Save Test Screenshot"
        ],

        // Status Bar Menu
        "status.open": [
            VelaLocale.zhCN: "打开 Vela",
            VelaLocale.en: "Open Vela"
        ],
        "status.ready": [
            VelaLocale.zhCN: "状态: 就绪",
            VelaLocale.en: "Status: Ready"
        ],
        "status.summary": [
            VelaLocale.zhCN: "运行中: {running} · 待审批: {approvals}",
            VelaLocale.en: "Running: {running} · Approvals: {approvals}"
        ],
        "status.inbox": [
            VelaLocale.zhCN: "待办审批",
            VelaLocale.en: "Approvals"
        ],
        "status.refresh": [
            VelaLocale.zhCN: "刷新数据",
            VelaLocale.en: "Refresh Data"
        ],
        "status.quit": [
            VelaLocale.zhCN: "退出 Vela",
            VelaLocale.en: "Quit Vela"
        ],

        // About Alert
        "about.title": [
            VelaLocale.zhCN: "Vela 0.1.0",
            VelaLocale.en: "Vela 0.1.0"
        ],
        "about.informative": [
            VelaLocale.zhCN: "The engineering layer for coding agents.\n本地优先 · 无遥测 · 确定性架构",
            VelaLocale.en: "The engineering layer for coding agents.\nLocal-first · Zero telemetry · Deterministic architecture"
        ],
        "common.ok": [
            VelaLocale.zhCN: "确定",
            VelaLocale.en: "OK"
        ],

        // Language Switch Alert
        "alert.languageChangeFailed.title": [
            VelaLocale.zhCN: "无法更改语言",
            VelaLocale.en: "Unable to Change Language"
        ],
        "alert.languageChangeFailed.message": [
            VelaLocale.zhCN: "保存语言设置失败：{error}",
            VelaLocale.en: "Failed to save language setting: {error}"
        ],

        // Open Panel
        "panel.chooseProject.title": [
            VelaLocale.zhCN: "选择项目",
            VelaLocale.en: "Choose Project"
        ],
        "panel.chooseProject.prompt": [
            VelaLocale.zhCN: "选择项目",
            VelaLocale.en: "Choose Project"
        ],
        "panel.chooseProject.message": [
            VelaLocale.zhCN: "选择一个本地 Git 或工程目录以连接到 Vela",
            VelaLocale.en: "Select a local Git or project directory to connect to Vela"
        ],

        // Notifications
        "notif.approval.title": [
            VelaLocale.zhCN: "需要人工审批",
            VelaLocale.en: "Human Approval Required"
        ],
        "notif.approval.bodySingle": [
            VelaLocale.zhCN: "[{title}] 等待操作审批",
            VelaLocale.en: "[{title}] awaiting approval"
        ],
        "notif.approval.bodyMulti": [
            VelaLocale.zhCN: "有 {count} 项操作等待审批",
            VelaLocale.en: "{count} operations awaiting approval"
        ],
        "notif.completed.statusUpdateTitle": [
            VelaLocale.zhCN: "工程状态更新",
            VelaLocale.en: "Project Status Update"
        ],
        "notif.completed.statusUpdateBody": [
            VelaLocale.zhCN: "有 {count} 项完成状态更新",
            VelaLocale.en: "{count} completion updates"
        ],
        "notif.completed.inferredTitle": [
            VelaLocale.zhCN: "会话完成事件",
            VelaLocale.en: "Session Completed Event"
        ],
        "notif.completed.inferredBody": [
            VelaLocale.zhCN: "[{title}] 日志记录了完成事件",
            VelaLocale.en: "[{title}] log recorded completion event"
        ],
        "notif.completed.workflowTitle": [
            VelaLocale.zhCN: "工作流已完成",
            VelaLocale.en: "Workflow Completed"
        ],
        "notif.completed.workflowBody": [
            VelaLocale.zhCN: "[{title}] 工作流执行成功",
            VelaLocale.en: "[{title}] workflow executed successfully"
        ],
        "notif.completed.taskTitle": [
            VelaLocale.zhCN: "任务已完成",
            VelaLocale.en: "Task Completed"
        ],
        "notif.completed.taskBody": [
            VelaLocale.zhCN: "[{title}] 任务完成",
            VelaLocale.en: "[{title}] task completed"
        ],
        "notif.error.statusUpdateTitle": [
            VelaLocale.zhCN: "工程状态更新",
            VelaLocale.en: "Project Status Update"
        ],
        "notif.error.statusUpdateBody": [
            VelaLocale.zhCN: "有 {count} 项异常或错误更新",
            VelaLocale.en: "{count} error or failure updates"
        ],
        "notif.error.inferredTitle": [
            VelaLocale.zhCN: "会话日志异常",
            VelaLocale.en: "Session Log Anomaly"
        ],
        "notif.error.inferredBody": [
            VelaLocale.zhCN: "[{title}] 日志记录了错误或中断",
            VelaLocale.en: "[{title}] log recorded error or interruption"
        ],
        "notif.error.workflowTitle": [
            VelaLocale.zhCN: "工作流执行失败",
            VelaLocale.en: "Workflow Execution Failed"
        ],
        "notif.error.workflowBody": [
            VelaLocale.zhCN: "[{title}] 遇到执行错误",
            VelaLocale.en: "[{title}] encountered an execution error"
        ],
        "notif.error.taskTitle": [
            VelaLocale.zhCN: "任务遇到错误",
            VelaLocale.en: "Task Encountered an Error"
        ],
        "notif.error.taskBody": [
            VelaLocale.zhCN: "[{title}] 遇到错误或异常",
            VelaLocale.en: "[{title}] encountered an error or exception"
        ],

        // Web Error Page HTML
        "error.html.title": [
            VelaLocale.zhCN: "无法加载 Vela 用户界面资源",
            VelaLocale.en: "Unable to Load Vela User Interface"
        ],
        "error.html.body": [
            VelaLocale.zhCN: "未找到 Contents/Resources/UI/index.html 或 Bundle.module/Resources/UI/index.html。",
            VelaLocale.en: "Contents/Resources/UI/index.html or Bundle.module/Resources/UI/index.html not found."
        ],

        // Host & RPC Errors
        "error.helperTerminated": [
            VelaLocale.zhCN: "Vela 辅助服务已退出",
            VelaLocale.en: "Vela helper service terminated"
        ],
        "error.helperProcessTerminated": [
            VelaLocale.zhCN: "Vela 辅助进程已终止",
            VelaLocale.en: "Vela helper process terminated"
        ],
        "error.bufferOverflow": [
            VelaLocale.zhCN: "Vela 辅助服务输出超出 32 MiB 限制，请求已拒绝并重置连接",
            VelaLocale.en: "Vela helper output exceeded 32 MiB limit; request rejected and connection reset"
        ],
        "error.maxPendingRequests": [
            VelaLocale.zhCN: "达到最大并发请求限制 (128)",
            VelaLocale.en: "Maximum concurrent request limit reached (128)"
        ],
        "error.helperUnavailable": [
            VelaLocale.zhCN: "Vela 辅助程序 (vela) 不可用或未找到。请检查应用程序打包完整性。",
            VelaLocale.en: "Vela helper executable (vela) is unavailable or not found. Please check application bundle integrity."
        ],
        "error.serializationFailed": [
            VelaLocale.zhCN: "请求数据序列化失败",
            VelaLocale.en: "Failed to serialize request payload"
        ],
        "error.timeout": [
            VelaLocale.zhCN: "请求超时 ({method})",
            VelaLocale.en: "Request timed out ({method})"
        ],
        "error.stdinWriteFailed": [
            VelaLocale.zhCN: "无法写入 Vela 辅助服务: {error}",
            VelaLocale.en: "Failed to write to Vela helper service: {error}"
        ],
        "error.missingMethod": [
            VelaLocale.zhCN: "缺少 method 字段",
            VelaLocale.en: "Missing method field"
        ],
        "error.invalidParams": [
            VelaLocale.zhCN: "params 必须为有效字典对象",
            VelaLocale.en: "params must be a valid dictionary object"
        ],
        "error.unsupportedMethod": [
            VelaLocale.zhCN: "不支持的 RPC 方法：{method}",
            VelaLocale.en: "Unsupported RPC method: {method}"
        ],
        "error.launchAtLoginAppRequired": [
            VelaLocale.zhCN: "开机自启功能需要以 macOS 应用程序包 (.app) 形式运行",
            VelaLocale.en: "Launch at login requires running as a macOS application bundle (.app)"
        ],
        "error.launchAtLoginConfigFailed": [
            VelaLocale.zhCN: "偏好设置已保存，但开机登录项未同步更新（{error}）。可在 macOS「系统设置 > 通用 > 登录项」中核对。",
            VelaLocale.en: "Preferences saved, but the login item could not be updated ({error}). You can verify this in macOS System Settings > General > Login Items."
        ],
        "error.launchAtLoginOSRequired": [
            VelaLocale.zhCN: "开机自启需要 macOS 13 及更高版本系统支持",
            VelaLocale.en: "Launch at login requires macOS 13 or later"
        ],
        "error.notificationAppRequired": [
            VelaLocale.zhCN: "系统通知功能需要以 macOS 应用程序包 (.app) 形式运行",
            VelaLocale.en: "System notifications require running as a macOS application bundle (.app)"
        ],
        "error.notificationAuthFailed": [
            VelaLocale.zhCN: "申请系统通知权限失败: {error}",
            VelaLocale.en: "Failed to request notification permission: {error}"
        ],
        "error.notificationDenied": [
            VelaLocale.zhCN: "系统通知权限已被用户拒绝，请在 macOS 系统设置中开启",
            VelaLocale.en: "Notification permission was denied by user; please enable it in macOS System Settings"
        ],
        "error.soundSingleKind": [
            VelaLocale.zhCN: "system.previewNotificationSound 仅接受包含单个 kind 参数的请求",
            VelaLocale.en: "system.previewNotificationSound accepts only a request with a single kind parameter"
        ],
        "error.soundMissingKind": [
            VelaLocale.zhCN: "缺少 kind 参数或类型错误",
            VelaLocale.en: "Missing or invalid kind parameter"
        ],
        "error.soundUnsupportedKind": [
            VelaLocale.zhCN: "不支持的提示音类型：{kind}",
            VelaLocale.en: "Unsupported notification sound kind: {kind}"
        ],
        "error.resourceDirUnavailable": [
            VelaLocale.zhCN: "无法访问应用资源目录",
            VelaLocale.en: "Unable to access application resource directory"
        ],
        "error.soundFileNotFound": [
            VelaLocale.zhCN: "未找到提示音文件或无法加载：{filename}",
            VelaLocale.en: "Notification sound file not found or failed to load: {filename}"
        ],
        "error.soundPlaybackFailed": [
            VelaLocale.zhCN: "播放提示音失败：{filename}",
            VelaLocale.en: "Failed to play notification sound: {filename}"
        ],
        "error.openExternalHttpsOnly": [
            VelaLocale.zhCN: "system.openExternal 仅支持 HTTPS 链接",
            VelaLocale.en: "system.openExternal supports only HTTPS URLs"
        ],
        "error.missingPath": [
            VelaLocale.zhCN: "缺少路径参数",
            VelaLocale.en: "Missing path parameter"
        ],
        "error.fileNotFound": [
            VelaLocale.zhCN: "文件不存在：{path}",
            VelaLocale.en: "File does not exist: {path}"
        ],
        "error.accessDenied": [
            VelaLocale.zhCN: "拒绝访问：路径不在 Vela 存储或已知项目范围内",
            VelaLocale.en: "Access denied: path is outside Vela store or known projects"
        ],
        "error.unknownSystemMethod": [
            VelaLocale.zhCN: "未知系统方法：{method}",
            VelaLocale.en: "Unknown system method: {method}"
        ],
        "error.invalidLocale": [
            VelaLocale.zhCN: "设置包含无效的语言代码",
            VelaLocale.en: "Settings contain an invalid locale"
        ],
        "panel.saveMemoryArchive.title": [
            VelaLocale.zhCN: "导出工程记忆归档",
            VelaLocale.en: "Export Memory Archive"
        ],
        "panel.saveMemoryArchive.prompt": [
            VelaLocale.zhCN: "存储归档",
            VelaLocale.en: "Save Archive"
        ],
        "panel.saveMemoryArchive.message": [
            VelaLocale.zhCN: "将导出的工程记忆归档保存为 JSON 文件（明文存储，不包含私密与全局记忆）",
            VelaLocale.en: "Save exported memory archive as a JSON file (plaintext, excludes private and global memories)"
        ],
        "panel.saveLibraryExport.title": [
            VelaLocale.zhCN: "导出知识库文档 (Markdown)",
            VelaLocale.en: "Export Library Document (Markdown)"
        ],
        "panel.saveLibraryExport.prompt": [
            VelaLocale.zhCN: "存储文档",
            VelaLocale.en: "Save Document"
        ],
        "panel.saveLibraryExport.message": [
            VelaLocale.zhCN: "将受审知识库文档保存为 Markdown 文件（不修改原始源文件）",
            VelaLocale.en: "Save reviewed library document as a Markdown file (without modifying source files)"
        ],
        "error.invalidArchivePayload": [
            VelaLocale.zhCN: "归档数据格式错误，必须为包含有效归档的字典对象",
            VelaLocale.en: "Invalid archive payload; must be an object containing valid archive data"
        ],
        "error.invalidArchiveFormat": [
            VelaLocale.zhCN: "不支持的归档格式，必须为 vela.memory-archive",
            VelaLocale.en: "Unsupported archive format; must be vela.memory-archive"
        ],
        "error.unsupportedArchiveVersion": [
            VelaLocale.zhCN: "不支持的归档版本，目前仅支持版本 1",
            VelaLocale.en: "Unsupported archive version; currently only version 1 is supported"
        ],
        "error.archiveSizeLimitExceeded": [
            VelaLocale.zhCN: "归档文件超出 1 MiB 大小限制",
            VelaLocale.en: "Archive file exceeds 1 MiB size limit"
        ]
    ]

    public static func string(_ key: String, locale: String, placeholders: [String: String] = [:]) -> String {
        let canonical = VelaLocale.canonical(locale)
        let template = table[key]?[canonical] ?? table[key]?[VelaLocale.defaultLocale] ?? key
        if placeholders.isEmpty {
            return template
        }
        var formatted = template
        for (placeholder, value) in placeholders {
            formatted = formatted.replacingOccurrences(of: "{\(placeholder)}", with: value)
        }
        return formatted
    }
}
