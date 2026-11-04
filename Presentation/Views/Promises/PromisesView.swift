import SwiftUI
import SwiftData

// MARK: - 承诺管理
//
// 修复报告 C6（P1，本仓库最影响留存的一处）：
//  原 `PromiseDetailView` 是纯展示页 —— 没有任何"完成 / 打卡 / 撤销"入口，
//  `fulfillmentRate` / `streakDays` / `lastCheckIn` / `FulfillmentRecord` **全仓库零写入**。
//  结果：完成率恒 0%、首页"待办"永不清零、「连续 N 天」徽章恒为 0，
//  承诺追踪这个唯一能撑住月留存的机制在根上是死的。
//
//  现在：详情页可打卡（做到 / 部分做到 / 没做到）、可结束、可重开、可删除；
//  统计由 `FulfillmentStats` 纯函数重算；到期未打卡由 `DataMaintenance` 结算为 missed。
//
//  同时修复：
//   - `trackingStatus` 直接比较字符串（"closed"/"active"）易错，改用 `PromiseStatus`。
//   - `DateFormatter` 在渲染路径内新建 → 改用 `AppFormatters`。
//   - 空状态补 CTA（C8）。

struct PromisesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    @Query(sort: \Promise.committedAt, order: .reverse) private var promises: [Promise]
    @State private var showAddPromise = false
    @State private var filter: PromiseFilter = .all

    enum PromiseFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case active = "进行中"
        case closed = "已完成"

        var id: String { rawValue }
    }

    private var filteredPromises: [Promise] {
        switch filter {
        case .all:    return promises
        case .active: return promises.filter { $0.status == .active }
        case .closed: return promises.filter { $0.status == .closed }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.lg) {
                    PromiseStatsCard(promises: promises)

                    Picker("筛选", selection: $filter) {
                        ForEach(PromiseFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    if filteredPromises.isEmpty {
                        EmptyStateView(
                            icon: "checklist",
                            title: promises.isEmpty ? "还没有承诺" : "这里还没有内容",
                            message: promises.isEmpty
                                ? "写下一个具体、可验证的承诺，比如「这周陪 TA 散步两次」。"
                                : "换个筛选条件看看。",
                            actionTitle: promises.isEmpty ? "添加承诺" : nil,
                            action: promises.isEmpty ? { showAddPromise = true } : nil
                        )
                    } else {
                        LazyVStack(spacing: ThemeManager.Spacing.sm) {
                            ForEach(filteredPromises) { promise in
                                NavigationLink {
                                    PromiseDetailView(promise: promise)
                                } label: {
                                    PromiseCard(promise: promise)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, ThemeManager.Spacing.md)
                .padding(.vertical, ThemeManager.Spacing.lg)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("承诺")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddPromise = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加承诺")
                }
            }
            .sheet(isPresented: $showAddPromise) {
                AddPromiseView()
            }
        }
    }
}

// MARK: - 统计（真实数据）

struct PromiseStatsCard: View {
    let promises: [Promise]

    private var activeCount: Int {
        promises.filter { $0.status == .active }.count
    }

    private var closedCount: Int {
        promises.filter { $0.status == .closed }.count
    }

    /// 完成率基于**真实履约记录**，而不是"已关闭的承诺数 / 总数"。
    private var completionRate: Double? {
        let entries = promises.flatMap(\.entryProjection)
        guard !entries.isEmpty else { return nil }
        return FulfillmentStats.summarize(entries: entries).rate
    }

    private var streak: Int {
        let entries = promises.flatMap(\.entryProjection)
        return FulfillmentStats.summarize(entries: entries).streakDays
    }

    var body: some View {
        HStack(spacing: ThemeManager.Spacing.sm) {
            StatItem(icon: "hourglass", value: "\(activeCount)",
                     label: "进行中", tint: ThemeManager.Colors.primary)
            Divider().frame(height: 36)
            StatItem(icon: "checkmark.seal", value: "\(closedCount)",
                     label: "已完成", tint: ThemeManager.Colors.secondary)
            Divider().frame(height: 36)
            StatItem(icon: "chart.pie",
                     value: completionRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                     label: "履约率", tint: ThemeManager.Colors.accent)
            Divider().frame(height: 36)
            StatItem(icon: "flame", value: "\(streak)",
                     label: "连续天", tint: ThemeManager.Colors.accent4)
        }
        // 四列在 393pt 宽的机型上很挤：「100%」曾经折成两行把标签挤歪，
        // 因此收窄内边距并给数值加缩放兜底。
        .padding(ThemeManager.Spacing.md)
        .surfaceCard()
    }
}

// MARK: - 承诺卡片

struct PromiseCard: View {
    let promise: Promise

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            HStack(alignment: .top) {
                Text(promise.content)
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                statusBadge
            }

            HStack(spacing: ThemeManager.Spacing.md) {
                if let name = promise.counterpartName {
                    Label(name, systemImage: "person")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }

                Text(AppFormatters.dateShort.string(from: promise.committedAt))
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)

                if let deadline = promise.deadline {
                    Text("截止 \(AppFormatters.dateShort.string(from: deadline))")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(
                            deadline < Date()
                                ? ThemeManager.Colors.danger
                                : ThemeManager.Colors.textSecondary
                        )
                }

                Spacer()

                if promise.fulfillmentRate > 0 {
                    Text("\(Int((promise.fulfillmentRate * 100).rounded()))%")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.secondary)
                }
            }

            if promise.streakDays > 0 {
                ProgressView(value: promise.fulfillmentRate)
                    .tint(ThemeManager.Colors.secondary)
                    .accessibilityLabel("履约进度")
                    .accessibilityValue("\(Int((promise.fulfillmentRate * 100).rounded()))%")
            }
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
        .accessibilityElement(children: .combine)
    }

    private var statusBadge: some View {
        let tint: Color = {
            switch promise.status {
            case .active:  return ThemeManager.Colors.accent
            case .paused:  return ThemeManager.Colors.textSecondary
            case .closed:  return ThemeManager.Colors.secondary
            }
        }()
        return Text(promise.status.displayName)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - 添加承诺

struct AddPromiseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Profile.updatedAt, order: .reverse) private var profiles: [Profile]

    @State private var content = ""
    @State private var selectedProfile: Profile?
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(86400 * 7)
    @State private var errorMessage: String?

    @FocusState private var contentFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("比如：这周陪 TA 散步两次", text: $content, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($contentFocused)
                        .accessibilityLabel("承诺内容")
                    // 承诺是「一个具体到能验证的动作」，往往要一两句话才说得清
                    // （哪天、做什么、做到什么程度）。打字容易越写越糊，
                    // 最后变成「对 TA 好一点」这种没法打卡的东西。
                    VoiceInputButton(text: $content, subject: "承诺内容", compact: true)
                } header: {
                    Text("承诺内容")
                } footer: {
                    Text("写得越具体越容易做到。")
                }

                Section("关于谁") {
                    if profiles.isEmpty {
                        Text("请先到「关系」里添加一个人")
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                    } else {
                        Picker("选择人物", selection: $selectedProfile) {
                            Text("不指定").tag(nil as Profile?)
                            ForEach(profiles) { profile in
                                Text(profile.name).tag(profile as Profile?)
                            }
                        }
                    }
                }

                Section("截止日期") {
                    Toggle("设置截止日期", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker(
                            "截止日期",
                            selection: $deadline,
                            in: Date()...,
                            displayedComponents: .date
                        )
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.danger)
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
                    Button("保存") { save() }
                        .disabled(!Validation.isNonEmpty(content))
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                contentFocused = true
                if selectedProfile == nil { selectedProfile = profiles.first }
            }
        }
    }

    private func save() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Validation.isNonEmpty(trimmed) else {
            errorMessage = "请填写承诺内容"
            return
        }

        let promise = Promise(
            content: trimmed,
            promisor: "user",
            promisee: selectedProfile?.name ?? "partner"
        )
        promise.profile = selectedProfile
        if hasDeadline { promise.deadline = deadline }

        modelContext.insert(promise)

        do {
            try modelContext.save()
            Telemetry.shared.track(.promiseCreated)
            // 提醒需要显式申请权限（修复：原 NotificationService 在 init 里就弹权限框）
            Task {
                let state = await NotificationService.shared.requestAuthorizationIfNeeded()
                if state == .authorized {
                    NotificationService.shared.schedulePromiseReminder(promise)
                }
            }
            dismiss()
        } catch {
            modelContext.delete(promise)
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 承诺详情（含打卡）

struct PromiseDetailView: View {
    @Bindable var promise: Promise

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false

    private var todayStatus: FulfillmentStatus? {
        guard let raw = promise.existingRecord(on: Date())?.status else { return nil }
        return FulfillmentStatus(rawValue: raw)
    }

    private var recentDays: [(day: Date, status: FulfillmentStatus?)] {
        FulfillmentStats.recentDays(entries: promise.entryProjection, days: 14, referencesDate: Date())
    }

    var body: some View {
        Form {
            Section {
                Text(promise.content)
                    .font(ThemeManager.Typography.headline)
                    .fixedSize(horizontal: false, vertical: true)

                if let name = promise.counterpartName {
                    HStack {
                        Text("关于")
                        Spacer()
                        Text(name).foregroundStyle(ThemeManager.Colors.textSecondary)
                    }
                }

                HStack {
                    Text("状态")
                    Spacer()
                    Text(promise.status.displayName)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }

                if let deadline = promise.deadline {
                    HStack {
                        Text("截止")
                        Spacer()
                        Text(AppFormatters.dateLong.string(from: deadline))
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                    }
                }
            }

            // 打卡：这是原先完全缺失的核心交互
            Section {
                HStack(spacing: ThemeManager.Spacing.sm) {
                    checkInButton(.fulfilled, title: "做到", icon: "checkmark.circle.fill",
                                  tint: ThemeManager.Colors.secondary)
                    checkInButton(.partial, title: "部分", icon: "circle.lefthalf.filled",
                                  tint: ThemeManager.Colors.accent)
                    checkInButton(.missed, title: "没做到", icon: "xmark.circle",
                                  tint: ThemeManager.Colors.textSecondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("今天")
            } footer: {
                Text(todayStatus == nil
                     ? "每天记一次，连续天数会自动累计。"
                     : "今天已记录：\(todayStatus?.displayName ?? "")。可以修改。")
            }

            Section("近 14 天") {
                HStack(spacing: 4) {
                    ForEach(Array(recentDays.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(for: item.status))
                                .frame(height: 26)
                            Text(dayLabel(item.day))
                                .font(.system(size: 9))
                                .foregroundStyle(ThemeManager.Colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("近 14 天打卡记录")
                .accessibilityValue("已做到 \(recentDays.filter { $0.status == .fulfilled }.count) 天")
            }

            Section {
                HStack {
                    Text("履约率")
                    Spacer()
                    Text("\(Int((promise.fulfillmentRate * 100).rounded()))%")
                        .foregroundStyle(ThemeManager.Colors.secondary)
                }
                HStack {
                    Text("连续达标")
                    Spacer()
                    Text("\(promise.streakDays) 天")
                        .foregroundStyle(ThemeManager.Colors.accent)
                }
                if let last = promise.lastCheckIn {
                    HStack {
                        Text("最近打卡")
                        Spacer()
                        Text(AppFormatters.dateLong.string(from: last))
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                    }
                }
            } header: {
                Text("统计")
            }

            Section {
                if promise.status == .closed {
                    Button("重新打开") { setStatus(.active) }
                } else {
                    Button("标记为已完成") { setStatus(.closed) }
                }
                Button("删除承诺", role: .destructive) { showDeleteConfirm = true }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.danger)
                }
            }
        }
        .navigationTitle("承诺详情")
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除这条承诺？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deletePromise() }
        } message: {
            Text("会同时删除它的全部打卡记录。")
        }
    }

    private func checkInButton(
        _ status: FulfillmentStatus,
        title: String,
        icon: String,
        tint: Color
    ) -> some View {
        let selected = todayStatus == status
        return Button {
            checkIn(status)
        } label: {
            Label(title, systemImage: icon)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(selected ? .white : tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ThemeManager.Spacing.sm)
                .background(selected ? tint : tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func color(for status: FulfillmentStatus?) -> Color {
        switch status {
        case .fulfilled: return ThemeManager.Colors.secondary
        case .partial:   return ThemeManager.Colors.accent
        case .missed:    return ThemeManager.Colors.danger.opacity(0.35)
        case .pending, .none: return ThemeManager.Colors.scoreTrack
        }
    }

    private func dayLabel(_ date: Date) -> String {
        // 复用 AppFormatters 里的实例：这里在 7 个格子的 ForEach 里被调用，
        // 每次新建 DateFormatter 是列表卡顿的明确来源（修复报告 B6 同类问题）。
        AppFormatters.dayOfMonth.string(from: date)
    }

    // MARK: 动作

    private func checkIn(_ status: FulfillmentStatus) {
        promise.recordCheckIn(status: status, in: modelContext)
        do {
            try modelContext.save()
            Telemetry.shared.track(.promiseCheckedIn)
            if promise.fulfillmentRate >= 1.0, promise.status == .active {
                setStatus(.closed)
            }
            DataMaintenance.syncWidget(context: modelContext)
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func setStatus(_ status: PromiseStatus) {
        promise.status = status
        promise.updatedAt = Date()
        if status == .closed {
            NotificationService.shared.cancelPromiseReminder(promise)
            Telemetry.shared.track(.promiseClosed)
        } else {
            NotificationService.shared.schedulePromiseReminder(promise)
        }
        do {
            try modelContext.save()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func deletePromise() {
        NotificationService.shared.cancelPromiseReminder(promise)
        modelContext.delete(promise)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}
