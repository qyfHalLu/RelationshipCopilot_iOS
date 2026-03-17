import SwiftUI

// MARK: - 主题管理器
// 使用静态结构体，因为主题配置不需要动态状态
enum ThemeManager {
    static var colorScheme: ColorScheme = .light
    static var accentColor: Color = .blue
    
    // 颜色系统
    struct Colors {
        // 主色调
        static let primary = Color(hex: "6366F1")      // 靛紫色
        static let primaryLight = Color(hex: "818CF8")
        static let primaryDark = Color(hex: "4F46E5")
        
        // 辅助色
        static let secondary = Color(hex: "10B981")    // 翠绿色
        static let accent = Color(hex: "F59E0B")       // 琥珀色
        static let accent1 = Color(hex: "8B5CF6")      // 紫色
        static let accent2 = Color(hex: "EC4899")      // 粉色
        static let accent3 = Color(hex: "14B8A6")     // 青色
        static let accent4 = Color(hex: "F97316")      // 橙色
        static let danger = Color(hex: "EF4444")       // 红色
        
        // 中性色
        static let background = Color(hex: "F8FAFC")
        static let surface = Color.white
        static let cardBackground = Color.white
        static let textPrimary = Color(hex: "1E293B")
        static let textSecondary = Color(hex: "64748B")
        static let border = Color(hex: "E2E8F0")
        
        // 渐变
        static let gradientStart = Color(hex: "6366F1")
        static let gradientEnd = Color(hex: "8B5CF6")
    }
    
    // 字体系统
    struct Typography {
        static let largeTitle = Font.system(size: 34, weight: .bold, design: .rounded)
        static let title = Font.system(size: 28, weight: .bold, design: .rounded)
        static let title2 = Font.system(size: 22, weight: .bold, design: .rounded)
        static let title3 = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 16, weight: .regular)
        static let callout = Font.system(size: 15, weight: .regular)
        static let subheadline = Font.system(size: 14, weight: .regular)
        static let footnote = Font.system(size: 13, weight: .regular)
        static let caption = Font.system(size: 12, weight: .regular)
    }
    
    // 间距系统
    struct Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }
    
    // 圆角系统
    struct Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let full: CGFloat = 9999
    }
    
    // 阴影系统
    struct Shadows {
        static let sm = ShadowStyle(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
        static let md = ShadowStyle(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        static let lg = ShadowStyle(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)
    }
}

// MARK: - 阴影样式
struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

// MARK: - Color扩展
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - View扩展
extension View {
    func shadow(_ style: ShadowStyle) -> some View {
        self.shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
    
    func cardStyle() -> some View {
        self
            .background(Color.white)
            .cornerRadius(ThemeManager.Radius.lg)
            .shadow(ThemeManager.Shadows.md)
    }
    
    func gradientBackground() -> some View {
        self.background(
            LinearGradient(
                colors: [ThemeManager.Colors.gradientStart, ThemeManager.Colors.gradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}
