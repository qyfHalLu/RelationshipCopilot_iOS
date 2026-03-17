import SwiftUI
import SwiftData

// MARK: - 承诺管理主视图
struct PromisesView: View {
    @Query(sort: \Promise.committedAt, order: .reverse) private var promises: [Promise]
    @State private var showAddPromise = false
    @State private var selectedFilter: PromiseFilter = .all
    
    enum PromiseFilter: String, CaseIterable {
        case all = "全部"
        case pending = "待完成"
        case completed = "已完成"
    }
    
    var filteredPromises: [Promise] {
        switch selectedFilter {
        case .all:
            return promises
        case .pending:
            return promises.filter { $0.trackingStatus == "active" }
        case .completed:
            return promises.filter { $0.trackingStatus == "closed" }
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.lg) {
                    // 统计卡片
                    PromiseStatsCard(promises: promises)
                    
                    // 筛选器
                    Picker("筛选", selection: $selectedFilter) {
                        ForEach(PromiseFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    // 承诺列表
                    if filteredPromises.isEmpty {
                        EmptyPromiseView()
                    } else {
                        LazyVStack(spacing: ThemeManager.Spacing.md) {
                            ForEach(filteredPromises) { promise in
                                PromiseCard(promise: promise)
                            }
                        }
                    }
                }
                .padding(.horizontal, ThemeManager.Spacing.md)
                .padding(.vertical, ThemeManager.Spacing.lg)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("承诺管理")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showAddPromise = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(ThemeManager.Colors.primary)
                    }
                }
            }
            .sheet(isPresented: $showAddPromise) {
                AddPromiseView()
            }
        }
    }
}

// MARK: - 统计卡片
struct PromiseStatsCard: View {
    let promises: [Promise]
    
    var activeCount: Int {
        promises.filter { $0.trackingStatus == "active" }.count
    }
    
    var completedCount: Int {
        promises.filter { $0.trackingStatus == "closed" }.count
    }
    
    var completionRate: Double {
        guard !promises.isEmpty else { return 0 }
        return Double(completedCount) / Double(promises.count) * 100
    }
    
    var body: some View {
        HStack(spacing: ThemeManager.Spacing.lg) {
            VStack(spacing: ThemeManager.Spacing.xs) {
                Text("\(activeCount)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(ThemeManager.Colors.primary)
                Text("进行中")
                    .font(ThemeManager.Typography.caption)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
            }
            
            Divider().frame(height: 40)
            
            VStack(spacing: ThemeManager.Spacing.xs) {
                Text("\(completedCount)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(ThemeManager.Colors.secondary)
                Text("已完成")
                    .font(ThemeManager.Typography.caption)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
            }
            
            Divider().frame(height: 40)
            
            VStack(spacing: ThemeManager.Spacing.xs) {
                Text("\(Int(completionRate))%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(ThemeManager.Colors.accent)
                Text("完成率")
                    .font(ThemeManager.Typography.caption)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
            }
        }
        .padding(ThemeManager.Spacing.lg)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.lg))
        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

// MARK: - 承诺卡片
struct PromiseCard: View {
    let promise: Promise
    @State private var showDetail = false
    
    var body: some View {
        Button(action: { showDetail = true }) {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
                HStack {
                    Text(promise.content)
                        .font(ThemeManager.Typography.headline)
                        .foregroundColor(ThemeManager.Colors.textPrimary)
                        .lineLimit(2)
                    
                    Spacer()
                    
                    statusBadge
                }
                
                HStack {
                    Image(systemName: "calendar")
                        .font(.caption)
                        .foregroundColor(ThemeManager.Colors.textSecondary)
                    
                    Text(formattedDate)
                        .font(ThemeManager.Typography.caption)
                        .foregroundColor(ThemeManager.Colors.textSecondary)
                    
                    if let deadline = promise.deadline {
                        Text("• 截止: \(formatDate(deadline))")
                            .font(ThemeManager.Typography.caption)
                            .foregroundColor(ThemeManager.Colors.textSecondary)
                    }
                    
                    Spacer()
                    
                    if promise.fulfillmentRate > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "chart.bar.fill")
                                .font(.caption)
                            Text("\(Int(promise.fulfillmentRate * 100))%")
                                .font(ThemeManager.Typography.caption)
                        }
                        .foregroundColor(ThemeManager.Colors.secondary)
                    }
                }
            }
            .padding(ThemeManager.Spacing.md)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.lg))
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showDetail) {
            PromiseDetailView(promise: promise)
        }
    }
    
    private var statusBadge: some View {
        Text(promise.trackingStatus == "active" ? "进行中" : "已完成")
            .font(ThemeManager.Typography.caption)
            .foregroundColor(promise.trackingStatus == "active" ? ThemeManager.Colors.accent : ThemeManager.Colors.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (promise.trackingStatus == "active" ? ThemeManager.Colors.accent : ThemeManager.Colors.secondary).opacity(0.1)
            )
            .clipShape(Capsule())
    }
    
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: promise.committedAt)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - 空状态视图
struct EmptyPromiseView: View {
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.lg) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 64))
                .foregroundColor(ThemeManager.Colors.textSecondary.opacity(0.5))
            
            Text("还没有承诺")
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            Text("添加你们的第一个承诺吧")
                .font(ThemeManager.Typography.subheadline)
                .foregroundColor(ThemeManager.Colors.textSecondary)
        }
        .padding(.top, 60)
    }
}

