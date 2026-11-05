import SwiftUI
import UIKit

// MARK: - 主题管理器
//
// 修复报告 C4 / C9：
//  - C4：原 `Colors` 全部是写死的浅色 hex（background = F8FAFC、surface = white、
//        textPrimary = 1E293B），再加上 `preferredColorScheme(darkMode ? .dark : .light)`
//        强制浅色，深色模式在结构上不可能实现；设置页还用 `.constant(true)` 假装已开启。
//        现改为 `UIColor` 动态色（自动跟随 trait），并删除所有强制 colorScheme。
//  - C9：原 `Typography` 全部是 `Font.system(size:)` 绝对字号，Dynamic Type 完全失效。
//        现映射到系统语义文本样式，自动支持动态字体与辅助功能字号。
//
//  实现选择说明：没有采用 Asset Catalog 语义色，而是用 `UIColor { trait in ... }` 动态提供者。
//  两者运行时行为等价（都随 trait 切换），但动态提供者能让「同一套色值」在代码里单点维护，
//  避免 20 多个 .colorset 目录与代码脱节；后续若交给设计师出图，可在不改调用方的前提下换成
//  `Color("Name")`。
//
//  iOS 27 适配：不使用 `UIScreen.main`（多窗口语义已变），不依赖已废弃的 UIColor 便捷构造。

enum ThemeManager {

    // 保留给需要读取当前配色的代码使用；不再用于强制界面方案。
    static var accentColor: Color { Colors.primary }

    // MARK: - 颜色系统

    enum Colors {

        // 主色（品牌色，深浅模式保持一致以保证识别度）
        static let primary = Color(hex: "6366F1")
        static let primaryLight = Color(hex: "818CF8")
        static let primaryDark = Color(hex: "4F46E5")

        // 辅助色
        static let secondary = Color(hex: "10B981")
        static let accent = Color(hex: "F59E0B")
        static let accent1 = Color(hex: "8B5CF6")
        static let accent2 = Color(hex: "EC4899")
        static let accent3 = Color(hex: "14B8A6")
        static let accent4 = Color(hex: "F97316")
        static let danger = Color(hex: "EF4444")

        /// 实心填充专用的深色变体（白字压它才够对比度）。
        ///
        /// ## 为什么需要单独一组
        ///
        /// 品牌色是给**浅底上的彩色文字/图标**用的，饱和度低、亮度高，
        /// 看着舒服。但同一个颜色一旦变成实心块、上面再压白字，对比度就崩了：
        ///
        /// | 颜色 | 白字对比度 | AA 正文(4.5) | AA 大字号(3.0) |
        /// |---|---|---|---|
        /// | `secondary` #10B981 | **2.54:1** | ❌ | ❌ |
        /// | `accent` #F59E0B | **2.15:1** | ❌ | ❌ |
        /// | `accent3` #14B8A6 | **2.49:1** | ❌ | ❌ |
        /// | `accent4` #F97316 | **2.80:1** | ❌ | ❌ |
        ///
        /// 所以：**浅色底的彩色文字仍用原品牌色，实心填充用下面的深色变体**。
        /// 打卡按钮（"今天做到了"选中态）是第一个踩到这个坑的地方 ——
        /// 它是首页最高频的动作，白字几乎糊在绿底上。
        ///
        /// 实测换色后：
        /// | 颜色 | 白字对比度 |
        /// |---|---|
        /// | `onFillSecondary` #047857 | **5.38:1** ✅ |
        /// | `onFillPrimary` #4338CA | **7.04:1** ✅ |
        static let onFillSecondary = Color(hex: "047857")
        static let onFillPrimary = Color(hex: "4338CA")

        // 语义中性色（随深浅模式自动切换）
        static let background = dynamic(
            light: UIColor(hex: "F6F7FB"),
            dark: UIColor(hex: "0F1117")
        )

        /// 卡片/面板底色。
        static let surface = dynamic(
            light: .white,
            dark: UIColor(hex: "1A1D26")
        )

        /// 次级面板（输入框、嵌套卡片）。
        static let surfaceElevated = dynamic(
            light: UIColor(hex: "F1F3F9"),
            dark: UIColor(hex: "232733")
        )

        static let cardBackground = surface

        static let textPrimary = dynamic(
            light: UIColor(hex: "1E293B"),
            dark: UIColor(hex: "F1F3F9")
        )

