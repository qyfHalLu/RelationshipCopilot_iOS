//
//  AvatarViews.swift
//  RelationshipCopilot
//
//  头像的两个可复用视图：
//   · `AvatarCircle`     —— 只读展示（列表、详情头部、各处选人器）
//   · `NFTAvatarRow`     —— 编辑（详情页 Form 里的一行）
//
//  ## 为什么之前"选了颜色却不生效"
//
//  `AddProfileView` 里写着 `profile.avatar = "color:\(avatarIndex)"`，
//  而列表卡片 `ProfileCard` 的颜色是自己用 UUID 哈希算的，**完全不读这个字段**。
//  用户选了颜色、保存、回到列表 —— 颜色跟选的不一样，而且没有任何提示。
//
//  所以这里把"读"这件事收到一个地方：所有展示都走 `AvatarCircle`，
//  它内部调 `AvatarStorage.parse`，颜色与照片只有一个真相来源。
//

import SwiftUI
import PhotosUI

// MARK: - 只读展示

/// 圆形头像：优先照片，其次颜色 + 首字，最后按 UUID 派生的默认色。
struct AvatarCircle: View {
    let name: String
    let raw: String?
    /// 用于在没有自定义颜色时派生一个稳定色。
    let fallbackID: UUID
    let diameter: CGFloat

    /// 首字字号跟着直径走，而不是写死。
    ///
    /// 原来 `ProfileCard` 是硬编码 52pt 圆 + `.title3` 字：XXXL 下
    /// 一个汉字宽过圆，首字两侧被裁掉。这里按直径比例给字号，
    /// 框和字永远是同一个比例关系。
    private var initialFont: Font {
        .system(size: diameter * 0.42, weight: .semibold, design: .rounded)
    }

    private var colorHex: String? {
        if case .color(let hex) = AvatarStorage.parse(raw) { return hex }
        return nil
    }

    private var photoName: String? {
        if case .photo(let name) = AvatarStorage.parse(raw) { return name }
        return nil
    }

