//
//  AddProfileView.swift
//  RelationshipCopilot
//
//  添加人物。
//
//  修复报告清单：
//  - 纪念日被静默丢弃（P1）：原 `saveProfile()` 里有 `if relationshipType == "partner" || "spouse" { }`
//    这样的空分支，注释写着 "Store anniversary in notes or create separate field"，
//    用户填的纪念日**从未被保存**，而 `NotificationService.scheduleAnniversaryReminder`
//    又依赖这个字段 —— 于是「纪念日提醒」永远不可能触发。现在写入 `Profile.anniversary`。
//  - 深色模式：原文件末尾硬编码 `.preferredColorScheme(.light)`，即使在深色模式下这个 sheet
//    也强制浅色。已移除。
//  - A3：关系类型改用 `RelationshipType` 枚举，中文名统一来源，避免"配偶"显示成"其他"。
//  - A6：备注写入独立字段 `note`（原实现塞进 `preferences.communicationStyle`）。
//  - 头像颜色现在会持久化到 `Profile.avatar`，重开 App 不再变。
//  - 输入校验统一走 `Validation`，保存失败给出明确提示（原实现 `try` 空的 insert，无错误处理）。
//

import SwiftUI
import SwiftData

struct AddProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var relationship: RelationshipType = .partner
    @State private var birthday = Date()
    @State private var hasBirthday = false
    @State private var anniversary = Date()
    @State private var hasAnniversary = false
    @State private var note = ""
    @State private var avatarIndex = 0
    @State private var errorMessage: String?

    @FocusState private var nameFocused: Bool

    private let palette: [Color] = [
        ThemeManager.Colors.primary,
        ThemeManager.Colors.accent1,
        ThemeManager.Colors.accent2,
        ThemeManager.Colors.accent3,
        ThemeManager.Colors.accent4,
        ThemeManager.Colors.secondary
    ]

    private var canSave: Bool {
        Validation.isNonEmpty(name)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.md) {
                    avatarSection
                    nameSection
                    relationshipSection
                    if relationship.isIntimate {
                        anniversarySection
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
        }
    }

    // MARK: 各区块

    private var avatarSection: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            ZStack {
                Circle()
                    .fill(palette[avatarIndex].opacity(0.2))
                    .frame(width: 84, height: 84)
                Text(String(name.isEmpty ? "?" : String(name.prefix(1))))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette[avatarIndex])
            }
            .accessibilityHidden(true)

            HStack(spacing: ThemeManager.Spacing.sm) {
                ForEach(0..<palette.count, id: \.self) { index in
                    Button {
                        avatarIndex = index
                    } label: {
                        Circle()
                            .fill(palette[index])
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle()
                                    .strokeBorder(.white, lineWidth: avatarIndex == index ? 2.5 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("头像颜色 \(index + 1)")
                    .accessibilityAddTraits(avatarIndex == index ? [.isSelected] : [])
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(ThemeManager.Spacing.lg)
        .surfaceCard()
    }

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
            Picker("关系", selection: $relationship) {
                ForEach(RelationshipType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var anniversarySection: some View {
        fieldCard(title: "重要日期") {
            VStack(spacing: ThemeManager.Spacing.sm) {
                Toggle("记录生日", isOn: $hasBirthday)
                if hasBirthday {
                    DatePicker("生日", selection: $birthday, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.compact)
                }

                Toggle("记录纪念日", isOn: $hasAnniversary)
                if hasAnniversary {
                    DatePicker("纪念日", selection: $anniversary, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.compact)
                }
            }
            .font(ThemeManager.Typography.body)
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
            // 备注常写"他忌讳什么、最近在忙什么、上次为什么吵"这类回忆性内容，
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
        if hasBirthday { profile.birthday = birthday }
        if hasAnniversary { profile.anniversary = anniversary }
        profile.notes = Validation.optionalText(note)
        profile.avatar = "color:\(avatarIndex)"

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
