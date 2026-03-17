import SwiftUI
import SwiftData

@main
struct RelationshipCopilotApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("darkMode") private var darkMode = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AuthenticationService())
                .preferredColorScheme(darkMode ? .dark : .light)
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
        configureAppearance()
        return true
    }
    
    private func configureAppearance() {
        UINavigationBar.appearance().tintColor = .systemBlue
        UITabBar.appearance().tintColor = .systemBlue
    }
}