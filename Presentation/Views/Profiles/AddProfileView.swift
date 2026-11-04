//
//  AddProfileView.swift
//  RelationshipCopilot
//
//  添加人物。
//
//  修复报告清单：
//  - 深色模式：原文件末尾硬编码 `.preferredColorScheme(.light)`，即使在深色模式下这个 sheet
//    也强制浅色。已移除。
//  - A3：关系类型改用 `RelationshipType` 枚举，中文名统一来源，避免"配偶"显示成"其他"。
//  - A6：备注写入独立字段 `note`（原实现塞进 `preferences.communicationStyle`）。
//  - 输入校验统一走 `Validation`，保存失败给出明确提示（原实现 `try` 空的 insert，无错误处理）。
//
//  ## 本轮改版
//
//  1. **删除「重要日期」**（生日 / 纪念日）。
//     用户不会用这个 App 记生日 —— 他们有日历、有专门的应用，而且那些地方已经
//     沉淀了多年的提醒习惯。在一个"处理矛盾"的工具里塞生日字段，等于让人在
//     吵架前先填一份档案表。`Profile.birthday` / `.anniversary` / `.knownSince`
//     三个字段一并删除，避免留下"写了没人读"的死数据。
//
//  2. **颜色从 6 个预设放开**：扩充到 12 色，并加 `ColorPicker` 支持任意取色。
//     原来 6 色在"每个人物一个颜色"的场景里必然撞色，而用户毫无办法。
//
//  3. **支持照片头像**：照片压缩后落盘，数据库只存文件名（理由见 `AvatarStorage`）。
//
//  4. **「其他」可自定义名称**：选了其他之后必须能说清到底是什么关系。
//

import SwiftUI
import SwiftData
import PhotosUI

