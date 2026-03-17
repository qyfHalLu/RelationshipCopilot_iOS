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
    @State private var relationship: RelationshipType = .partner
    @State private var birthday: Date = Date()
    @State private var anniversary: Date = Date()
    @State private var notes: String = ""
    @State private var avatarColor: Int = 0
    
    @Query private var profiles: [Profile]
    
    let columns = [
        GridItem(.adaptive(minimum: 60))
    ]
    
    let colors: [Color] = [
        Theme.Colors.primary,
        Theme.Colors.accent1,
        Theme.Colors.accent2,
        Theme.Colors.accent3,
        Theme.Colors.accent4,
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
                VStack(spacing: Theme.Spacing.lg) {
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
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.md)
            }
            .background(Theme.Colors.background)
            .navigationTitle("添加人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundStyle(Theme.Colors.secondaryText)
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
        VStack(spacing: Theme.Spacing.md) {
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
                .foregroundStyle(Theme.Colors.secondaryText)
            
            LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
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
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.xl))
    }
    
    // MARK: - Basic Info Section
    private var basicInfoSection: some View {
        VStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("姓名")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.Colors.secondaryText)
                
                TextField("请输入姓名", text: $name)
                    .font(.body)
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.background)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.md))
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.xl))
    }
    
    // MARK: - Relationship Section
    private var relationshipSection: some View {
        VStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("关系类型")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.Colors.secondaryText)
                
                Picker("关系类型", selection: $relationship) {
                    ForEach(RelationshipType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.md)
                .background(Theme.Colors.background)
                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.md))
            }
            
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("生日")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.Colors.secondaryText)
                
                DatePicker("生日", selection: $birthday, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.background)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.md))
            }
            
            if relationship == .partner || relationship == .spouse {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("纪念日")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    
                    DatePicker("纪念日", selection: $anniversary, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .padding(Theme.Spacing.md)
                        .background(Theme.Colors.background)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.md))
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.xl))
    }
    
    // MARK: - Notes Section
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("备注")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(Theme.Colors.secondaryText)
            
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 100)
                .padding(Theme.Spacing.sm)
                .background(Theme.Colors.background)
                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.md))
                .scrollContentBackground(.hidden)
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.xl))
    }
    
    // MARK: - Actions
    private func saveProfile() {
        let profile = Profile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            relationship: relationship,
            birthday: birthday,
            anniversary: relationship == .partner || relationship == .spouse ? anniversary : nil,
            notes: notes.isEmpty ? nil : notes,
            avatarColorIndex: avatarColor
        )
        
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