green(initValue: Double(healthScore)), in: 0...100, step: 1)
                    }
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
