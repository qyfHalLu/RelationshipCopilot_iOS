import SwiftUI
import SwiftData
import AVFoundation

// MARK: - 记录对话
//
// 修复报告 A2 / B1–B5 / C6 / D2 / D5 —— 这是本仓库问题最集中的页面：
//
//  原实现（`RecordingView.swift:522-538`）：
//    `stopRecording()` → 固定 `sleep(2s)` → 把 `transcription` 赋成硬编码字符串
//    「这是模拟的对话转录内容」→ 直接弹出 `AnalysisResultView`（内含硬编码的 65/45 分）。
//    也就是说：**录了音，但音频从未被用于分析；AI 服务从未被调用**。
//
//  现在：
//    1. 录音用 `RecordingService`（AVAudioEngine 流式识别，支持后台与长音频）。
//    2. 停止后拿**真实转写文本**调用 `AIService.analyze`（协议注入，可测）。
//    3. 结果与转写一起落 SwiftData（`RecordingSession`），历史可回看 —— 此前
//       `RecordingSession(` 全仓库 0 次实例化，分析页永远为空。
//    4. 音频在分析完成后删除，只留文字（隐私）。
//    5. 无转写时明确失败，不编造结果；AI 未配置时明确提示。
//    6. 录音前引导选择关联人物，使分析有上下文。