    /// 优先用解析出的颜色；解析不出来才用派生默认色。
    ///
    /// 注意顺序：`deterministicHex` 放在最后，这样"用户选的颜色坏了"
    /// 会退回一个稳定色而不是黑圆。
    private var resolvedColor: Color {
        if let hex = colorHex, let color = AvatarStorage.color(fromHex: hex) {
            return color
        }
        if let color = AvatarStorage.color(fromHex: AvatarStorage.deterministicHex(for: fallbackID)) {
            return color
        }
        return ThemeManager.Colors.primary
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1))
    }

    var body: some View {
        Group {
            if let photoName, let image = AvatarStorage.loadPhoto(named: photoName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(resolvedColor.opacity(0.15))
                        .frame(width: diameter, height: diameter)
                    Text(initial)
                        .font(initialFont)
                        .foregroundStyle(resolvedColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 编辑行

/// 详情页 Form 里的头像照片行。
///
/// 只负责照片。颜色在 `NFTAvatarColorRow`，**必须**分成两行 ——
/// 与 `PhotosPicker` 同处一行时，点击会被它的行级手势抢走。
struct NFTAvatarRow: View {
    let name: String
    @Binding var colorHex: String
    let photoName: String?
    @Binding var photoItem: PhotosPickerItem?
    let onClearPhoto: () -> Void

    private var diameter: CGFloat { 64 }

    /// 当前应展示的头像。
    ///
    /// 这里刻意直接调 `AvatarStorage.encode` 拼出 raw 串，而不是把
    /// `photoName` / `colorHex` 分开传给 `AvatarCircle` ——
    /// 目的是让预览走**和列表完全同一条解析路径**。
    /// 如果预览自己写一套 if-else，就会出现"编辑页看着对、列表里不对"。
    private var previewRaw: String {
        if let photoName { return AvatarStorage.encode(photoName: photoName) }
        return AvatarStorage.encode(colorHex: colorHex)
    }

    var body: some View {
        // ## 为什么照片和颜色必须分到两行
        //
        // 原来两者同处一个 HStack 里的 VStack，结果**点「换个颜色」会弹出相册**。
        //
        // 排查过程值得记下来，因为每一层结论都推翻了上一层：
        //  ① 先以为是触控区太小 → 都补到 44pt（确实该补），问题仍在。
        //  ② 再以为是点击顺序问题 → 打 frame 发现两个按钮已相隔 48pt，仍在。
        //  ③ 截图证明：点「换个颜色」**色板和相册同时出现了**。
        //     `PhotosPicker` 在 Form 行里注册的是**行级**手势，
        //     它不认内部 `Button` 的 `contentShape` —— 整行任何点击都先交给它。
        //
        // 所以调触控区治不了这个病。唯一可靠的修法是让两者不在同一个 Form 行里：
        // 照片留在这一行，颜色入口单独成行（`NFTAvatarColorRow`）。
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            HStack(spacing: ThemeManager.Spacing.md) {
                AvatarCircle(
                    name: name,
                    raw: previewRaw,
                    fallbackID: UUID(),
                    diameter: diameter
                )

                PhotosPicker(selection: $photoItem, matching: .images) {
                    // 补足 44pt：实测未加时这个按钮只有 18pt 高。
                    Text(photoName == nil ? "换成照片" : "换一张照片")
                        .font(ThemeManager.Typography.subheadline)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }

                Spacer()
            }

            if photoName != nil {
                Button {
                    onClearPhoto()
                } label: {
                    Text("改回颜色")
                        .font(ThemeManager.Typography.caption)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.vertical, ThemeManager.Spacing.xs)
    }
}

// MARK: - 颜色行

/// 头像颜色：一行入口 + 展开后的 12 色板。
///
/// 单独成行是**功能正确性的要求**，不是排版偏好 ——
/// 与 `PhotosPicker` 同处一行时点击会被它抢走（详见 `NFTAvatarRow` 的注释）。
struct NFTAvatarColorRow: View {
    @Binding var colorHex: String
    /// 有照片时颜色不生效，所以整行禁用并说明原因，
    /// 而不是让用户选了颜色却发现头像没变。
    let disabled: Bool

    @State private var showPalette = false

    private var colorBinding: Binding<Color> {
        Binding(
            get: { AvatarStorage.color(fromHex: colorHex) ?? ThemeManager.Colors.primary },
            set: { newValue in
                if let hex = newValue.toHex() { colorHex = hex }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showPalette.toggle()
                }
            } label: {
                HStack {
                    Text("头像颜色")
                        .foregroundStyle(disabled ? ThemeManager.Colors.textSecondary : ThemeManager.Colors.textPrimary)
                    Spacer()
                    Circle()
                        .fill(AvatarStorage.color(fromHex: colorHex) ?? .gray)
                        .frame(width: 22, height: 22)
                    Text(showPalette ? "收起" : "更换")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.primary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)

            if disabled {
                Text("正在使用照片，改回颜色后才能选色。")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }

            if showPalette && !disabled {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: ThemeManager.Spacing.sm), count: 6),
                    spacing: ThemeManager.Spacing.sm
                ) {
                    ForEach(AvatarStorage.paletteHex, id: \.self) { hex in
                        Button {
                            colorHex = hex
                        } label: {
                            Circle()
                                .fill(AvatarStorage.color(fromHex: hex) ?? .gray)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().strokeBorder(
                                        ThemeManager.Colors.textPrimary,
                                        lineWidth: hex == colorHex ? 2 : 0
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("头像颜色")
                        .accessibilityAddTraits(hex == colorHex ? [.isSelected] : [])
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                ColorPicker("自定义颜色", selection: colorBinding, supportsOpacity: false)
                    .font(ThemeManager.Typography.caption)
            }
        }
        .padding(.vertical, ThemeManager.Spacing.xs)
    }
}
