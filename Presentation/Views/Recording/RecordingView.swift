import SwiftUI
import AVFoundation

struct RecordingView: View {
    @State private var viewModel = RecordingViewModel()
    
    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.Colors.background.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 顶部提示
                    if viewModel.recordingState == .idle {
                        RecordingTipCard()
                    }
                    
                    Spacer()
                    
                    // 录音状态显示
                    RecordingStatusView(viewModel: viewModel)
                    
                    Spacer()
                    
                    // 录音控制按钮
                    RecordingControls(viewModel: viewModel)
                        .padding(.bottom, 40)
                }
            }
            .navigationTitle("记录对话")
            .navigationBarTitleDisplayMode(.large)
        }
        .alert("需要权限", isPresented: $viewModel.showPermissionAlert) {
            Button("去设置") {
                viewModel.openSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("需要麦克风权限来录制对话。请在设置中开启权限。")
        }
        .sheet(isPresented: $viewModel.showAnalysisSheet) {
            AnalysisResultView(transcription: viewModel.transcription)
        }
    }
}

// MARK: - 录音提示卡片
struct RecordingTipCard: View {
    @State private var isVisible = false
    
    var body: some View {
        HStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "info.circle.fill")
                .font(.title3)
                .foregroundColor(ThemeManager.Colors.primary)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("录音说明")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundColor(ThemeManager.Colors.textPrimary)
                
                Text("点击下方按钮开始录音，录音仅用于生成分析报告，不会自动上传。")
                    .font(ThemeManager.Typography.caption)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
                    .lineLimit(2)
            }
            
            Spacer()
        }
        .padding(ThemeManager.Spacing.md)
        .background(Color.white)
        .cornerRadius(ThemeManager.Radius.md)
        .shadow(ThemeManager.Shadows.sm)
        .padding(.horizontal, ThemeManager.Spacing.md)
        .padding(.top, ThemeManager.Spacing.md)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : -20)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                isVisible = true
            }
        }
    }
}

// MARK: - 录音状态视图
struct RecordingStatusView: View {
    @Bindable var viewModel: RecordingViewModel
    @State private var pulseAnimation = false
    
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.xl) {
            // 波形动画
            ZStack {
                // 外圈脉冲
                if viewModel.recordingState == .recording {
                    Circle()
                        .stroke(ThemeManager.Colors.primary.opacity(0.3), lineWidth: 2)
                        .frame(width: 200, height: 200)
                        .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                        .opacity(pulseAnimation ? 0 : 1)
                        .animation(
                            .easeInOut(duration: 1.5).repeatForever(autoreverses: false),
                            value: pulseAnimation
                        )
                }
                
                // 内圈
                Circle()
                    .fill(viewModel.recordingState == .recording ? ThemeManager.Colors.primary.opacity(0.1) : Color.white)
                    .frame(width: 160, height: 160)
                    .shadow(ThemeManager.Shadows.lg)
                
                // 麦克风图标或波形
                if viewModel.recordingState == .recording {
                    AudioWaveformView()
                        .frame(width: 80, height: 60)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 48))
                        .foregroundColor(viewModel.recordingState == .recording ? ThemeManager.Colors.primary : ThemeManager.Colors.textSecondary)
                }
            }
            .onAppear {
                if viewModel.recordingState == .recording {
                    pulseAnimation = true
                }
            }
            
            // 时长显示
            if viewModel.recordingState == .recording {
                Text(viewModel.formattedDuration)
                    .font(.system(size: 48, weight: .medium, design: .monospaced))
                    .foregroundColor(ThemeManager.Colors.textPrimary)
                    .transition(.scale.combined(with: .opacity))
            } else if viewModel.recordingState == .analyzing {
                AnalyzingView()
            } else {
                Text("点击开始录音")
                    .font(ThemeManager.Typography.title3)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
            }
            
            // 状态提示
            if viewModel.recordingState == .recording {
                Text("正在录音...")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundColor(ThemeManager.Colors.primary)
            }
        }
    }
}

// MARK: - 音频波形视图
struct AudioWaveformView: View {
    @State private var phase = 0.0
    let bars = 7
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<bars, id: \.self) { index in
                AudioBar(index: index, phase: phase)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 0.1).repeatForever(autoreverses: false)) {
                phase += .pi * 2
            }
        }
    }
}

// MARK: - 音频条
struct AudioBar: View {
    let index: Int
    let phase: Double
    
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(ThemeManager.Colors.primary)
            .frame(width: 6, height: height)
            .animation(.easeInOut(duration: 0.3), value: phase)
    }
    
    private var height: CGFloat {
        let baseHeight: CGFloat = 20
        let variance = sin(phase + Double(index) * 0.5) * 15
        return max(8, baseHeight + variance)
    }
}

// MARK: - 分析中视图
struct AnalyzingView: View {
    @State private var rotation = 0.0
    
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            ZStack {
                Circle()
                    .stroke(ThemeManager.Colors.border, lineWidth: 4)
                    .frame(width: 60, height: 60)
                
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(ThemeManager.Colors.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(rotation))
            }
            
            Text("AI分析中...")
                .font(ThemeManager.Typography.subheadline)
                .foregroundColor(ThemeManager.Colors.textSecondary)
        }
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - 录音控制按钮
struct RecordingControls: View {
    @Bindable var viewModel: RecordingViewModel
    @State private var buttonScale = 1.0
    
