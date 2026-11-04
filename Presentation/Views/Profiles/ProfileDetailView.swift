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
//  展示纪念日、补删除入口、补无障碍标签。
//

import SwiftUI
import SwiftData

struct ProfileDetailView: View {
    @Bindable var profile: Profile

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var relationship: RelationshipType = .other
    @State private var intimacy = 5
    @State private var birthday: Date?
    @State private var anniversary: Date?
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    @State private var didLoad = false

    private var isDirty: Bool {
        name != profile.name
            || relationship.rawValue != profile.relationshipType
            || intimacy != profile.intimacyScore
            || birthday != profile.birthday
            || anniversary != profile.anniversary
            || note != (profile.notes ?? "")
    }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("称呼", text: $name)
                    .accessibilityLabel("称呼")

                Picker("关系类型", selection: $relationship) {
                    ForEach(RelationshipType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
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
                Text("这是你自己的感觉，随时可以改。它只影响纪念日和话术的语气，不会被换算成任何分数。")
            }

            Section("重要日期") {
                optionalDateRow(title: "生日", date: $birthday, range: ...Date())
                optionalDateRow(title: "纪念日", date: $anniversary, range: ...Date())
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
        .alert("删除「\(profile.name)」？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteProfile() }
        } message: {
            Text("会同时删除这个人的所有承诺与对话记录，无法恢复。")
        }
    }

    @ViewBuilder
    private func optionalDateRow(title: String, date: Binding<Date?>, range: PartialRangeThrough<Date>) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let value = date.wrappedValue {
                DatePicker(
                    title,
                    selection: Binding(
                        get: { value },
                        set: { date.wrappedValue = $0 }
                    ),
                    in: range,
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)

                Button {
                    date.wrappedValue = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除\(title)")
            } else {
                Button("添加") {
                    date.wrappedValue = Date()
                }
                .font(ThemeManager.Typography.subheadline)
            }
        }
    }

    // MARK: 数据

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        name = profile.name
        relationship = profile.relationship
        intimacy = IntimacyScale.clamp(profile.intimacyScore)
        birthday = profile.birthday
        anniversary = profile.anniversary
        note = profile.notes ?? ""
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Validation.isNonEmpty(trimmed) else {
            errorMessage = "称呼不能为空"
            return
        }

        profile.name = trimmed
        profile.relationship = relationship
        // 走显式方法，内部会夹到 0...10，杜绝负数污染（修复 A1 / R6）
        profile.setIntimacy(intimacy)
        profile.birthday = birthday
        profile.anniversary = anniversary
        profile.notes = Validation.optionalText(note)
        profile.updatedAt = Date()

        do {
            try modelContext.save()
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
