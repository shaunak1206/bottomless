import AppIntents
import UIKit
import BottomlessCore

/// "Sync Photos" for Shortcuts: a Personal Automation (e.g. "When charger connects") can run it every day.
struct SyncPhotosIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Photos"
    static var description = IntentDescription("Backs up new photos and videos to Bottomless and refreshes the library.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let services = AppServices.shared else {
            return .result(dialog: "Bottomless is not set up on this iPhone yet.")
        }
        let r = await services.runAll(deadline: Date().addingTimeInterval(25))
        let waiting = services.catalog.backupCounts().filter { $0.key != .committed }.values.reduce(0, +)
        if waiting > 0 {
            return .result(dialog: "Backed up \(r.committed) item(s). \(waiting) still uploading in the background.")
        }
        return .result(dialog: "Backed up \(r.committed) item(s). Everything is safe.")
    }
}

/// For two Personal Automations, "When charger connects" and "When battery level rises above 80%": backs up
/// new photos once the iPhone is charging and at or above the battery level, without opening the app. Uploads it
/// starts keep going after it returns; 100 or more waiting are split over two days (DailyAllowance).
struct BackUpWhileChargingIntent: AppIntent {
    static var title: LocalizedStringResource = "Back Up While Charging"
    static var description = IntentDescription("Backs up new photos and videos when the iPhone is charging and at least at the battery level given. Use it in automations for \"When charger connects\" and \"When battery level rises above\". With 100 or more waiting, half go today and the rest tomorrow.")
    static var openAppWhenRun = false

    @Parameter(title: "Minimum battery (%)", default: 80)
    var minimumBattery: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let services = AppServices.shared else {
            return .result(dialog: "Bottomless is not set up on this iPhone yet.")
        }
        let (charging, level) = await MainActor.run { () -> (Bool, Int) in
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            let level = UIDevice.current.batteryLevel  // -1 when unknown (the simulator)
            return (state == .charging || state == .full || level < 0, level < 0 ? 100 : Int((level * 100).rounded()))
        }
        guard charging else { return .result(dialog: "Not charging, so nothing was backed up.") }
        let floor = min(max(minimumBattery, 0), 100)
        guard level >= floor else {
            return .result(dialog: "Battery is at \(level)%. Backing up starts at \(floor)%.")
        }
        let r = await services.runAll(deadline: Date().addingTimeInterval(25))
        let counts = services.catalog.backupCounts()
        let waiting = counts[.new] ?? 0
        let moving = (counts[.prepared] ?? 0) + (counts[.uploading] ?? 0) + (counts[.uploaded] ?? 0)
        let tomorrow = services.allowance.leftForTomorrow(waiting: waiting)
        var says = moving + waiting == 0 ? "Backed up \(r.committed) item(s). Everything is safe."
            : "Backed up \(r.committed) item(s); \(moving) more are uploading in the background."
        if tomorrow > 0 { says += " \(tomorrow) go tomorrow (100 or more are split over two days)." }
        return .result(dialog: "\(says)")
    }
}

struct OpenFreeUpSpaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Free Up Space"
    static var description = IntentDescription("Opens Bottomless to remove backed-up photos from this iPhone.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "bottomless.openFreeUp")
        return .result()
    }
}

struct BottomlessShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncPhotosIntent(), phrases: ["Sync photos in \(.applicationName)", "Back up photos with \(.applicationName)"],
                    shortTitle: "Sync Photos", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: BackUpWhileChargingIntent(), phrases: ["Back up while charging with \(.applicationName)"],
                    shortTitle: "Back Up While Charging", systemImageName: "battery.100.bolt")
        AppShortcut(intent: OpenFreeUpSpaceIntent(), phrases: ["Free up space with \(.applicationName)"],
                    shortTitle: "Free Up Space", systemImageName: "externaldrive.badge.minus")
    }
}
