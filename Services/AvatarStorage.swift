//
//  AvatarStorage.swift
//  RelationshipCopilot
//
//  人物头像的两条路径：颜色 与 照片。
//
//  ## 为什么照片不直接存进 SwiftData
//
//  `@Model` 里的 `Data?` 字段会跟着行一起被读出来。一张照片原图动辄
//  2–5 MB，SwiftData 每次 fetch 都要把它整块搬进内存 —— 人物列表滚动时
//  就会明显卡顿，而界面上那个圆只有 52pt，根本不需要原图。
//
//  所以：照片缩放后落盘到沙盒，数据库里只留文件名（几十个字节）。
//  这和 `DisputeDraftStore` 用文件存草稿是同一套取舍。
//
//  ## 为什么用一个字符串字段承载两种形态
//
//  存量数据里 `Profile.avatar` 已经在写 `"color:<index>"` 了（虽然从未被读）。
//  SwiftData 加字段要迁移，而这里只需要两种互斥的形态，用前缀区分即可：
//
//      "color:6366F1"   自定义颜色（hex，不含 #）
//      "photo:AB12-….jpg" 照片文件名（在 AvatarStorage 目录下）
//      nil               没选过，退回按 UUID 派生的默认色
//
//  这样不需要新增字段，旧数据也能被平滑读出（见 `legacyIndex`）。
//

import SwiftUI
import UIKit

enum AvatarStorage {

    // MARK: - 编码

    /// 头像内容。
    enum Content: Equatable {
        /// 纯色底 + 首字（用户自选或默认派生）
        case color(String)
        /// 照片
        case photo(String)
    }

    /// 一张照片落盘后的最大边长。
    ///
    /// 界面最大用途是详情页的大圆（约 96pt）。按 @3x 算 288px 足够，
    /// 取 512 留一点余量给以后可能的放大展示，同时把体积压到百 KB 级。
    private static let maxPixel: CGFloat = 512

    private static let folderName = "Avatars"

    // MARK: - 解析 / 序列化

    /// 从 `Profile.avatar` 的原始字符串解析出内容。
    ///
    /// 无法识别时返回 nil，由调用方回退到默认色 —— 不猜、不崩。
    static func parse(_ raw: String?) -> Content? {
        guard let raw, !raw.isEmpty else { return nil }

        if raw.hasPrefix("photo:") {
            let name = String(raw.dropFirst("photo:".count))
            return name.isEmpty ? nil : .photo(name)
        }

        if raw.hasPrefix("color:") {
            let hex = String(raw.dropFirst("color:".count))
            // 旧版存的是 `"color:0"`…`"color:5"`（调色板索引），没有 hex 那么长。
            // 这两种都要认，否则升级用户的颜色会突然变掉。
            if hex.count >= 6 { return .color(hex) }
            if let index = Int(hex) { return .color(legacyPalette[index % legacyPalette.count]) }
        }

        return nil
    }

    static func encode(colorHex: String) -> String { "color:\(colorHex)" }
    static func encode(photoName: String) -> String { "photo:\(photoName)" }

    // MARK: - 默认色

    /// 没选过颜色时，按 UUID 派生一个稳定的颜色。
    ///
    /// 用 UUID 而不是 `hashValue`：后者每个进程种子不同，头像颜色会每次
    /// 启动都变（这是本项目踩过的坑，见 `ProfileCard` 注释）。
    static func deterministicHex(for id: UUID) -> String {
        var hash: UInt64 = 1469598103934665603   // FNV-1a 偏移
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return legacyPalette[Int(hash % UInt64(legacyPalette.count))]
    }

    /// 内置的分享色板。
    ///
    /// 从 6 色扩到 12 色：原来 6 个颜色在"关系"这种每个人都有一堆档案的
    /// 场景里几乎必然撞色，而用户又无法自定义。现在既扩了数量，也放开了
    /// 任意取色（`ColorPicker`），色板只是"懒得挑时"的快捷选项。
    ///
    /// 全部选的是中高明度、中饱和度的色，保证白色首字在其上可读。
    static let paletteHex: [String] = [
        "6366F1",   // 靛蓝
        "8B5CF6",   // 紫
        "EC4899",   // 粉
        "EF4444",   // 红
        "F97316",   // 橙
        "F59E0B",   // 琥珀
        "84CC16",   // 黄绿
        "10B981",   // 绿
        "14B8A6",   // 青
        "0EA5E9",   // 天蓝
        "64748B",   // 石板灰
        "78716C"    // 暖灰
    ]

    /// 旧版的 6 色索引色板，仅供兼容读取。
    private static let legacyPalette: [String] = [
        "6366F1", "8B5CF6", "EC4899", "14B8A6", "F97316", "10B981"
    ]

    // MARK: - 照片读写

    /// 头像目录（`Documents/Avatars`）。
    private static var directory: URL? {
        guard let base = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(forPhotoName name: String) -> URL? {
        directory?.appendingPathComponent(name)
    }

    /// 把用户选的照片压到 `maxPixel` 后落盘，返回文件名。
    ///
    /// 失败返回 nil 而不是抛错：调用方拿 nil 就退回原来的颜色，
    /// 而「头像没换成」这件事不值得弹一个错误框打断用户。
    static func savePhoto(_ image: UIImage) -> String? {
        guard let data = downscale(image) else { return nil }
        let name = "\(UUID().uuidString).jpg"
        guard let url = url(forPhotoName: name) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            AppLog.persistence.error("保存头像失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func deletePhoto(named name: String) {
        guard let url = url(forPhotoName: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 读取照片。同步读 —— 文件在本地、已压到 512px，放到后台队列反而
    /// 会让头像在滚动时白一下。
    static func loadPhoto(named name: String) -> UIImage? {
        guard let url = url(forPhotoName: name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - 缩放

    private static func downscale(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }

        let scale = min(1, maxPixel / longest)
        let target = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )

        // 用 `UIGraphicsImageRenderer`（iOS 10+）而不是 UIGraphicsBeginImageContext：
        // 后者在 @3x 屏上默认 1x 渲染，缩出来的图会糊。
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true   // 头像是圆形裁切，不需要透明通道
        let renderer = UIGraphicsImageRenderer(size: target, format: format)

        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

// MARK: - SwiftUI 桥接

extension AvatarStorage {
    /// 从 hex 字符串构造 `Color`。
    ///
    /// ## 为什么要先校验再构造
    ///
    /// `UIColor(hex:)` 对无法解析的输入**静默返回黑色**（`ThemeManager.swift:218`）。
    /// 用在这里的后果是：一个存坏的 `avatar` 值会让头像变成一个黑圆 ——
    /// 看起来像设计如此，实际是数据坏了，而且没有任何报错。
    ///
    /// 所以这里显式要求 6 位或 8 位十六进制，不合规就返回 nil，
    /// 由调用方回退到默认派生色。
    static func color(fromHex hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6 || cleaned.count == 8,
              UInt64(cleaned, radix: 16) != nil else { return nil }
        return Color(hex: hex)
    }
}
