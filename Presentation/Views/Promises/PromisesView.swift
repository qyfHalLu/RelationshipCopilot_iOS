import SwiftUI
import SwiftData

// MARK: - 承诺管理主视图
struct PromisesView: View {
    @Query(sort: \Promise.dueDate, order: .forward) private var promises: [Promise]
    @State private var showAddPromise = false
    @State private var selectedFilter: PromiseFilter = .all
    
    enum PromiseFilter: String, CaseIterable {
        case all = "全部"
        case pending = "待完成"
        case completed = "已完成"
        case overdue = "已逾期"
    }
    
    var filteredPromises: [Promise] {
        switch selectedFilter {
        case .all:
            return promises
        case .pending:
            return promises.filter { !$0.isCompleted && !$0.isOverdue }
        case .completed:
            return promises.filter { $0.isCompleted }
        case .overdue:
            return promises.filter { $0.isOverdue && !$0.isCompleted }
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.lg) {
                    // 承诺统计
                    PromiseStatsCard(promises: promises)
                    
                    // 筛选器
                    FilterSegmentedControl(
                        selectedFilter: $selectedFilter,
                        filters: PromiseFilter.allCases
                    )
                    
                    // 承诺列表
                    if filteredPromises.isEmpty {
                        EmptyPromisesView(filter: selectedFilter)
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

// MARK: - 承诺统计卡片
struct PromiseStatsCard: View {
    let promises: [Promise]
    @State private var isAnimating = false
    
    var completionRate: Double {
        guard !promises.isEmpty else { return 0 }
        let completed = promises.filter { $0.isCompleted }.count
        return Double(completed) / Double(promises.count) * 100
    }
    
    var overdueCount: Int {
        promises.filter { $0.isOverdue && !$0.isCompleted }.count
    }
    
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.lg) {
            HStack {
                Text("本月承诺概览")
                    .font(ThemeManager.Typography.title3)
                    .foregroundColor(ThemeManager.Colors.textPrimary)
                
                Spacer()
                
                if overdueCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("\(overdueCount)条逾期")
                            .font(ThemeManager.Typography.caption)
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(ThemeManager.Radius.full)
                }
            }
            
            HStack(spacing: ThemeManager.Spacing.lg) {
                StatItem(
                    icon: "checklist",
                    value: "\(promises.count)",
                    label: "总承诺",
                    color: ThemeManager.Colors.primary
                )
                
                Divider()
                
                StatItem(
                    icon: "checkmark.circle.fill",
                    value: "\(Int(completionRate))%",
                    label: "履约率",
                    color: ThemeManager.Colors.secondary
                )
                
                Divider()
                
                StatItem(
                    icon: "clock.fill",
                    value: "\(promises.filter { !$0.isCompleted }.count)",
                    label: "待完成",
                    color: ThemeManager.Colors.accent
                )
            }
        }
        .padding(ThemeManager.Spacing.lg)
        .background(Color.white)
        .cornerRadius(ThemeManager.Radius.lg)
        .shadow(ThemeManager.Shadows.md)
        .opacity(isAnimating ? 1 : 0)
        .offset(y: isAnimating ? 0 : 20)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - 筛选分段控制器
struct FilterSegmentedControl<T: CaseIterable & RawRepresentable & Hashable>: View where T.RawValue == String {
    @Binding var selectedFilter: T
    let filters: [T]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ThemeManager.Spacing.sm) {
                ForEach(filters, id: \.self) { filter in
                    Button(action: { selectedFilter = filter }) {
                        Text(filter.rawValue)
                            .font(ThemeManager.Typography.subheadline)
                            .fontWeight(selectedFilter == filter ? .semibold : .regular)
                            .foregroundColor(selectedFilter == filter ? .white : ThemeManager.Colors.textPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                selectedFilter == filter
                                ? ThemeManager.Colors.primary
                                : Color.white
                            )
                            .cornerRadius(ThemeManager.Radius.full)
                    }
                }
            }
        }
    }
}

// MARK: - 承诺卡片
struct PromiseCard: View {
    @Bindable var promise: Promise
    @State private var showDetail = false
    
