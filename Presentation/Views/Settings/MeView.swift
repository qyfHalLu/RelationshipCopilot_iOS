import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - 「我的」
//
// 修复报告 C3 / C5 / F3：
//  - 设置页此前不可达，现在作为独立 tab 的入口，同时首页齿轮也能进。
//  - 修复 F3 审核项「有账号体系但没有删除账号入口」（App Store 5.1.1(v)）：
//    「数据管理」页提供导出与**永久删除**。
//  - 用户信息不再硬编码，取真实登录态。

struct MeView: View {
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [Profile]
    @Query private var promises: [Promise]
    @Query private var sessions: [RecordingSession]

    @State private var showLogoutAlert = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    userCard
                }

                // 原先这里有独立的「内容」三行（人物档案 / 承诺 / 记录）。
                // 这些计数在各自的 tab 里都能看到，重复占用了一屏高度，
                // 导致底部「退出登录」被浮动 tab bar 压住。现在并入上方用户卡片，
                // 既减少冗余，也让整页内容不再溢出。
                Section("设置") {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("偏好设置", systemImage: "gearshape")
                    }
                    NavigationLink {
                        DataManagementView()
                    } label: {
                        Label("数据管理", systemImage: "externaldrive")
                    }
                    NavigationLink {
                        LegalDocumentView(document: .privacy)
                    } label: {
                        Label("隐私政策", systemImage: "shield")
                    }
                    NavigationLink {
                        LegalDocumentView(document: .terms)
                    } label: {
                        Label("用户协议", systemImage: "doc.text")
                    }
                    NavigationLink {
                        HelpView()
                    } label: {
                        Label("帮助与反馈", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showLogoutAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("退出登录")
                            Spacer()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // iOS 26+ 的浮动 tab bar 会盖住列表最后一行（实测「退出登录」被遮）。
            // contentMargins 只影响可滚动范围，内容不足一屏时无效，
            // 必须用 safeAreaInset 真正压缩列表的可视高度。
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 64) }
            .navigationTitle("我的")
            .alert("确认退出登录？", isPresented: $showLogoutAlert) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) { authService.logout() }
            } message: {
                Text("本机数据会保留，下次登录可继续使用。如需彻底清除请用「数据管理」。")
            }
        }
    }

    private var userCard: some View {
        HStack(spacing: ThemeManager.Spacing.md) {
            ZStack {
                Circle()
                    .fill(ThemeManager.Colors.primary.opacity(0.15))
                    .frame(width: 56, height: 56)
                Image(systemName: "person.fill")
                    .font(.title3)
                    .foregroundStyle(ThemeManager.Colors.primary)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(maskedPhone)
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)

                Text("\(profiles.count) 位人物 · \(promises.count) 条承诺 · \(sessions.count) 次记录")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)

                if authService.isDemoSession {
                    Text("演示账号 · 数据仅存本机")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.accent)
                } else {
                    Text("数据保存在本机")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var maskedPhone: String {
        guard let phone = authService.currentUser?.phone, !phone.isEmpty else {
            // 内测免登录没有手机号。显示「未登录」会让用户以为账号出问题了，
            // 所以这里说清楚当前是什么状态。
            return authService.isDemoSession ? "内测版本" : "未登录"
        }
        return SafeLog.maskedPhone(phone)
    }
}

// MARK: - 数据管理
//
// 修复报告 F3（审核 5.1.1(v) 必需）+ E5（用户不敢深度使用隐私类 App 的根因是"删不掉"）。

