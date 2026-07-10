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
        button.image = Self.renderIcon(
            percentage: usage.map { $0.primaryPercentage },
            hasError: lastError != nil && usage == nil
        )
    }

    /// Draws the Codex status icon: a `‹/›` code glyph plus the 5h-window
    /// percentage. Rendered as a template image so it stays monochrome and
    /// adapts to menu bar appearance automatically — visually distinct from
    /// the colored Claude metric items.
    private static func renderIcon(percentage: Double?, hasError: Bool) -> NSImage {
        let text: String
        if hasError {
            text = "–"
        } else if let percentage = percentage {
            text = "\(Int(min(max(percentage, 0), 999)))%"
        } else {
            text = "…"
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let symbol = NSImage(
            systemSymbolName: "chevron.left.forwardslash.chevron.right",
            accessibilityDescription: "Codex"
        )?.withSymbolConfiguration(symbolConfig)
        let symbolSize = symbol?.size ?? .zero

        let spacing: CGFloat = 3
        let height: CGFloat = 18
        let width = symbolSize.width + spacing + textSize.width + 2

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        symbol?.draw(in: NSRect(
            x: 1,
            y: (height - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        ))
        (text as NSString).draw(
            at: NSPoint(x: 1 + symbolSize.width + spacing, y: (height - textSize.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
