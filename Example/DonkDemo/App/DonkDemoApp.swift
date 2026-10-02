import Donk
import SwiftUI
import UserNotifications

@main
struct DonkDemoApp: App {
    @UIApplicationDelegateAdaptor(DemoAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DemoMenuView()
                .environmentObject(PushInbox.shared)
        }
    }
}

final class DemoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Donk.installCrashReporter()
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        var configuration = DonkConfiguration()
        configuration.push.templates = DemoPushTemplates.all
        configuration.storage.userDefaultsSuites = ["group.donk.demo.suite"]
        if let tools = UserDefaults.standard.string(forKey: "DonkTools") {
            configuration.tools = Set(tools.split(separator: ",").compactMap { DonkTool(rawValue: String($0)) })
        }
        Donk.start(configuration)
        DemoLaunchOptions.apply()
        DemoDiagnostics.applyLaunchArguments()
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        DonkPush.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        PushInbox.shared.record(source: "didReceiveRemoteNotification", userInfo: userInfo)
        completionHandler(.newData)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        PushInbox.shared.record(source: "willPresent", userInfo: notification.request.content.userInfo)
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        PushInbox.shared.record(source: "didReceive (\(response.actionIdentifier))", userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }
}
