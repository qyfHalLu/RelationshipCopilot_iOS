//
//  AddProfileView.swift
//  RelationshipCopilot
//
//  添加人物视图
//

import SwiftUI
import SwiftData

struct AddProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var name: String = ""
    @State private var relationshipType: String = "partner"
    @State private var birthday: Date = Date()
    @State private var anniversary: Date = Date()
    @State private var notes: String = ""
    @State private var avatarColor: Int = 0
    
    @Query private var profiles: [Profile]
    
    let columns = [
        GridItem(.adaptive(minimum: 60))
    ]
    
    let colors: [Color] = [
        ThemeManager.Colors.primary,
        ThemeManager.Colors.accent1,
        ThemeManager.Colors.accent2,
        ThemeManager.Colors.accent3,
        ThemeManager.Colors.accent4,
        Color(hex: "EF4444"),
        Color(hex: "F59E0B"),
        Color(hex: "10B981"),
        Color(hex: "3B82F6"),
        Color(hex: "8B5CF6"),
        Color(hex: "EC4899"),
        Color(hex: "14B8A6")
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.lg) {
                    // Avatar selection
                    avatarSection
                    
                    // Basic info
                    basicInfoSection
                    
                    // Relationship details
                    relationshipSection
                    
                    // Notes
                    notesSection
                    
                    Spacer(minLength: 100)
                }
                .padding(.horizontal, ThemeManager.Spacing.md)
                .padding(.top, ThemeManager.Spacing.md)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("添加人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveProfile()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.light)
    }
    
    // MARK: - Avatar Section
    private var avatarSection: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            ZStack {
                Circle()
                    .fill(colors[avatarColor].gradient)
                    .frame(width: 100, height: 100)
                
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: colors[avatarColor].opacity(0.4), radius: 10, y: 5)
            
            Text("选择头像颜色")
                .font(.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
            
            LazyVGrid(columns: columns, spacing: ThemeManager.Spacing.md) {
                ForEach(0..<colors.count, id: \.self) { index in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            avatarColor = index
                        }
                    } label: {
                        Circle()
                            .fill(colors[index])
                            .frame(width: 44, height: 44)
                            .overlay {
                                if avatarColor == index {
                                    Circle()
                                        .strokeBorder(.white, lineWidth: 3)
                                }
                            }
                            .shadow(color: colors[index].opacity(0.5), radius: avatarColor == index ? 8 : 0, y: 3)
                    }
                }
            }
        }
        .padding(ThemeManager.Spacing.lg)
        .background(ThemeManager.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.xl))
    }
    
    // MARK: - Basic Info Section
    private var basicInfoSection: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
                Text("姓名")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                
                TextField("请输入姓名", text: $name)
                    .font(.body)
                    .padding(ThemeManager.Spacing.md)
                    .background(ThemeManager.Colors.background)
                    .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
            }
        }
        .padding(ThemeManager.Spacing.lg)
        .background(ThemeManager.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.xl))
    }
    
    // MARK: - Relationship Section
    private var relationshipSection: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
                Text("关系类型")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                
                Picker("关系类型", selection: $relationshipType) {
                    Text("伴侣").tag("partner")
                    Text("配偶").tag("spouse")
                    Text("家人").tag("family")
                    Text("朋友").tag("friend")
                    Text("同事").tag("colleague")
                    Text("其他").tag("other")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ThemeManager.Spacing.md)
                .background(ThemeManager.Colors.background)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
            }
            
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
                Text("生日")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                
                DatePicker("生日", selection: $birthday, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .padding(ThemeManager.Spacing.md)
                    .background(ThemeManager.Colors.background)
                    .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
            }
            
            if relationshipType == "partner" || relationshipType == "spouse" {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
                    Text("纪念日")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                    
                    DatePicker("纪念日", selection: $anniversary, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .padding(ThemeManager.Spacing.md)
                        .background(ThemeManager.Colors.background)
                        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
                }
            }
        }
        .padding(ThemeManager.Spacing.lg)
        .background(ThemeManager.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.xl))
    }
    
    // MARK: - Notes Section
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
            Text("备注")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
            
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 100)
                .padding(ThemeManager.Spacing.sm)
                .background(ThemeManager.Colors.background)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
                .scrollContentBackground(.hidden)
        }
        .padding(ThemeManager.Spacing.lg)
        .background(ThemeManager.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.xl))
    }
    
    // MARK: - Actions
    private func saveProfile() {
        let profile = Profile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            relationshipType: relationshipType
        )
        profile.birthday = birthday
        if relationshipType == "partner" || relationshipType == "spouse" {
            // Store anniversary in notes or create separate field
        }
        profile.notes = notes.isEmpty ? nil : notes
        
        modelContext.insert(profile)
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            dismiss()
        }
    }
}

#Preview {
    AddProfileView()
        .modelContainer(for: [Profile.self, Promise.self, RecordingSession.self], inMemory: true)
}