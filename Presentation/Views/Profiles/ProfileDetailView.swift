//
//  ProfileDetailView.swift
//  RelationshipCopilot
//
//  人物详情/编辑视图
//

import SwiftUI
import SwiftData

struct ProfileDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    let profile: Profile
    
    @State private var name: String = ""
    @State private var relationshipType: String = ""
    @State private var healthScore: Int = 75
    @State private var notes: String = ""
    @State private var showError: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("姓名", text: $name)
                    
                    Picker("关系类型", selection: $relationshipType) {
                        Text("伴侣").tag("partner")
                        Text("配偶").tag("spouse")
                        Text("家人").tag("family")
                        Text("朋友").tag("friend")
                        Text("同事").tag("colleague")
                        Text("其他").tag("other")
                    }
                }
                
                Section("健康度") {
                    HStack {
                        Text("关系健康度")
                        Spacer()
                        Text("\(healthScore)")
                            .foregroundStyle(healthColor)
                            .fontWeight(.bold)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(healthScore) },
                        set: { healthScore = Int($0) }
                    ), in: 0...100, step: 1)
                    .tint(healthColor)
                }
                
                Section("备注") {
                    TextField("添加备注...", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("编辑人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveProfile()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .alert("请输入姓名", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            }
            .onAppear {
                name = profile.name
                relationshipType = profile.relationshipType
                healthScore = profile.healthScore
                notes = profile.notes ?? ""
            }
        }
    }
    
    private var healthColor: Color {
        switch healthScore {
        case 0...40: return .red
        case 41...60: return .orange
        case 61...80: return .yellow
        default: return .green
        }
    }
    
    private func saveProfile() {
        guard !name.isEmpty else {
            showError = true
            return
        }
        
        profile.name = name
        profile.relationshipType = relationshipType
        profile.healthScore = healthScore
        profile.notes = notes.isEmpty ? nil : notes
        profile.updatedAt = Date()
        
        dismiss()
    }
}

// MARK: - 空状态视图
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(ThemeManager.Colors.border)
            
            Text(title)
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            Text(subtitle)
                .font(ThemeManager.Typography.callout)
                .foregroundColor(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
    }
}

#Preview {
    NavigationStack {
        ProfileDetailView(profile: Profile(name: "测试", relationshipType: "partner"))
    }
    .modelContainer(for: [Profile.self, Promise.self, RecordingSession.self], inMemory: true)
}