    var body: some View {
        HStack(spacing: ThemeManager.Spacing.xl) {
            // 取消按钮（仅在录音中显示）
            if viewModel.recordingState == .recording {
                Button(action: {
                    viewModel.cancelRecording()
                }) {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .foregroundColor(ThemeManager.Colors.textSecondary)
                        .frame(width: 60, height: 60)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(ThemeManager.Shadows.md)
                }
                .transition(.scale.combined(with: .opacity))
            }
            
            // 主按钮
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    buttonScale = 0.9
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    buttonScale = 1.0
                }
                
                switch viewModel.recordingState {
                case .idle:
                    viewModel.startRecording()
                case .recording:
                    viewModel.stopRecording()
                case .analyzing:
                    break
                }
            }) {
                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 80, height: 80)
                        .shadow(ThemeManager.Shadows.lg)
                    
                    Image(systemName: buttonIcon)
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }
            }
            .scaleEffect(buttonScale)
            .disabled(viewModel.recordingState == .analyzing)
            
            // 占位（保持对称）
            if viewModel.recordingState == .recording {
                Color.clear
                    .frame(width: 60, height: 60)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
    
    private var buttonColor: Color {
        switch viewModel.recordingState {
        case .idle:
            return ThemeManager.Colors.primary
        case .recording:
            return ThemeManager.Colors.danger
        case .analyzing:
            return ThemeManager.Colors.textSecondary
        }
    }
    
    private var buttonIcon: String {
        switch viewModel.recordingState {
        case .idle:
            return "mic.fill"
        case .recording:
            return "stop.fill"
        case .analyzing:
            return "hourglass"
        }
    }
}

// MARK: - 分析结果视图
struct AnalysisResultView: View {
    let transcription: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.lg) {
                    // 情绪分析卡片
                    EmotionAnalysisCard()
                    
                    // 沟通建议卡片
                    CommunicationAdviceCard()
                    
                    // 转录文本
                    TranscriptionCard(text: transcription)
                }
                .padding(ThemeManager.Spacing.md)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("分析结果")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 情绪分析卡片
struct EmotionAnalysisCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("情绪分析")
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            HStack(spacing: ThemeManager.Spacing.lg) {
                EmotionIndicator(
                    label: "你的情绪",
                    score: 65,
                    color: .blue
                )
                
                EmotionIndicator(
                    label: "对方情绪",
                    score: 45,
                    color: .orange
                )
            }
            
            Text("双方情绪存在差异，建议先平复情绪再沟通")
                .font(ThemeManager.Typography.subheadline)
                .foregroundColor(ThemeManager.Colors.textSecondary)
        }
        .padding(ThemeManager.Spacing.lg)
        .background(Color.white)
        .cornerRadius(ThemeManager.Radius.lg)
        .shadow(ThemeManager.Shadows.md)
    }
}

// MARK: - 情绪指示器
struct EmotionIndicator: View {
    let label: String
    let score: Int
    let color: Color
    
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.sm) {
            Text(label)
                .font(ThemeManager.Typography.caption)
                .foregroundColor(ThemeManager.Colors.textSecondary)
            
            Text("\(score)")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(color)
            
            // 进度条
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ThemeManager.Colors.border)
                        .frame(height: 4)
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(score) / 100, height: 4)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 沟通建议卡片
struct CommunicationAdviceCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("沟通建议")
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                AdviceItem(
                    icon: "1.circle.fill",
                    text: "使用'我感到...'句式表达感受，避免指责"
                )
                
                AdviceItem(
                    icon: "2.circle.fill",
                    text: "给对方表达的机会，认真倾听"
                )
                
                AdviceItem(
                    icon: "3.circle.fill",
                    text: "寻找双方都能接受的解决方案"
                )
            }
        }
        .padding(ThemeManager.Spacing.lg)
        .background(Color.white)
        .cornerRadius(ThemeManager.Radius.lg)
        .shadow(ThemeManager.Shadows.md)
    }
}

// MARK: - 建议项
struct AdviceItem: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: ThemeManager.Spacing.sm) {
            Image(systemName: icon)
                .foregroundColor(ThemeManager.Colors.primary)
            
            Text(text)
                .font(ThemeManager.Typography.subheadline)
                .foregroundColor(ThemeManager.Colors.textPrimary)
        }
    }
}

// MARK: - 转录文本卡片
struct TranscriptionCard: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("对话记录")
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            Text(text.isEmpty ? "暂无转录内容" : text)
                .font(ThemeManager.Typography.body)
                .foregroundColor(ThemeManager.Colors.textSecondary)
                .lineLimit(nil)
        }
        .padding(ThemeManager.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(ThemeManager.Radius.lg)
        .shadow(ThemeManager.Shadows.md)
    }
}

// MARK: - 录音视图模型
@Observable
class RecordingViewModel {
    enum RecordingState {
        case idle
        case recording
        case analyzing
    }
    
    var recordingState: RecordingState = .idle
    var recordingDuration: TimeInterval = 0
    var transcription: String = ""
    var showPermissionAlert = false
    var showAnalysisSheet = false
    
    private var recordingService = ManualConflictRecordingService()
    private var timer: Timer?
    
    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    func startRecording() {
        Task {
            do {
                try await recordingService.startRecording()
                await MainActor.run {
                    recordingState = .recording
                    startTimer()
                }
            } catch {
                await MainActor.run {
                    showPermissionAlert = true
                }
            }
        }
    }
    
    func stopRecording() {
        recordingService.stopRecording()
        stopTimer()
        
        recordingState = .analyzing
        
        // 模拟分析过程
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                transcription = "这是模拟的对话转录内容。在实际应用中，这里会显示AI转录的对话文本。"
                recordingState = .idle
                recordingDuration = 0
                showAnalysisSheet = true
            }
        }
    }
    
    func cancelRecording() {
        recordingService.stopRecording()
        stopTimer()
        recordingState = .idle
        recordingDuration = 0
    }
    
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.recordingDuration += 1
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