struct AddProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var relationship: RelationshipType = .partner
    @State private var customRelationshipName = ""
    @State private var note = ""

    /// 当前选中的颜色（hex，不含 #）。默认取色板第一项。
    @State private var colorHex = AvatarStorage.paletteHex[0]
    /// 已选并落盘的照片文件名。非 nil 时照片优先于颜色显示。
    @State private var photoName: String?
    @State private var photoItem: PhotosPickerItem?

    @State private var errorMessage: String?

    @FocusState private var nameFocused: Bool

    private var canSave: Bool {
        guard Validation.isNonEmpty(name) else { return false }
        // 选了「其他」就必须填名称：否则列表里会出现一串无法区分的「其他」。
        if relationship == .other {
            return Validation.isNonEmpty(customRelationshipName)
        }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.md) {
                    avatarSection
                    nameSection
                    relationshipSection
                    if relationship == .other {
                        customRelationshipSection
                    }
                    noteSection

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(ThemeManager.Spacing.md)
            }
            .background(ThemeManager.Colors.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("添加人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { nameFocused = true }
            .onChange(of: photoItem) { _, newValue in
                Task { await loadPhoto(newValue) }
            }
        }
    }

    // MARK: 头像

    private var avatarSection: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            ZStack {
                if let photoName, let image = AvatarStorage.loadPhoto(named: photoName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(avatarColor.opacity(0.2))
                        .frame(width: 84, height: 84)
                    Text(String(name.isEmpty ? "?" : String(name.prefix(1))))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(avatarColor)
                }
            }
            .accessibilityHidden(true)

            // 两个入口并列：拍照/相册，以及"用颜色"。
            //
            // 放在同一行是因为它们互斥且同级 —— 用户要么用照片、要么用颜色，
            // 不存在先设一个再设另一个的先后关系。做成两个上下按钮会暗示
            // 有顺序，实际没有。
            HStack(spacing: ThemeManager.Spacing.sm) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("换照片", systemImage: "photo")
                        .font(ThemeManager.Typography.caption)
                }
                .buttonStyle(.bordered)

                if photoName != nil {
                    Button {
                        if let old = photoName { AvatarStorage.deletePhoto(named: old) }
                        photoName = nil
                    } label: {
                        Label("用颜色", systemImage: "paintpalette")
                            .font(ThemeManager.Typography.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }

            // 选了照片时色板收起。
            //
            // 不收起的话，用户会以为"颜色和照片会一起生效"，而圆只有一个位置。
            if photoName == nil {
                colorPalette
            }
        }
        .frame(maxWidth: .infinity)
        .padding(ThemeManager.Spacing.lg)
        .surfaceCard()
    }

    private var avatarColor: Color {
        AvatarStorage.color(fromHex: colorHex) ?? ThemeManager.Colors.primary
    }

    private var colorPalette: some View {
        VStack(spacing: ThemeManager.Spacing.sm) {
            // 12 色用 LazyVGrid 而不是 HStack：12 个 30pt 圆 + 间距在 375pt
            // 宽的屏幕上排不下，HStack 会把它们压缩成椭圆。
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
                                Circle().strokeBorder(.white, lineWidth: colorHex == hex ? 2.5 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("头像颜色")
                    .accessibilityAddTraits(colorHex == hex ? [.isSelected] : [])
                }
            }

            // 任意取色。
            //
            // `ColorPicker` 是系统控件，自带取色器、取色到屏幕任意位置、
            // 以及最近使用色。自己画一个色轮做不到这些，也没必要。
            //
            // 分隔线是必要的：系统控件把标签放左、色环放右，中间大片空白
            // 会让「自定义颜色」看起来和上面 12 色板是两件无关的事。
            // 加一条细线把它归到同一组的最后一项。
            Divider()
                .padding(.vertical, 2)

            ColorPicker(
                "自定义颜色",
                selection: Binding(
                    get: { avatarColor },
                    set: { newValue in
                        if let hex = newValue.toHex() { colorHex = hex }
                    }
                ),
                supportsOpacity: false
            )
            .font(ThemeManager.Typography.caption)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "这张照片读不出来，换一张试试"
            return
        }
        if let name = AvatarStorage.savePhoto(image) {
            // 换照片时删掉上一张，否则沙盒里会堆积无人引用的图片。
            if let old = photoName { AvatarStorage.deletePhoto(named: old) }
            photoName = name
            errorMessage = nil
        } else {
            errorMessage = "照片保存失败，换一张试试"
        }
    }

    // MARK: 文本

    private var nameSection: some View {
        fieldCard(title: "称呼") {
            TextField("比如：小林", text: $name)
                .font(ThemeManager.Typography.body)
                .focused($nameFocused)
                .submitLabel(.done)
                .padding(ThemeManager.Spacing.md)
                .background(ThemeManager.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                .accessibilityLabel("称呼")
        }
    }

    private var relationshipSection: some View {
        fieldCard(title: "关系") {
            // 7 个选项不再用 `.segmented`。
            //
            // 分段控件在 375pt 宽下放 7 个中文标签会被压缩到每个只剩两个字，
            // 而且选中态几乎看不见。`Menu` 样式是系统推荐的"多选项单选"。
            Picker("关系", selection: $relationship) {
                ForEach(RelationshipType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(ThemeManager.Colors.primary)
        }
    }

    private var customRelationshipSection: some View {
        fieldCard(title: "具体是什么关系") {
            TextField("比如：舅舅、健身教练、房东", text: $customRelationshipName)
                .font(ThemeManager.Typography.body)
                .padding(ThemeManager.Spacing.md)
                .background(ThemeManager.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                .accessibilityLabel("自定义关系名称")
        }
    }

    private var noteSection: some View {
        fieldCard(title: "备注（可选）") {
            TextEditor(text: $note)
                .font(ThemeManager.Typography.body)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(ThemeManager.Spacing.sm)
                .background(ThemeManager.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                .accessibilityLabel("备注")
            // 备注常写"TA 忌讳什么、最近在忙什么、上次为什么吵"这类回忆性内容，
            // 想的时候比打的时候快。语音入口放在这里而不是省掉。
            VoiceInputButton(text: $note, subject: "备注", compact: true)
        }
    }

    private func fieldCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text(title)
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ThemeManager.Spacing.lg)
        .surfaceCard()
    }

    // MARK: 保存

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Validation.isNonEmpty(trimmed) else {
            errorMessage = "请填写称呼"
            return
        }

        let profile = Profile(name: trimmed, relationshipType: relationship.rawValue)

        if relationship == .other {
            let custom = customRelationshipName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Validation.isNonEmpty(custom) else {
                errorMessage = "请填写具体是什么关系"
                return
            }
            profile.customRelationshipName = custom
        }

        profile.notes = Validation.optionalText(note)
        // 照片优先：两者都设过时，界面显示照片（`AvatarStorage.parse` 也是这个顺序）。
        if let photoName {
            profile.avatar = AvatarStorage.encode(photoName: photoName)
        } else {
            profile.avatar = AvatarStorage.encode(colorHex: colorHex)
        }

        modelContext.insert(profile)

        do {
            try modelContext.save()
            Telemetry.shared.track(.profileCreated)
            DataMaintenance.syncWidget(context: modelContext)
            dismiss()
        } catch {
            modelContext.delete(profile)
            errorMessage = "保存失败：\(error.localizedDescription)"
            AppLog.persistence.error("Insert profile failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Color → hex

extension Color {
    /// 转成 `RRGGBB`（不含 #）。失败返回 nil。
    ///
    /// 用 `UIColor.getRed` 而不是自己解析：`Color` 可能是任何色彩空间
    /// （显示 P3、灰度、甚至 pattern），只有交给 UIKit 转换才是可靠的。
    /// 返回 nil 时调用方保留原颜色，而不是退回黑色。
    func toHex() -> String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(
            format: "%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }
}
