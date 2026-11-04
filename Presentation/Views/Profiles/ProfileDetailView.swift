//
//  ProfileDetailView.swift
//  RelationshipCopilot
//
//  人物详情 / 编辑。
//
//  修复报告 A1（P0 数据损坏路径）：
//  原实现在 `onAppear` 里 `healthScore = profile.healthScore`，
//  保存时 `profile.healthScore = healthScore`，配合写反的 setter，
//  导致「打开详情页 → 一个字不改 → 点保存」把 85 变成 -56，再存一次变成 -194。
//
//  改版：健康度已删除（见 Core/IntimacyScale.swift 头部说明）。
//  本页不再展示任何"分数"，只让用户标注这个人和自己有多近 ——
//  这是个**输入**，不是**结论**。原来把用户自己的输入换算成两位数再显示回来，
//  既没增加任何信息，又让人误以为有东西在评估这段关系。
//
//  同时修复：关系类型改用枚举（配偶不再显示"其他"）、备注落到独立字段、
//  补删除入口、补无障碍标签。
//
//  本轮改版：删除「重要日期」（生日 / 纪念日）。理由见 `AddProfileView` 头部 ——
//  用户不会用这个 App 记生日，他们有日历和专门的应用。留着这两个字段
//  只会让"编辑一个人"变成填表。同时补上头像（照片/颜色）与「其他」关系的自定义名称。
//

import SwiftUI
import SwiftData
import PhotosUI

struct ProfileDetailView: View {
    @Bindable var profile: Profile

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var relationship: RelationshipType = .other
    @State private var customRelationshipName = ""
    @State private var intimacy = 5
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    @State private var didLoad = false

    // 头像编辑态
    @State private var colorHex = AvatarStorage.paletteHex[0]
    @State private var photoName: String?
    @State private var photoItem: PhotosPickerItem?
    /// 原照片名。保存时才真正删除旧文件 —— 用户可能选了新照片又取消编辑。
    @State private var originalPhotoName: String?

    private var isDirty: Bool {
        name != profile.name
            || relationship.rawValue != profile.relationshipType
            || customNameValue != (profile.customRelationshipName ?? "")
            || intimacy != profile.intimacyScore
            || note != (profile.notes ?? "")
            || photoName != originalPhotoName
            || (photoName == nil && AvatarStorage.encode(colorHex: colorHex) != profile.avatar)
    }

