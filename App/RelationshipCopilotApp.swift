import SwiftUI
import SwiftData

@main
struct RelationshipCopilotApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AuthenticationService())
                .environment(ThemeManager())
        }
        .modelContainer(for: [
            User.self,
            Profile.self,
            Promise.self,
            RecordingSession.self
        ])
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 配置Firebase或其他服务
        configureAppearance()
        return true
    }
    
    private func configureAppearance() {
        // 全局外观配置
        UINavigationBar.appearance().tintColor = .systemBlue
        UITabBar.appearance().tintColor = .systemBlue
    }
}
