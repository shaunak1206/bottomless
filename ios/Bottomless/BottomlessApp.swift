import SwiftUI
import BackgroundTasks
import BottomlessCore

@main
struct BottomlessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .onChange(of: phase) { _, new in
            if new == .active { Task { await model.refresh(backup: true) } }
            if new == .background { BackgroundJobs.schedule() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundJobs.register()
        _ = AppServices.shared          // reconnects the background upload session early
        return true
    }

    /// iOS relaunched us because background uploads finished.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard let services = AppServices.shared else { completionHandler(); return }
        services.uploader.backgroundCompletion = completionHandler
        services.uploader.connect()
        Task { _ = await services.engine.run(deadline: Date().addingTimeInterval(20)) }
    }
}

/// Nightly backup while charging, plus a light refresh during the day.
enum BackgroundJobs {
    static let nightly = "com.shaunakkapur.bottomless.nightly"
    static let refresh = "com.shaunakkapur.bottomless.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: nightly, using: nil) { task in
            handle(task, deadline: Date().addingTimeInterval(25 * 60), backup: true)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refresh, using: nil) { task in
            handle(task, deadline: Date().addingTimeInterval(25), backup: true)
        }
    }

    static func schedule() {
        let processing = BGProcessingTaskRequest(identifier: nightly)
        processing.requiresExternalPower = true
        processing.requiresNetworkConnectivity = true
        var tonight = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 2), matchingPolicy: .nextTime) ?? Date()
        if tonight.timeIntervalSinceNow < 3600 { tonight = Date().addingTimeInterval(3600) }
        processing.earliestBeginDate = tonight
        try? BGTaskScheduler.shared.submit(processing)

        let appRefresh = BGAppRefreshTaskRequest(identifier: refresh)
        appRefresh.earliestBeginDate = Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(appRefresh)
    }

    private static func handle(_ task: BGTask, deadline: Date, backup: Bool) {
        schedule()
        guard let services = AppServices.shared else { task.setTaskCompleted(success: false); return }
        let work = Task {
            _ = await services.runAll(deadline: deadline, backup: backup)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
