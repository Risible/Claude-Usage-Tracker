//
//  UpdateManager.swift
//  Claude Usage
//
//  Sparkle update manager wrapper
//

import Foundation
import Combine
import Sparkle

/// User driver delegate for Sparkle gentle reminders
final class UpdateUserDriver: NSObject, SPUStandardUserDriverDelegate {
    // REQUIRED: Enable gentle reminders for background apps
    var supportsGentleScheduledUpdateReminders: Bool {
        return true
    }

    // Handle showing scheduled updates
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // For background/menu bar apps, always show updates
        return true
    }

    // Customize how updates are shown
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate {
            LoggingService.shared.logInfo("Showing update alert for version \(update.displayVersionString)")
        }
    }

    // Optional: Handle when user interacts with update
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        LoggingService.shared.logInfo("User attended to update: \(update.displayVersionString)")
    }

    // Optional: Cleanup when update session finishes
    func standardUserDriverWillFinishUpdateSession() {
        LoggingService.shared.logInfo("Update session finished")
    }
}

/// Manages automatic updates using Sparkle framework
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    /// This fork is updated by rebuilding from source (Risible fork CI), not
    /// via upstream's Sparkle feed — accepting a stock release would silently
    /// replace every fork customization. Keep the updater dormant: never
    /// started, no scheduled checks, manual check is a no-op.
    private static let sparkleUpdatesEnabled = false

    private let updaterController: SPUStandardUpdaterController
    private let userDriver: UpdateUserDriver // Keep strong reference

    @Published private(set) var canCheckForUpdates: Bool = false
    @Published private(set) var automaticChecksEnabled: Bool

    private init() {
        // Create user driver delegate for gentle reminders
        userDriver = UpdateUserDriver()

        // Initialize Sparkle updater with user driver delegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: Self.sparkleUpdatesEnabled,
            updaterDelegate: nil,
            userDriverDelegate: userDriver
        )

        if Self.sparkleUpdatesEnabled {
            automaticChecksEnabled = updaterController.updater.automaticallyChecksForUpdates
            canCheckForUpdates = updaterController.updater.canCheckForUpdates
            LoggingService.shared.logInfo("Update manager initialized with gentle reminders")
        } else {
            automaticChecksEnabled = false
            canCheckForUpdates = false
            LoggingService.shared.logInfo("Update manager dormant (fork build — updates come from source)")
        }
    }

    /// Manually check for updates
    func checkForUpdates() {
        guard Self.sparkleUpdatesEnabled else {
            LoggingService.shared.logInfo("Update check ignored — updater is dormant in this fork build")
            return
        }
        updaterController.checkForUpdates(nil)
        LoggingService.shared.logInfo("Manual update check triggered")
    }

    /// Toggle automatic update checks
    func setAutomaticChecksEnabled(_ enabled: Bool) {
        guard Self.sparkleUpdatesEnabled else { return }
        updaterController.updater.automaticallyChecksForUpdates = enabled
        automaticChecksEnabled = enabled
        DataStore.shared.userDefaults.set(enabled, forKey: "SUEnableAutomaticChecks")
        LoggingService.shared.logInfo("Automatic updates: \(enabled)")
    }

    /// Get last update check date
    var lastUpdateCheckDate: Date? {
        return updaterController.updater.lastUpdateCheckDate
    }
}
