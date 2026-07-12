import Cocoa
import SwiftUI
import Combine

/// Independent menu bar controller for the OpenAI Codex usage tracker.
///
/// Deliberately separate from MenuBarManager's Claude metric/profile status
/// items (modelled on the peak-hours indicator): it owns its own status item,
/// refresh timer, popover, and data, and gates itself on its own settings
/// toggle + presence of ~/.codex/auth.json — never on Claude credentials.
final class CodexMenuBarController: NSObject, ObservableObject {
    @Published private(set) var usage: CodexUsage?
    @Published private(set) var lastError: CodexUsageError?
    @Published private(set) var isRefreshing = false

    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var popover: NSPopover?
    private var settingsObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var appearanceObserver: NSKeyValueObservation?
    private var lastAppearanceName: NSAppearance.Name?

    /// Unique autosave name so macOS/Ice persist position separately from the
    /// Claude items (see StatusBarUIManager.autosavePrefix scheme).
    private static let autosaveName: NSStatusItem.AutosaveName = "claudeUsageTracker.codex"

    private static let refreshInterval: TimeInterval = 60

    override init() {
        super.init()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .codexTrackerSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            CodexUsageService.shared.invalidateInstalledCache()
            self?.applySettings()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.statusItem != nil else { return }
            // Small delay so the network is back up after sleep
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self?.refresh()
            }
        }

        applySettings()
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    private func applySettings() {
        let enabled = SharedDataStore.shared.loadCodexTrackerEnabled()
            && CodexUsageService.shared.isCodexInstalled()
        if enabled {
            start()
        } else {
            cleanup()
        }
    }

    private func start() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        // NSStatusItem persists isVisible under its autosaveName — force it
        // back to true or a prior cmd-drag removal keeps the item hidden.
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "codex.title".localized
        }
        statusItem = item
        updateIcon()

        // Observe app-level appearance only — per-button effectiveAppearance
        // KVO re-fires on every button.image set and loops forever (see
        // StatusBarUIManager.observeAppearanceChanges).
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            guard let self = self else { return }
            let newName = change.newValue?.name
            guard newName != self.lastAppearanceName else { return }
            self.lastAppearanceName = newName
            DispatchQueue.main.async { self.updateIcon() }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refreshTimer?.tolerance = Self.refreshInterval * 0.1

        refresh()
        LoggingService.shared.logUIEvent("Codex menu bar tracker started")
    }

    func cleanup() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        appearanceObserver?.invalidate()
        appearanceObserver = nil
        popover?.close()
        popover = nil
        if let item = statusItem {
            if let button = item.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    // MARK: - Refresh

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                self.usage = try await CodexUsageService.shared.fetchUsage()
                self.lastError = nil
            } catch let error as CodexUsageError {
                self.lastError = error
                LoggingService.shared.logWarning("CodexMenuBarController: refresh failed — \(error.errorDescription ?? "unknown")")
            } catch {
                self.lastError = .networkError(error.localizedDescription)
            }
            self.isRefreshing = false
            self.updateIcon()
        }
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let existing = popover, existing.isShown {
            existing.close()
            popover = nil
            return
        }

        let pop = NSPopover()
        pop.behavior = .transient
        // Keep animation off: NSPopover animation triggers infinite layout
        // recursion with SwiftUI content on macOS 26+ (see MenuBarManager).
        pop.animates = false
        pop.contentViewController = NSHostingController(rootView: CodexPopoverView(controller: self))
        // Activate first so the popover appears over a full-screen Space.
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = pop
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "common.refresh".localized, action: #selector(contextMenuRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        if let window = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonRect)
            menu.popUp(positioning: nil, at: NSPoint(x: screenRect.origin.x, y: screenRect.origin.y), in: nil)
        }
    }

    @objc private func contextMenuRefresh() {
        refresh()
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let isDarkMode = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let window = usage?.menuBarWindow
        let image = Self.renderIcon(
            weeklyPercentage: window?.percentage,
            weeklyResetTime: window?.resetTime,
            weeklyWindowSeconds: window?.windowSeconds ?? 7 * 24 * 3600,
            isDarkMode: isDarkMode
        )
        image.isTemplate = false
        button.image = image
    }

    /// Draws the Codex status icon: the OpenAI mark inside a circular weekly
    /// progress ring — same geometry, status colors, and week-elapsed tick
    /// mark as the Claude metric's "Icon with Bar" ring style, so the two
    /// items read as siblings while the center mark tells them apart. While
    /// loading (or on error) only the background ring is drawn.
    private static func renderIcon(
        weeklyPercentage: Double?,
        weeklyResetTime: Date?,
        weeklyWindowSeconds: TimeInterval,
        isDarkMode: Bool
    ) -> NSImage {
        let circleSize: CGFloat = 22
        let totalWidth = circleSize + 1
        let foregroundColor: NSColor = isDarkMode ? .white : .black

        // OpenAI mark is full-bleed (no built-in padding like the Claude
        // tray template), so it needs a smaller box to sit inside the ring.
        let markBox: CGFloat = circleSize - 11
        let mark = NSImage(named: "OpenAIMark")?.tinted(with: foregroundColor)

        let statusColor: NSColor
        if let percentage = weeklyPercentage {
            switch UsageStatusCalculator.calculateStatus(
                usedPercentage: percentage,
                showRemaining: false,
                elapsedFraction: nil
            ) {
            case .safe: statusColor = .systemGreen
            case .moderate: statusColor = .systemOrange
            case .critical: statusColor = .systemRed
            }
        } else {
            statusColor = foregroundColor
        }

        let image = NSImage(size: NSSize(width: totalWidth, height: circleSize))
        image.lockFocus()
        defer { image.unlockFocus() }

        let center = NSPoint(x: 1 + circleSize / 2, y: circleSize / 2)
        let radius = (circleSize - 4.0) / 2

        // Background ring
        let bgArcPath = NSBezierPath()
        bgArcPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        foregroundColor.withAlphaComponent(0.15).setStroke()
        bgArcPath.lineWidth = 3.0
        bgArcPath.lineCapStyle = .round
        bgArcPath.stroke()

        // Weekly progress ring (clockwise from 12 o'clock)
        let fraction = CGFloat(min(max((weeklyPercentage ?? 0) / 100.0, 0), 1))
        if fraction > 0 {
            let arcPath = NSBezierPath()
            arcPath.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * fraction,
                clockwise: true
            )
            statusColor.setStroke()
            arcPath.lineWidth = 3.0
            arcPath.lineCapStyle = .round
            arcPath.stroke()
        }

        // Week-elapsed tick mark on the ring (clockwise from 12 o'clock),
        // pace-colored like the Claude ring's marker.
        if let elapsed = UsageStatusCalculator.elapsedFraction(
            resetTime: weeklyResetTime,
            duration: weeklyWindowSeconds,
            showRemaining: false
        ) {
            let tickAngle = (90 - 360 * CGFloat(elapsed)) * .pi / 180
            let innerR = radius - 2.0
            let outerR = radius + 2.0
            let tickPath = NSBezierPath()
            tickPath.move(to: NSPoint(
                x: center.x + innerR * cos(tickAngle),
                y: center.y + innerR * sin(tickAngle)
            ))
            tickPath.line(to: NSPoint(
                x: center.x + outerR * cos(tickAngle),
                y: center.y + outerR * sin(tickAngle)
            ))
            let pace = weeklyPercentage.flatMap {
                PaceStatus.calculate(usedPercentage: $0, elapsedFraction: elapsed)
            }
            (pace?.color ?? foregroundColor).setStroke()
            tickPath.lineWidth = 2.0
            tickPath.lineCapStyle = .round
            tickPath.stroke()
        }

        // OpenAI mark in the center (preserve its 18:17 aspect ratio)
        if let mark = mark {
            let markHeight = markBox * 17.0 / 18.0
            mark.draw(in: NSRect(
                x: center.x - markBox / 2,
                y: center.y - markHeight / 2,
                width: markBox,
                height: markHeight
            ))
        }

        return image
    }
}