struct DataManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var showDeleteConfirm = false
    @State private var showFinalConfirm = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享导出文件", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        export()
                    } label: {
                        Label("导出全部数据（JSON）", systemImage: "square.and.arrow.up")
                    }
                }

                Button {
                    exportTelemetry()
                } label: {
                    Label("导出使用统计（不含对话内容）", systemImage: "chart.bar.doc.horizontal")
                }
            } header: {
                Text("导出")
            } footer: {
                Text("导出内容包含人物档案、承诺、记录、转写文本，以及评理案卷（含你写下的原文）。文件是**未加密的明文 JSON**，只保存在本机临时目录，分享后请自行保管。")
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除全部数据", systemImage: "trash")
                }
            } header: {
                Text("危险操作")
            } footer: {
                // 这一句必须**逐个列出**会被删掉的东西。
                // 原文只说"人物档案、承诺、履约记录、对话记录"，漏了评理——
                // 而评理里存着"最让你难受的是…"这类最高敏的原文。
                // 用户按这句话理解删除范围，写漏就等于让他在错误的认知下做决定。
                Text("会永久删除本机所有人物档案、承诺、履约记录、对话记录、评理案卷（含你写下的原文）与登录状态，且无法恢复。")
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 64) }
        .navigationTitle("数据管理")
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除全部数据？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("继续", role: .destructive) { showFinalConfirm = true }
        } message: {
            Text("此操作不可撤销。建议先导出备份。")
        }
        .alert("最后确认", isPresented: $showFinalConfirm) {
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { deleteEverything() }
        } message: {
            Text("将立即清空所有本地数据并退出登录。")
        }
    }

    // MARK: 导出

    private func export() {
        do {
            let payload = try DataExporter.build(context: modelContext)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("relationshipcopilot-export.json")
            try payload.write(to: url, options: .atomic)
            exportURL = url
            statusMessage = "已生成导出文件（\(ByteCountFormatter.string(fromByteCount: Int64(payload.count), countStyle: .file))）"
            Telemetry.shared.track(.dataExported)
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func exportTelemetry() {
        do {
            let text = Telemetry.shared.export()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("relationshipcopilot-usage.txt")
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            exportURL = url
            statusMessage = "已生成使用统计文件"
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    // MARK: 删除

    private func deleteEverything() {
        do {
            // 删除逻辑收敛到 `DataEraser`，与 Schema 共用同一份模型清单。
            // 这里曾经手写清单并漏掉 `DisputeCase` —— 用户看到「已删除全部本地数据」，
            // 评理证词却完整留在库里。详见 Services/DataEraser.swift 的文件头。
            try DataEraser.eraseAll(in: modelContext)
        } catch {
            AppLog.persistence.error("Delete failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = "删除失败：\(error.localizedDescription)"
            return
        }

        RecordingService.cleanupOrphanRecordings()
        NotificationService.shared.clearAll()
        WidgetDataStore.clear()
        Telemetry.shared.reset()
        Telemetry.shared.track(.accountDeleted)
        authService.logout()
        statusMessage = "已删除全部本地数据"
        dismiss()
    }
}

// MARK: - 导出器

enum DataExporter {

    struct Payload: Encodable {
        struct ProfileDTO: Encodable {
            let id: String
            let name: String
            let relationshipType: String
            /// 用户在关系选「其他」时自填的名称。没填则为 nil。
            let customRelationshipName: String?
            /// 头像。`"color:<hex>"` 或 `"photo:<文件名>"`。
            ///
            /// 导出只记形状与引用，不内联图片数据 —— 备份文件应该能当文本看，
            /// 而且照片本身在沙盒里，要备份图片得单独做一次打包（见 TODO）。
            let avatar: String?
            let note: String?
            let intimacyScore: Int
            /// 已删除的关系健康度不再导出。它是 `70 + intimacy * 3`，
            /// 导出只会让这份数据看起来比它实际的含义更重要。
            let intimacyLabel: String
            let createdAt: Date
            let updatedAt: Date
        }

        struct PromiseDTO: Encodable {
            let id: String
            let content: String
            let status: String
            let deadline: Date?
            let fulfillmentRate: Double
            let streakDays: Int
            let lastCheckIn: Date?
            let profileName: String?
            let records: [RecordDTO]
        }

        struct RecordDTO: Encodable {
            let date: Date
            let status: String
        }

        struct SessionDTO: Encodable {
            let id: String
            let kind: String
            let status: String
            let startedAt: Date
            let endedAt: Date?
            let transcription: String?
            let analysisSummary: String?
            let analysisScore: Int?
            let profileName: String?
        }

        /// 评理案卷。
        ///
        /// **这一块曾经整个缺失。** 导出是用户唯一的备份手段（数据不上云），
        /// 而原实现只导出 profiles / promises / sessions，评理数据一份都不在里面。
        /// 更糟的是删除确认框写着"建议先导出备份" —— 照做也保不住评理。
        ///
        /// 字段刻意**完整保留原文**（happened / hurtMost / request / myPart），
        /// 不做摘要：这是用户的私有记录，备份的意义就是原样带走。
        struct DisputeDTO: Encodable {
            struct TestimonyDTO: Encodable {
                let happened: String
                let hurtMost: String
                let request: String
                let myPart: String
                let submittedAt: Date
            }

            struct VerdictDTO: Encodable {
                let reframe: String
                let needA: String
                let needB: String
                let stuckPoint: String
                let solvability: String
                let action: String?
                let coexistence: String?
                let generatedAt: Date
            }

            let id: String
            let title: String
            let mode: String
            let state: String
            let createdAt: Date
            let closedAt: Date?
            let profileName: String?

            /// 是否为降级结果（并列原话、未真正评理）。备份里必须跟着走，
            /// 否则恢复后会把它当成正常结论。
            let isDegradedVerdict: Bool

            /// 安全拦截命中的风险类型；未拦截时为空数组。
            let safetyConcerns: [String]

            let sideA: TestimonyDTO?
            let sideB: TestimonyDTO?
            let verdict: VerdictDTO?
        }

        let exportedAt: Date
        let appVersion: String
        let profiles: [ProfileDTO]
        let promises: [PromiseDTO]
        let sessions: [SessionDTO]
        /// 评理案卷。新增字段排在末尾，保持既有字段位置不变，
        /// 以免依赖旧格式的脚本解析出错。
        let disputes: [DisputeDTO]
    }

    static func build(context: ModelContext) throws -> Data {
        let profiles = try context.fetch(FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.createdAt)]))
        let promises = try context.fetch(FetchDescriptor<Promise>(sortBy: [SortDescriptor(\.committedAt)]))
        let sessions = try context.fetch(FetchDescriptor<RecordingSession>(sortBy: [SortDescriptor(\.createdAt)]))
        let disputes = try context.fetch(FetchDescriptor<DisputeCase>(sortBy: [SortDescriptor(\.createdAt)]))

        let payload = Payload(
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            profiles: profiles.map {
                Payload.ProfileDTO(
                    id: $0.id.uuidString,
                    name: $0.name,
                    relationshipType: $0.relationshipType,
                    customRelationshipName: $0.customRelationshipName,
                    avatar: $0.avatar,
                    note: $0.note,
                    intimacyScore: $0.intimacyScore,
                    intimacyLabel: $0.intimacyLabel,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            },
            promises: promises.map { promise in
                Payload.PromiseDTO(
                    id: promise.id.uuidString,
                    content: promise.content,
                    status: promise.trackingStatus,
                    deadline: promise.deadline,
                    fulfillmentRate: promise.fulfillmentRate,
                    streakDays: promise.streakDays,
                    lastCheckIn: promise.lastCheckIn,
                    profileName: promise.profile?.name,
                    records: (promise.fulfillmentRecords ?? []).map {
                        Payload.RecordDTO(date: $0.recordDate, status: $0.status)
                    }
                )
            },
            sessions: sessions.map {
                Payload.SessionDTO(
                    id: $0.id.uuidString,
                    kind: $0.sessionType,
                    status: $0.status,
                    startedAt: $0.startedAt,
                    endedAt: $0.endedAt,
                    transcription: $0.transcription,
                    analysisSummary: $0.analysisResult?.summary,
                    analysisScore: $0.analysisResult?.scoreValue,
                    profileName: $0.profile?.name
                )
            },
            disputes: disputes.map { dispute in
                Payload.DisputeDTO(
                    id: dispute.id.uuidString,
                    title: dispute.title,
                    mode: dispute.modeRaw,
                    state: dispute.stateRaw,
                    createdAt: dispute.createdAt,
                    closedAt: dispute.closedAt,
                    profileName: dispute.profile?.name,
                    isDegradedVerdict: dispute.isDegradedVerdict,
                    safetyConcerns: dispute.safetyConcerns.map(\.rawValue),
                    sideA: dispute.sideA.map { testimony in
                        Payload.DisputeDTO.TestimonyDTO(
                            happened: testimony.happened,
                            hurtMost: testimony.hurtMost,
                            request: testimony.request,
                            myPart: testimony.myPart,
                            submittedAt: testimony.submittedAt
                        )
                    },
                    sideB: dispute.sideB.map { testimony in
                        Payload.DisputeDTO.TestimonyDTO(
                            happened: testimony.happened,
                            hurtMost: testimony.hurtMost,
                            request: testimony.request,
                            myPart: testimony.myPart,
                            submittedAt: testimony.submittedAt
                        )
                    },
                    verdict: dispute.verdict.map { verdict in
                        Payload.DisputeDTO.VerdictDTO(
                            reframe: verdict.reframe,
                            needA: verdict.needA,
                            needB: verdict.needB,
                            stuckPoint: verdict.stuckPoint,
                            solvability: verdict.solvability.rawValue,
                            action: verdict.action,
                            coexistence: verdict.coexistence,
                            generatedAt: verdict.generatedAt
                        )
                    }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }
}