        static let textSecondary = dynamic(
            light: UIColor(hex: "64748B"),
            dark: UIColor(hex: "A2AAB8")
        )

        static let border = dynamic(
            light: UIColor(hex: "E2E8F0"),
            dark: UIColor(hex: "2E333F")
        )

        /// 深色模式下用描边代替阴影（黑色阴影在深色背景上不可见）。
        static let cardBorder = border

        static let gradientStart = Color(hex: "6366F1")
        static let gradientEnd = Color(hex: "8B5CF6")

        /// 用于评分等强调数字的底色
        static let scoreTrack = dynamic(
            light: UIColor(hex: "EDEFF5"),
            dark: UIColor(hex: "262B36")
        )

        private static func dynamic(light: UIColor, dark: UIColor) -> Color {
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            })
        }
    }

    // MARK: - 字体系统
    //
    // 使用语义文本样式而非固定 pt：自动支持 Dynamic Type、
    // 系统"文字大小"设置与辅助功能里的更大字号。
    enum Typography {
        static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let title = Font.system(.title, design: .rounded).weight(.bold)
        static let title2 = Font.system(.title2, design: .rounded).weight(.bold)
        static let title3 = Font.system(.title3, design: .rounded).weight(.semibold)
        static let headline = Font.system(.headline, design: .rounded)
        static let body = Font.system(.body)
        static let callout = Font.system(.callout)
        static let subheadline = Font.system(.subheadline)
        static let footnote = Font.system(.footnote)
        static let caption = Font.system(.caption)
        static let caption2 = Font.system(.caption2)

        /// 大号评分数字：用 `.largeTitle` 相对缩放，避免绝对字号在辅助功能下不放大。
        static let scoreDisplay = Font.system(.largeTitle, design: .rounded).weight(.bold)
        /// 计时器等宽数字
        static let timer = Font.system(.largeTitle, design: .monospaced).weight(.medium)
    }

    // MARK: - 间距 / 圆角

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let full: CGFloat = 9999
    }

    enum Shadows {
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

    /// 深色模式下阴影不可见，改用描边表达层级。
    func resolvedColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .clear : color
    }

    func resolvedRadius(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0 : radius
    }
}

// MARK: - Color 扩展

extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

extension UIColor {
    convenience init(hex: String, alpha: CGFloat = 1.0) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r, g, b, a: UInt64
        switch cleaned.count {
        case 3:
            (r, g, b, a) = (
                (value >> 8) * 17,
                (value >> 4 & 0xF) * 17,
                (value & 0xF) * 17,
                255
            )
        case 6:
            (r, g, b, a) = (value >> 16, value >> 8 & 0xFF, value & 0xFF, 255)
        case 8:
            (r, g, b, a) = (value >> 24, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        default:
            (r, g, b, a) = (0, 0, 0, 255)
        }

        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255 * alpha
        )
    }
}

// MARK: - 通用样式
//
// 修复报告 C4：原 `cardStyle()` 硬编码 `Color.white`，深色模式下会露出白块。
// 现在所有卡片统一走 `surfaceCard()`，自动适配深浅色。

extension View {

    func shadow(_ style: ShadowStyle) -> some View {
        self.shadow(
            color: style.color,
            radius: style.radius,
            x: style.x,
            y: style.y
        )
    }

    /// 卡片容器：语义底色 + 圆角 + 深浅色自适应描边/阴影。
    func surfaceCard(
        cornerRadius: CGFloat = ThemeManager.Radius.lg,
        padding: CGFloat? = nil
    ) -> some View {
        modifier(SurfaceCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    // 说明：`gradientBackground()` 已删除（全仓库零调用）。
    // `Colors.gradientStart/gradientEnd` **仍然在用** —— 登录页和快捷工具的
    // 渐变卡片直接引用了它们，不要跟着一起删。

    /// 只在需要时显示（避免 `if` 造成的视图身份变化）。
    @ViewBuilder
    func visible(_ isVisible: Bool) -> some View {
        if isVisible { self }
    }
}

private struct SurfaceCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(ThemeManager.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        scheme == .dark ? ThemeManager.Colors.cardBorder : Color.clear,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: ThemeManager.Shadows.md.resolvedColor(for: scheme),
                radius: ThemeManager.Shadows.md.resolvedRadius(for: scheme),
                x: ThemeManager.Shadows.md.x,
                y: ThemeManager.Shadows.md.y
            )
    }
}