// MARK: - 添加承诺视图
struct AddPromiseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @Query private var profiles: [Profile]
    
    @State private var content: String = ""
    @State private var selectedProfile: Profile?
    @State private var deadline: Date = Date().addingTimeInterval(86400 * 7)
    @State private var hasDeadline: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("承诺内容") {
                    TextField("写下你的承诺...", text: $content, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section("关联人物") {
                    if profiles.isEmpty {
                        Text("请先添加人物")
                            .foregroundColor(ThemeManager.Colors.textSecondary)
                    } else {
                        Picker("选择人物", selection: $selectedProfile) {
                            Text("请选择").tag(nil as Profile?)
                            ForEach(profiles) { profile in
                                Text(profile.name).tag(profile as Profile?)
                            }
                        }
                    }
                }
                
                Section("截止日期") {
                    Toggle("设置截止日期", isOn: $hasDeadline)
                    
                    if hasDeadline {
                        DatePicker("截止日期", selection: $deadline, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("添加承诺")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        savePromise()
                    }
                    .disabled(content.isEmpty)
                }
            }
        }
    }
    
    private func savePromise() {
        let promise = Promise(content: content, promisor: "user", promisee: selectedProfile?.name ?? "partner")
        promise.profile = selectedProfile
        
        if hasDeadline {
            promise.deadline = deadline
        }
        
        modelContext.insert(promise)
        dismiss()
    }
}

// MARK: - 承诺详情视图
struct PromiseDetailView: View {
    let promise: Promise
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {
                    // 承诺内容
                    Text(promise.content)
                        .font(ThemeManager.Typography.headline)
                        .foregroundColor(ThemeManager.Colors.textPrimary)
                    
                    // 状态
                    HStack {
                        Text("状态:")
                            .foregroundColor(ThemeManager.Colors.textSecondary)
                        Text(promise.trackingStatus == "active" ? "进行中" : "已完成")
                            .foregroundColor(promise.trackingStatus == "active" ? ThemeManager.Colors.accent : ThemeManager.Colors.secondary)
                    }
                    .font(ThemeManager.Typography.subheadline)
                    
                    // 履约率
                    if promise.fulfillmentRate > 0 {
                        VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
                            Text("履约率")
                                .font(ThemeManager.Typography.subheadline)
                                .foregroundColor(ThemeManager.Colors.textSecondary)
                            
                            ProgressView(value: promise.fulfillmentRate)
                                .tint(ThemeManager.Colors.secondary)
                            
                            Text("\(Int(promise.fulfillmentRate * 100))%")
                                .font(ThemeManager.Typography.caption)
                                .foregroundColor(ThemeManager.Colors.secondary)
                        }
                    }
                    
                    // 日期信息
                    VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
                        Text("作出承诺: \(formatDate(promise.committedAt))")
                            .font(ThemeManager.Typography.caption)
                            .foregroundColor(ThemeManager.Colors.textSecondary)
                        
                        if let deadline = promise.deadline {
                            Text("截止日期: \(formatDate(deadline))")
                                .font(ThemeManager.Typography.caption)
                                .foregroundColor(ThemeManager.Colors.textSecondary)
                        }
                    }
                    
                    Spacer()
                }
                .padding(ThemeManager.Spacing.lg)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("承诺详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        return formatter.string(from: date)
    }
}

#Preview {
    PromisesView()
        .modelContainer(for: [Promise.self, Profile.self], inMemory: true)
}