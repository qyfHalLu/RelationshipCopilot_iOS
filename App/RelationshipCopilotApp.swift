import SwiftUI
import SwiftData
import UIKit

// MARK: - 应用入口
//
// 修复报告 A（架构）：
//  - 原实现在 `WindowGroup` 的 body 表达式里 `ContentView().environment(AuthenticationService())`，
//    SwiftUI `body` 每次重新求值都会**新建一个 AuthenticationService**（例如切换深色模式触发
//    @AppStorage 变化时），登录态被重置。现改为用 `@State` 在 App 层持有单例。
//  - 原 `preferredColorScheme(darkMode ? .dark : .light)` 且 `@AppStorage("darkMode")` 默认 false，
//    等于**强制所有用户使用浅色**，系统深色偏好被忽略（修复报告 C4）。现改为三态外观设置，
//    "跟随系统"时传 nil。
//
//  iOS 27 适配：
//  - 不使用 `UIScreen.main`（多窗口语义已变）。
//  - `AppDelegate` 仅保留外观配置，不再承担业务；场景生命周期交给 SwiftUI。

@main
struct RelationshipCopilotApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 登录服务在 App 生命周期内唯一。
    @State private var authService = AuthenticationService()
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    init() {
        #if DEBUG
        // 自动化验证用的密钥注入，必须在这里做而不是 ContentView 的 `.task`。
        //
        // 原因：`AIService.shared` 是 lazy 单例，它的 init 里会读一次 Keychain
        // 来决定走代理还是直连。任何 View 的 body 求值都可能先于 `.task` 触发它，
        // 一旦先被初始化，之后再写 Keychain 就不生效了（要重启 App 才行）。
        // App.init 早于所有 body，是唯一确定安全的时机。
        //
        // 只写 Keychain，不落源码、不落 Info.plist、不落 IPA。
        if let key = UITestSupport.injectedDirectKey {
            try? SecureStorageService.shared.save(
                key: EndpointConfiguration.directKeychainAccount,
                value: key
            )
        }
        #endif
    }

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authService)
                .preferredColorScheme(appearance.colorScheme)
                .tint(ThemeManager.Colors.primary)
        }
        .modelContainer(Self.sharedContainer)
    }

    /// 持久化容器。新增的可选字段（`Profile.note` / `Profile.anniversary` /
    /// `AnalysisResult.emotionalTrend` 等）由 SwiftData 轻量迁移自动处理，存量数据不丢失。
    ///
    /// Schema 与「删除全部数据」共用 `DataEraser.modelTypes` 这一份清单。
    /// 在此之前两处各写一遍，结果删除清单漏了 `DisputeCase`（隐私缺陷）。
    static let sharedContainer: ModelContainer = {
        let schema = Schema(DataEraser.modelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            AppLog.persistence.fault("ModelContainer failed: \(error.localizedDescription, privacy: .public)")
            // 兜底：内存容器让 App 仍可启动并提示，而不是直接闪退。
            // 注意：此分支意味着本地数据不可用，属于异常路径，需在崩溃上报中关注。
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: [fallback])
        }
    }()
}

// MARK: - 外观模式

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearanceMode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureAppearance()
        // 性能与稳定性观测（报告 E5 / R5）。模拟器不产生数据，真机 + TestFlight 才有回传。
        MetricsReporter.shared.start()
        return true
    }

    private func configureAppearance() {
        // 用语义色而非固定 systemBlue，保证深浅模式下都有足够对比度。
        let tint = UIColor(ThemeManager.Colors.primary)
        UINavigationBar.appearance().tintColor = tint
        UITabBar.appearance().tintColor = tint
    }
}