struct RecordingView: View {
    @State private var viewModel = RecordingViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.lg) {
                    profileSelector

                    recordingStage

                    if viewModel.phase == .recording || viewModel.phase == .paused {
                        liveTranscript
                    }

                    if let error = viewModel.error, error.isBlocking {
                        errorCard(error)
                    }

                    controls

                    consentNote
                }
                .padding(.horizontal, ThemeManager.Spacing.md)
                .padding(.vertical, ThemeManager.Spacing.lg)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("记录对话")
            .navigationBarTitleDisplayMode(.large)
            .scrollDismissesKeyboard(.immediately)
            .onAppear { viewModel.onAppear(context: modelContext) }
            .alert("需要权限", isPresented: $viewModel.showPermissionAlert) {
                Button("去设置") { openSettings() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(viewModel.permissionMessage)
            }
            .sheet(item: $viewModel.completedSession) { session in
                NavigationStack {
                    SessionDetailView(session: session, showsDismiss: true)
                }
            }
        }
    }

    // MARK: 选择关联人物

    private var profileSelector: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text("这次记录关于")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)

            if viewModel.profiles.isEmpty {
                HStack(spacing: ThemeManager.Spacing.sm) {
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(ThemeManager.Colors.accent)
                    Text("还没有人物档案，请先到「关系」里添加一个人")
                        .font(ThemeManager.Typography.callout)
                        .foregroundStyle(ThemeManager.Colors.textPrimary)
                }
                .padding(ThemeManager.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfaceCard(cornerRadius: ThemeManager.Radius.md)
            } else {
                Menu {
                    ForEach(viewModel.profiles) { profile in
                        Button {
                            viewModel.selectedProfile = profile
                        } label: {
                            if viewModel.selectedProfile?.id == profile.id {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "person.fill")
                            .foregroundStyle(ThemeManager.Colors.primary)
                        Text(viewModel.selectedProfile?.name ?? "请选择")
                            .font(ThemeManager.Typography.body)
                            .foregroundStyle(ThemeManager.Colors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                    }
                    .padding(ThemeManager.Spacing.md)
                    .surfaceCard(cornerRadius: ThemeManager.Radius.md)
                }
                .disabled(viewModel.phase == .recording || viewModel.phase == .analyzing)
            }
        }
    }

    // MARK: 录音可视化

    private var recordingStage: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            ZStack {
                if viewModel.phase == .recording {
                    Circle()
                        .fill(ThemeManager.Colors.danger.opacity(0.08))
                        .frame(width: 180, height: 180)
                }

                Circle()
                    .fill(ThemeManager.Colors.surfaceElevated)
                    .frame(width: 150, height: 150)

                if viewModel.phase == .recording {
                    WaveformIndicator(isActive: true)
                } else if viewModel.phase == .analyzing {
                    VStack(spacing: ThemeManager.Spacing.sm) {
                        ProgressView()
                        Text("分析中")
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                    }
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(recordingAccessibilityLabel)

            Text(AppFormatters.duration(viewModel.elapsed))
                .font(ThemeManager.Typography.timer)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())

            Text(viewModel.statusText)
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingAccessibilityLabel: String {
        switch viewModel.phase {
        case .idle:      return "准备录音"
        case .recording: return "正在录音，已录 \(Int(viewModel.elapsed)) 秒"
        case .paused:    return "录音已暂停"
        case .analyzing: return "正在分析"
        case .finished:  return "录音结束"
        }
    }

    // MARK: 实时转写

    private var liveTranscript: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text("实时转写")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)

            ScrollView {
                Text(viewModel.liveTranscription.isEmpty ? "正在聆听…" : viewModel.liveTranscription)
                    .font(ThemeManager.Typography.callout)
                    .foregroundStyle(viewModel.liveTranscription.isEmpty
                                     ? ThemeManager.Colors.textSecondary
                                     : ThemeManager.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
        .padding(ThemeManager.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
    }

    // MARK: 控制

    private var controls: some View {
        HStack(spacing: ThemeManager.Spacing.xl) {
            if viewModel.phase == .recording || viewModel.phase == .paused {
                Button {
                    viewModel.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                        .frame(width: 56, height: 56)
                        .background(ThemeManager.Colors.surfaceElevated)
                        .clipShape(Circle())
                }
                .accessibilityLabel("取消录音")
            }

            Button {
                viewModel.primaryAction()
            } label: {
                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 76, height: 76)
                    Image(systemName: buttonIcon)
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(PressableStyle(scale: 0.94))
            .disabled(!viewModel.canTapPrimary)
            .accessibilityLabel(viewModel.primaryActionLabel)

            if viewModel.phase == .recording || viewModel.phase == .paused {
                Button {
                    viewModel.togglePause()
                } label: {
                    Image(systemName: viewModel.phase == .paused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .foregroundStyle(ThemeManager.Colors.textPrimary)
                        .frame(width: 56, height: 56)
                        .background(ThemeManager.Colors.surfaceElevated)
                        .clipShape(Circle())
                }
                .accessibilityLabel(viewModel.phase == .paused ? "继续录音" : "暂停录音")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var buttonColor: Color {
        switch viewModel.phase {
        case .idle, .finished: return ThemeManager.Colors.primary
        case .recording, .paused: return ThemeManager.Colors.danger
        case .analyzing: return ThemeManager.Colors.textSecondary
        }
    }

    private var buttonIcon: String {
        switch viewModel.phase {
        case .idle, .finished: return "mic.fill"
        case .recording, .paused: return "stop.fill"
        case .analyzing: return "hourglass"
        }
    }

    // MARK: 隐私说明与错误

    private var consentNote: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Label("录音前请取得对方同意", systemImage: "hand.raised")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            Text("音频只保存在本机，分析完成后立即删除，仅保留文字。使用 AI 分析时，转写出的文字会发送到分析服务。")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ThemeManager.Spacing.md)
        .background(ThemeManager.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
    }

    private func errorCard(_ error: AppError) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.danger)

            HStack(spacing: ThemeManager.Spacing.md) {
                switch error.recovery {
                case .openSettings:
                    Button("去设置") { openSettings() }
                case .retry:
                    Button("重试") { viewModel.retry() }
                case .upgrade:
                    Text("可明天再试，或在设置里查看剩余次数")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                case .reenter, .dismiss, .none:
                    EmptyView()
                }
                Spacer()
                Button("忽略") { viewModel.error = nil }
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }
            .font(ThemeManager.Typography.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ThemeManager.Spacing.md)
        .background(ThemeManager.Colors.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - 波形

struct WaveformIndicator: View {
    let isActive: Bool
    @State private var phase: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(ThemeManager.Colors.primary)
                    .frame(width: 6, height: barHeight(index))
            }
        }
        .onAppear {
            guard isActive, !reduceMotion else { return }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let base: CGFloat = 14
        let amplitude: CGFloat = 18
        let offset = sin(Double(index) * 0.9 + phase * .pi * 2)
        return base + amplitude * CGFloat((offset + 1) / 2)
    }
}

// MARK: - 视图模型

@MainActor
@Observable
final class RecordingViewModel {

    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case analyzing
        case finished
    }

    var phase: Phase = .idle
    var elapsed: TimeInterval = 0
    var liveTranscription: String = ""

    var profiles: [Profile] = []
    var selectedProfile: Profile?

    var error: AppError?
    var showPermissionAlert = false
    var permissionMessage = ""
    var completedSession: RecordingSession?

    /// 已停止但尚未成功分析的会话（用于「重试分析」）。
    private var pendingSession: RecordingSession?

    let recorder = RecordingService()
    private var analyzer: ConversationAnalyzing
    private var context: ModelContext?

    init(analyzer: ConversationAnalyzing? = nil) {
        self.analyzer = analyzer ?? AIService.shared
    }

    // MARK: 生命周期

    func onAppear(context: ModelContext) {
        self.context = context
        loadProfiles()
        syncFromRecorder()
    }

    private func loadProfiles() {
        guard let context else { return }
        do {
            profiles = try context.fetch(
                FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            )
            if selectedProfile == nil { selectedProfile = profiles.first }
        } catch {
            AppLog.persistence.error("Load profiles failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func syncFromRecorder() {
        elapsed = recorder.elapsed
        liveTranscription = recorder.transcription
        switch recorder.state {
        case .idle:      phase = .idle
        case .recording: phase = .recording
        case .paused:    phase = .paused
        case .finished:  phase = .finished
        case .preparing: phase = .recording
        }
    }

    // MARK: 状态文案

    var statusText: String {
        switch phase {
        case .idle:
            return profiles.isEmpty
                ? "先添加一个人，再开始记录"
                : "点击开始录音，锁屏也能继续"
        case .recording:
            return "正在录音 · 可锁屏放进兜里"
        case .paused:
            return "已暂停"
        case .analyzing:
            return "正在根据对话内容分析"
        case .finished:
            return "已结束"
        }
    }

    var canTapPrimary: Bool {
        if phase == .analyzing { return false }
        if profiles.isEmpty && phase == .idle { return false }
        return true
    }

    var primaryActionLabel: String {
        switch phase {
        case .idle, .finished: return "开始录音"
        case .recording, .paused: return "停止录音"
        case .analyzing: return "分析中"
        }
    }

    // MARK: 动作

    func primaryAction() {
        switch phase {
        case .idle, .finished:
            startRecording()
        case .recording, .paused:
            stopAndAnalyze()
        case .analyzing:
            break
        }
    }

    func togglePause() {
        switch phase {
        case .recording:
            recorder.pause()
            syncFromRecorder()
        case .paused:
            do {
                try recorder.resume()
                syncFromRecorder()
            } catch let appError as AppError {
                error = appError
            } catch {
                self.error = .recorderFailed(error.localizedDescription)
            }
        default:
            break
        }
    }

    func cancel() {
        recorder.cancel()
        phase = .idle
        elapsed = 0
        liveTranscription = ""
        error = nil
        Telemetry.shared.track(.recordingCancelled)
    }

    private func startRecording() {
        error = nil
        Task {
            do {
                try await recorder.start()
                syncFromRecorder()
                phase = .recording
                Telemetry.shared.track(.recordingStarted)
                startMirroring()
            } catch let appError as AppError {
                handleStartFailure(appError)
            } catch {
                handleStartFailure(.recorderFailed(error.localizedDescription))
            }
        }
    }

    private func handleStartFailure(_ appError: AppError) {
        error = appError
        switch appError.recovery {
        case .openSettings:
            permissionMessage = appError.localizedDescription + "。请到系统设置中开启对应权限。"
            showPermissionAlert = true
        default:
            break
        }
        phase = .idle
    }

    /// 把 recorder 的实时状态镜像到 ViewModel（recorder 是 @Observable，
    /// 但嵌套观察在 struct View 里不稳定，这里用定时同步保证刷新）。
    private func startMirroring() {
        Task { @MainActor in
            while recorder.state.isActive {
                elapsed = recorder.elapsed
                liveTranscription = recorder.transcription
                phase = recorder.state == .paused ? .paused : .recording
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            elapsed = recorder.elapsed
            liveTranscription = recorder.transcription
        }
    }

    private func stopAndAnalyze() {
        _ = recorder.stop()
        phase = .analyzing
        elapsed = recorder.elapsed
        liveTranscription = recorder.transcription

        Task { await analyzeCurrentRecording() }
    }

    private func analyzeCurrentRecording() async {
        guard let context else { return }

        let text = recorder.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioURL = recorder.audioFileURL

        // 1) 落库：无论分析成功与否，只要录到了内容就保存记录
        let session = RecordingSession(
            sessionType: .conflict,
            profile: selectedProfile,
            startedAt: Date().addingTimeInterval(-recorder.elapsed),
            endedAt: Date(),
            audioFileURL: nil
        )
        session.transcription = text.isEmpty ? nil : text
        context.insert(session)

        do {
            try context.save()
        } catch {
            AppLog.persistence.error("Save session failed: \(error.localizedDescription, privacy: .public)")
        }

        // 2) 音频只在内存/临时目录，分析后一律删除
        if let audioURL { RecordingService.removeFile(at: audioURL) }
        recorder.discardAudioFile()

        // 3) 没有转写就明确失败，绝不编造分析
        guard !text.isEmpty else {
            session.status = SessionStatus.completed.rawValue
            error = .emptyTranscription
            phase = .finished
            pendingSession = session
            Telemetry.shared.track(.analysisFailed)
            save(context)
            return
        }

        guard let profile = selectedProfile else {
            error = .persistenceFailed("请先选择这次记录关于谁")
            phase = .finished
            pendingSession = session
            return
        }

        // 4) 真实调用 AI
        do {
            let result = try await analyzer.analyze(
                conversation: text,
                counterpartName: profile.name,
                relationshipType: profile.relationship
            )
            session.analysisResult = result
            session.status = SessionStatus.analyzed.rawValue
            save(context)
            recorder.discardAudioFile()

            completedSession = session
            pendingSession = nil
            phase = .idle
            error = nil
            Telemetry.shared.track(.analysisSucceeded)

            // 24 小时回访（报告 N1）
            NotificationService.shared.scheduleReflectionFollowUp(sessionID: session.id)

            // 记录一次互动，用于「最近互动」与 Widget
            profile.lastInteractionAt = Date()
            profile.interactionCount += 1
            profile.updatedAt = Date()
            save(context)
            DataMaintenance.syncWidget(context: context)

        } catch let appError as AppError {
            session.status = SessionStatus.completed.rawValue
            save(context)
            error = appError
            phase = .finished
            pendingSession = session
            Telemetry.shared.track(.analysisFailed)
        } catch {
            session.status = SessionStatus.completed.rawValue
            save(context)
            self.error = .serverError(-1)
            phase = .finished
            pendingSession = session
        }
    }

    /// 重试：优先复用已保存的会话文本，避免重复录音。
    func retry() {
        error = nil
        if let session = pendingSession, let text = session.transcription, !text.isEmpty,
           let profile = selectedProfile {
            phase = .analyzing
            Task {
                do {
                    let result = try await analyzer.analyze(
                        conversation: text,
                        counterpartName: profile.name,
                        relationshipType: profile.relationship
                    )
                    session.analysisResult = result
                    session.status = SessionStatus.analyzed.rawValue
                    if let context { save(context) }
                    completedSession = session
                    pendingSession = nil
                    phase = .idle
                    Telemetry.shared.track(.analysisSucceeded)
                } catch let appError as AppError {
                    self.error = appError
                    phase = .finished
                } catch {
                    self.error = .serverError(-1)
                    phase = .finished
                }
            }
        } else {
            phase = .idle
        }
    }

    private func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            AppLog.persistence.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