    private var customNameValue: String {
        relationship == .other
            ? customRelationshipName.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    var body: some View {
        Form {
            Section("基本信息") {
                NFTAvatarRow(
                    name: name,
                    colorHex: $colorHex,
                    photoName: photoName,
                    photoItem: $photoItem,
                    onClearPhoto: {
                        photoName = nil
                    }
                )

                // 必须单独一行：与 PhotosPicker 同行时，
                // 后者注册的行级手势会把点击全部吃掉（点"换颜色"弹相册）。
                NFTAvatarColorRow(colorHex: $colorHex, disabled: photoName != nil)

                TextField("称呼", text: $name)
                    .accessibilityLabel("称呼")

                Picker("关系类型", selection: $relationship) {
                    ForEach(RelationshipType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                if relationship == .other {
                    TextField("具体是什么关系（如：舅舅、房东）", text: $customRelationshipName)
                        .accessibilityLabel("自定义关系名称")
                }
            }

            Section {
                HStack {
                    Text("距离感")
                    Spacer()
                    Text(IntimacyScale.label(for: intimacy))
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundStyle(ThemeManager.Colors.primary)
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("距离感：\(IntimacyScale.label(for: intimacy))")

                Slider(
                    value: Binding(
                        get: { Double(intimacy) },
                        set: { intimacy = IntimacyScale.clamp(Int($0.rounded())) }
                    ),
                    in: 0...10,
                    step: 1
                ) {
                    Text("距离感")
                } minimumValueLabel: {
                    Text("疏远").font(.caption2)
                } maximumValueLabel: {
                    Text("很近").font(.caption2)
                }
                .tint(ThemeManager.Colors.primary)
                .accessibilityValue(IntimacyScale.label(for: intimacy))
            } header: {
                Text("你们有多近")
            } footer: {
                Text("这是你自己的感觉，随时可以改。它只影响话术的语气，不会被换算成任何分数。")
            }

            Section("备注") {
                TextEditor(text: $note)
                    .frame(minHeight: 80)
                    .accessibilityLabel("备注")
                VoiceInputButton(text: $note, subject: "备注", compact: true)
            }

            Section("关联内容") {
                HStack {
                    Text("承诺")
                    Spacer()
                    Text("\((profile.promises ?? []).count)")
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
                HStack {
                    Text("对话记录")
                    Spacer()
                    Text("\((profile.recordingSessions ?? []).count)")
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
                if let last = profile.lastInteractionAt {
                    HStack {
                        Text("最近记录")
                        Spacer()
                        Text(AppFormatters.relativeText(for: last))
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.danger)
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Text("删除这个人")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!isDirty || !Validation.isNonEmpty(name))
            }
        }
        .onAppear(perform: loadIfNeeded)
        .onChange(of: photoItem) { _, newValue in
            Task { await loadPhoto(newValue) }
        }
        .alert("删除「\(profile.name)」？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteProfile() }
        } message: {
            Text("会同时删除这个人的所有承诺与对话记录，无法恢复。")
        }
    }

    // MARK: 数据

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        name = profile.name
        relationship = profile.relationship
        customRelationshipName = profile.customRelationshipName ?? ""
        intimacy = IntimacyScale.clamp(profile.intimacyScore)
        note = profile.notes ?? ""

        // 头像：照片与颜色分开还原，两处都要，否则"改成颜色"时
        // 取色器会从错误的初始值起跳。
        switch AvatarStorage.parse(profile.avatar) {
        case .photo(let name):
            photoName = name
            originalPhotoName = name
            colorHex = AvatarStorage.paletteHex[0]
        case .color(let hex):
            photoName = nil
            originalPhotoName = nil
            colorHex = hex
        case nil:
            photoName = nil
            originalPhotoName = nil
            colorHex = AvatarStorage.deterministicHex(for: profile.id)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "这张照片读不出来，换一张试试"
            return
        }
        if let newName = AvatarStorage.savePhoto(image) {
            // 这里**不删**旧文件：可能上一张就是用户原来那张，
            // 而用户还没点保存。旧文件的删除放到 save() 成功之后。
            photoName = newName
            errorMessage = nil
        } else {
            errorMessage = "照片保存失败，换一张试试"
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Validation.isNonEmpty(trimmed) else {
            errorMessage = "称呼不能为空"
            return
        }
        if relationship == .other, !Validation.isNonEmpty(customRelationshipName) {
            errorMessage = "请填写具体是什么关系"
            return
        }

        profile.name = trimmed
        profile.relationship = relationship
        profile.customRelationshipName = relationship == .other
            ? Validation.optionalText(customRelationshipName)
            : nil
        // 走显式方法，内部会夹到 0...10，杜绝负数污染（修复 A1 / R6）
        profile.setIntimacy(intimacy)
        profile.notes = Validation.optionalText(note)

        if let photoName {
            profile.avatar = AvatarStorage.encode(photoName: photoName)
        } else {
            profile.avatar = AvatarStorage.encode(colorHex: colorHex)
        }

        profile.updatedAt = Date()

        do {
            try modelContext.save()

            // 保存成功后才回收旧照片文件。
            //
            // 顺序很重要：先删文件再存数据库的话，一旦 save 失败，
            // 数据库里还指着那个文件名，但文件已经没了 —— 头像变成空白。
            if let original = originalPhotoName, original != photoName {
                AvatarStorage.deletePhoto(named: original)
            }
            originalPhotoName = photoName

            Telemetry.shared.track(.profileEdited)
            DataMaintenance.syncWidget(context: modelContext)
            errorMessage = nil
            dismiss()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            AppLog.persistence.error("Save profile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteProfile() {
        modelContext.delete(profile)
        do {
            try modelContext.save()
            DataMaintenance.syncWidget(context: modelContext)
            dismiss()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}
