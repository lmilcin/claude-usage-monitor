import AppKit
import ServiceManagement
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let service = UsageService()

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var snapshot: UsageSnapshot?
    private var lastError: Error?
    private var organizations: [Organization] = []
    private var activeOrganizationID: String?
    private var isRefreshing = false

    private var timer: Timer?
    private var retryTask: Task<Void, Never>?

    private static let usagePageURL = URL(string: "https://claude.ai/settings/usage")!

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        updateStatusButton()
        rebuildMenu()
        scheduleTimer()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        if !settings.hasCompletedSetup {
            Task { @MainActor in self.runFirstLaunchSetup() }
        } else {
            refreshNow()
        }
    }

    @objc private func systemDidWake() {
        // Give Wi-Fi a moment to reconnect.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.refreshNow()
        }
    }

    // MARK: Refresh

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(settings.refreshMinutes * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        timer.tolerance = min(30, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        retryTask?.cancel()
        rebuildMenu()

        let source = settings.dataSource
        let key = source == .claudeAI ? settings.sessionKey : nil
        let orgID = settings.organizationID

        Task {
            do {
                let result = try await service.fetch(source: source, sessionKey: key, preferredOrgID: orgID)
                snapshot = result.snapshot
                organizations = result.organizations
                activeOrganizationID = result.organizationID
                lastError = nil
            } catch {
                lastError = error
                scheduleRetryIfTransient(error)
            }
            isRefreshing = false
            updateStatusButton()
            rebuildMenu()
        }
    }

    /// Network blips (e.g. right after login / wake) shouldn't leave the icon stale for a full interval.
    private func scheduleRetryIfTransient(_ error: Error) {
        guard error is URLError, settings.refreshMinutes > 1 else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    private var isStale: Bool {
        guard let snapshot else { return true }
        return Date().timeIntervalSince(snapshot.fetchedAt) > TimeInterval(settings.refreshMinutes * 60 * 3)
    }

    private var errorNeedsAction: Bool {
        (lastError as? UsageError)?.needsUserAction ?? false
    }

    // MARK: Status button

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let windows: [UsageWindow?]
        switch settings.iconMode {
        case .both: windows = [snapshot?.session, snapshot?.weekly]
        case .session: windows = [snapshot?.session]
        case .weekly: windows = [snapshot?.weekly]
        }
        let fractions = windows.map { $0?.remainingFraction }
        button.image = StatusIcon.image(fractions: fractions, dimmed: isStale || errorNeedsAction)

        if settings.showPercentage, snapshot != nil {
            let text = windows.map { $0.map { "\($0.remainingPercent)%" } ?? "–" }.joined(separator: " · ")
            button.attributedTitle = NSAttributedString(
                string: " " + text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
        } else {
            button.title = ""
        }

        var tooltip = (snapshot?.allWindows ?? []).prefix(2)
            .map { "\($0.title): \($0.remainingPercent)% left" }
            .joined(separator: "\n")
        if let lastError { tooltip += (tooltip.isEmpty ? "" : "\n") + "⚠︎ " + lastError.localizedDescription }
        button.toolTip = tooltip.isEmpty ? "Claude Usage Monitor" : tooltip
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let now = Date()

        if let snapshot {
            for window in snapshot.allWindows {
                let item = NSMenuItem()
                item.view = UsageRowView(
                    title: window.title,
                    remainingFraction: window.remainingFraction,
                    usedPercent: window.usedPercent,
                    detail: UsageFormatting.resetDescription(window.resetsAt, now: now))
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        if let lastError {
            menu.addItem(infoItem("⚠︎ " + lastError.localizedDescription, color: .systemRed))
        }

        var status: String
        if isRefreshing {
            status = "Refreshing…"
        } else if let snapshot {
            status = "Updated \(UsageFormatting.ago(snapshot.fetchedAt, now: now))"
        } else {
            status = lastError == nil ? "Not updated yet" : "No data yet"
        }
        if settings.dataSource == .claudeAI,
           organizations.count > 1,
           let org = organizations.first(where: { $0.id == activeOrganizationID }) {
            status += " · \(org.name)"
        }
        menu.addItem(infoItem(status, color: .secondaryLabelColor))

        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh Now", #selector(refreshNow), key: "r"))
        menu.addItem(actionItem("Open claude.ai Usage Page", #selector(openUsagePage)))
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsMenu()
        menu.addItem(settingsItem)
        menu.addItem(actionItem("About Claude Usage Monitor", #selector(showAbout)))
        menu.addItem(actionItem("Quit", #selector(quit), key: "q"))
    }

    private func buildSettingsMenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        let sourceMenu = NSMenu()
        for source in DataSource.allCases {
            let item = actionItem(source.title, #selector(selectDataSource(_:)))
            item.representedObject = source.rawValue
            item.state = settings.dataSource == source ? .on : .off
            sourceMenu.addItem(item)
        }
        sub.addItem(submenuItem("Data Source", sourceMenu))

        if settings.dataSource == .claudeAI {
            sub.addItem(actionItem(settings.sessionKey == nil ? "Set Session Key…" : "Change Session Key…",
                                   #selector(promptForSessionKey)))
            if organizations.count > 1 {
                let orgMenu = NSMenu()
                for org in organizations {
                    let item = actionItem(org.name, #selector(selectOrganization(_:)))
                    item.representedObject = org.id
                    item.state = org.id == activeOrganizationID ? .on : .off
                    orgMenu.addItem(item)
                }
                sub.addItem(submenuItem("Organization", orgMenu))
            }
        }
        sub.addItem(.separator())

        let intervalMenu = NSMenu()
        for minutes in Settings.refreshChoices {
            let item = actionItem(minutes == 1 ? "1 minute" : "\(minutes) minutes", #selector(selectInterval(_:)))
            item.tag = minutes
            item.state = settings.refreshMinutes == minutes ? .on : .off
            intervalMenu.addItem(item)
        }
        sub.addItem(submenuItem("Refresh Every", intervalMenu))

        let iconMenu = NSMenu()
        for mode in IconMode.allCases {
            let item = actionItem(mode.title, #selector(selectIconMode(_:)))
            item.representedObject = mode.rawValue
            item.state = settings.iconMode == mode ? .on : .off
            iconMenu.addItem(item)
        }
        sub.addItem(submenuItem("Menu Bar Icon", iconMenu))

        let percent = actionItem("Show Percentage in Menu Bar", #selector(togglePercentage))
        percent.state = settings.showPercentage ? .on : .off
        sub.addItem(percent)

        sub.addItem(.separator())
        let login = actionItem("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        sub.addItem(login)
        return sub
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// A wrapping, non-interactive text row (menu item titles never wrap).
    private func infoItem(_ text: String, color: NSColor) -> NSMenuItem {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = color
        label.preferredMaxLayoutWidth = UsageRowView.width - 28
        let size = label.sizeThatFits(NSSize(width: UsageRowView.width - 28, height: 1000))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: UsageRowView.width, height: ceil(size.height) + 6))
        label.frame = NSRect(x: 14, y: 3, width: UsageRowView.width - 28, height: ceil(size.height))
        container.addSubview(label)
        let item = NSMenuItem()
        item.view = container
        return item
    }

    // MARK: Actions

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(Self.usagePageURL)
    }

    @objc private func selectDataSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let source = DataSource(rawValue: raw) else { return }
        settings.dataSource = source
        settings.hasCompletedSetup = true
        resetDataAndRefresh()
        if source == .claudeAI, settings.sessionKey == nil { promptForSessionKey() }
    }

    @objc private func selectOrganization(_ sender: NSMenuItem) {
        settings.organizationID = sender.representedObject as? String
        refreshNow()
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        settings.refreshMinutes = sender.tag
        scheduleTimer()
        rebuildMenu()
    }

    @objc private func selectIconMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = IconMode(rawValue: raw) else { return }
        settings.iconMode = mode
        updateStatusButton()
    }

    @objc private func togglePercentage() {
        settings.showPercentage.toggle()
        updateStatusButton()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            showAlert("Couldn't change Launch at Login",
                      "\(error.localizedDescription)\n\nTip: move the app to /Applications first.")
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func resetDataAndRefresh() {
        snapshot = nil
        lastError = nil
        organizations = []
        activeOrganizationID = nil
        Task {
            await service.reset()
            refreshNow()
        }
        updateStatusButton()
    }

    // MARK: Setup dialogs

    private func runFirstLaunchSetup() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to Claude Usage Monitor"
        alert.informativeText = """
            Where should usage be read from?

            • claude.ai session key — paste the sessionKey cookie from your browser. \
            Same data as claude.ai → Settings → Usage. Expires when you log out of claude.ai.

            • Claude Code login — reuse the login of the Claude Code CLI on this Mac \
            (macOS will ask to allow Keychain access; choose “Always Allow”). \
            Needs `claude` to be run every now and then to keep the token fresh.
            """
        alert.addButton(withTitle: "Use Session Key…")
        alert.addButton(withTitle: "Use Claude Code Login")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            settings.dataSource = .claudeAI
            settings.hasCompletedSetup = true
            promptForSessionKey()
        case .alertSecondButtonReturn:
            settings.dataSource = .claudeCode
            settings.hasCompletedSetup = true
            resetDataAndRefresh()
        default:
            lastError = UsageError.notConfigured("Not set up yet — open Settings → Data Source")
            updateStatusButton()
            rebuildMenu()
        }
    }

    @objc private func promptForSessionKey() {
        NSApp.activate(ignoringOtherApps: true)
        let hasKey = settings.sessionKey != nil

        let alert = NSAlert()
        alert.messageText = "claude.ai Session Key"
        alert.informativeText = """
            1. Log in to claude.ai in your browser.
            2. Open the developer tools (⌥⌘I; in Safari enable Settings → Advanced → \
            “Show features for web developers” first).
            3. Go to Storage (Safari) / Application (Chrome) → Cookies → https://claude.ai.
            4. Copy the value of the “sessionKey” cookie (starts with sk-ant-sid) and paste it below.

            The key is stored in your login Keychain and only ever sent to claude.ai.
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = hasKey ? "Leave empty to keep the current key" : "sk-ant-sid01-…"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingMiddle
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if hasKey { alert.addButton(withTitle: "Remove Key") }
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = Settings.normalizeSessionKey(field.stringValue)
            guard !key.isEmpty else { return }
            if !key.hasPrefix("sk-ant-") {
                showAlert("That doesn't look like a session key",
                          "claude.ai session keys start with “sk-ant-sid”. Saved anyway — check the menu for errors.")
            }
            settings.sessionKey = key
            settings.organizationID = nil
            resetDataAndRefresh()
        case .alertThirdButtonReturn:
            settings.sessionKey = nil
            resetDataAndRefresh()
        default:
            break
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Accessory apps have no menu bar of their own, but text fields only get
    /// ⌘V/⌘C/⌘X/⌘A/⌘Z through the main menu's key equivalents — so install a hidden Edit menu.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