    var body: some View {
        Button(action: { showDetail = true }) {
            HStack(spacing: ThemeManager.Spacing.md) {
                // 完成状态
                Button(action: { toggleCompletion() }) {
                    Image(systemName: promise.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(promise.isCompleted ? ThemeManager.Colors.secondary : ThemeManager.Colors.border)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(promise.title)
                        .font(ThemeManager.Typography.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(promise.isCompleted ? ThemeManager.Colors.textSecondary : ThemeManager.Colors.textPrimary)
                        .strikethrough(promise.isCompleted)
                    
                    HStack(spacing: 8) {
                        Label(promise.dueDate.formatted(.dateTime.month().day()), systemImage: "calendar")
                            .font(ThemeManager.Typography.caption)
                            .foregroundColor(promise.isOverdue && !promise.isCompleted ? .red : ThemeManager.Colors.textSecondary)
                        
                        if let profile = promise.relatedProfile {
                            Label(profile.name, systemImage: "person.fill")
                                .font(ThemeManager.Typography.caption)
                                .foregroundColor(ThemeManager.Colors.textSecondary)
                        }
                    }
                }
                
                Spacer()
                
                // 优先级指示
                Circle()
                    .fill(priorityColor)
                    .frame(width: 8, height: 8)
            }
            .padding(ThemeManager.Spacing.md)
            .background(Color.white)
            .cornerRadius(ThemeManager.Radius.md)
            .shadow(ThemeManager.Shadows.sm)
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showDetail) {
            PromiseDetailView(promise: promise)
        }
    }
    
    private var priorityColor: Color {
        switch promise.priority {
        case 1: return .red
        case 2: return .orange
        default: return .green
        }
    }
    
    private func toggleCompletion() {
        withAnimation(.spring(duration: 0.3)) {
            promise.isCompleted.toggle()
            promise.completedAt = promise.isCompleted ? Date() : nil
        }
    }
}

// MARK: - 空承诺视图
struct EmptyPromisesView: View {
    let filter: PromisesView.PromiseFilter
    
    var message: String {
        switch filter {
        case .all: return "还没有任何承诺\n添加第一条承诺开始维护关系"
        case .pending: return "没有待完成的承诺\n太棒了！"
        case .completed: return "还没有已完成的承诺\n继续加油！"
        case .overdue: return "没有逾期的承诺\n继续保持！"
        }
    }
    
    var icon: String {
        switch filter {
        case .all: return "checklist"
        case .pending: return "checkmark.circle"
        case .completed: return "star.circle"
        case .overdue: return "checkmark.shield"
        }
    }
    
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(ThemeManager.Colors.border)
            
            Text(message)
                .font(ThemeManager.Typography.callout)
                .foregroundColor(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
    }
}

// MARK: - 添加承诺视图
struct AddPromiseView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Query private var profiles: [Profile]
    
    @State private var title = ""
    @State private var notes = ""
    @State private var dueDate = Date().addingTimeInterval(86400)
    @State private var priority = 2
    @State private var selectedProfile: Profile?
    @State private var showError = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("承诺内容") {
                    TextField("例如：周末一起看电影", text: $title)
                    
                    TextField("备注（可选）", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section("设置") {
                    DatePicker("截止日期", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                    
                    Picker("优先级", selection: $priority) {
                        Text("低").tag(3)
                        Text("中").tag(2)
                        Text("高").tag(1)
                    }
                    
                    if !profiles.isEmpty {
                        Picker("关联人物", selection: $selectedProfile) {
                            Text("无").tag(nil as Profile?)
                            ForEach(profiles) { profile in
                                Text(profile.name).tag(profile as Profile?)
                            }
                        }
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
                    .disabled(title.isEmpty)
                }
            }
            .alert("请输入承诺内容", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            }
        }
    }
    
    private func savePromise() {
        guard !title.isEmpty else {
            showError = true
            return
        }
        
        let promise = Promise(
            title: title,
            notes: notes.isEmpty ? nil : notes,
            dueDate: dueDate,
            priority: priority,
            relatedProfile: selectedProfile
        )
        
        modelContext.insert(promise)
        
        // 安排通知
        NotificationService.shared.schedulePromiseReminder(promise)
        
        dismiss()
    }
}

// MARK: - 承诺详情视图
struct PromiseDetailView: View {
    @Bindable var promise: Promise
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("已完成", isOn: $promise.isCompleted)
                    
                    if promise.isCompleted, let completedAt = promise.completedAt {
                        LabeledContent("完成时间", value: completedAt.formatted())
                    }
                }
                
                Section("承诺内容") {
                    Text(promise.title)
                        .font(ThemeManager.Typography.body)
                    
                    if let notes = promise.notes {
                        Text(notes)
                            .font(ThemeManager.Typography.callout)
                            .foregroundColor(ThemeManager.Colors.textSecondary)
                    }
                }
                
                Section("详情") {
                    LabeledContent("截止日期", value: promise.dueDate.formatted())
                    
                    LabeledContent("优先级") {
                        HStack {
                            Circle()
                                .fill(priorityColor)
                                .frame(width: 8, height: 8)
                            Text(priorityText)
                        }
                    }
                    
                    if let profile = promise.relatedProfile {
                        LabeledContent("关联人物", value: profile.name)
                    }
                    
                    LabeledContent("创建时间", value: promise.createdAt.formatted())
                }
                
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除承诺", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("承诺详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("确认删除？", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deletePromise()
                }
            } message: {
                Text("此操作无法撤销")
            }
        }
    }
    
    private var priorityColor: Color {
        switch promise.priority {
        case 1: return .red
        case 2: return .orange
        default: return .green
        }
    }
    
    private var priorityText: String {
        switch promise.priority {
        case 1: return "高"
        case 2: return "中"
        default: return "低"
        }
    }
    
    private func deletePromise() {
        // 取消通知
        NotificationService.shared.cancelPromiseReminder(promise)
        
        modelContext.delete(promise)
        dismiss()
    }
}
