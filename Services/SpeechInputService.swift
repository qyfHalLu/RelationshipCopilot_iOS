//
//  SpeechInputService.swift
//  RelationshipCopilot
//
//  语音输入：把说的话实时转成文字，追加进一个文本框。
//
//  ## 为什么不复用 RecordingService
//
//  `RecordingService` 承载的是"录一段对话做分析"——它要存音频文件、计时、
//  配置后台音频、管理会话生命周期。那是另一件事。
//
//  语音输入只需要一件事：**边说边出字**。不落文件、不计时、退出即销毁。
//  两者混在一起会让那个本来就复杂的服务更难维护，也会让"录音分析"意外获得
//  "输入框"的语义。
//
//  ## 关键实现约束（前车之鉴）
//
//  `RecordingService` 的头注释记录过一次真实崩溃：用 `withCheckedContinuation`
//  包 recognitionTask 回调，每个回调都 `resume()`，于是同一 continuation
//  resume 多次 → 崩溃。这里用 **`AsyncStream`** 承接部分结果，天然没有这个问题：
//  stream 可以持续产事件，不需要"一次性唤醒"的语义。
//

import Foundation
import Speech
import AVFoundation
import Observation

/// 语音输入的错误。**每个都有明确的下一步**，不能只显示"出错了"。
enum SpeechInputError: LocalizedError, Equatable {
    case microphoneDenied
    case speechDenied
    case recognizerUnavailable
    case audioSessionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "没有麦克风权限。请到「设置 → 关系副驾」里打开麦克风"
        case .speechDenied:
            return "没有语音识别权限。请到「设置 → 关系副驾」里打开语音识别"
        case .recognizerUnavailable:
            return "这台设备暂时无法识别中文语音"
        case .audioSessionFailed(let detail):
            return "无法开始录音：\(detail)"
        }
    }
}

/// 同一屏只允许一个语音输入在录。
///
/// ## 为什么必须协调
///
/// 道歉准备的第 3 步有七个格子，每格一个麦克风。每个按钮各自持有一个
/// `SpeechInputService`，也就各自持有一个 `AVAudioEngine`。
///
/// 同时开两个的后果不是"第二个报错"，而是**更坏的静默错**：
/// 第二次 `AVAudioSession.setActive(true)` 通常仍然成功（iOS 不阻拦），
/// 但两个 engine 各自往自己的 `SFSpeechAudioBufferRecognitionRequest` 里喂 buffer，
/// 于是两个输入框同时出现文字 —— 用户以为自己在给第二格说话，字却写进了第一格。
///
/// 所以录之前先"占坑"，占了就把别人停掉。这不是锦上添花：
/// 没有它，七个格子反而比一个格子更容易写错。
@Observable
@MainActor
final class VoiceInputCoordinator {
    static let shared = VoiceInputCoordinator()

    /// 当前占着麦克风的按钮。
    private(set) var active: UUID?

    func claim(_ token: UUID) {
        active = token
    }

    func release(_ token: UUID) {
        // 只释放自己占的那一坑。晚到的 release 不能把别人的坑清掉 ——
        // 例如 A 开始录、B 抢占、A 的回调随后到达。
        if active == token { active = nil }
    }

    /// 自己没占坑、却有人在录 → 说明被抢占了，应当停。
    func isPreempted(_ token: UUID) -> Bool {
        guard let active else { return false }
        return active != token
    }
}

@Observable
@MainActor
final class SpeechInputService {

    /// 是否正在听。
    private(set) var isRecording = false
    /// 本次识别到目前为止的文本（不含用户原有的内容）。
    private(set) var transcript = ""
    /// 出错时的原因。
    private(set) var error: SpeechInputError?

    /// 音频电平（0…1），用来给按钮做呼吸动画。
    /// 没有反馈的录音按钮会让人怀疑"到底有没有在录"。
    private(set) var level: Double = 0

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var streamTask: Task<Void, Never>?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    // MARK: 开始 / 停止

    /// 开始听。返回是否成功启动（失败原因见 `error`）。
    @discardableResult
    func start() async -> Bool {
        guard !isRecording else { return true }
        error = nil
        transcript = ""

        guard await requestMicrophone() else {
            error = .microphoneDenied
            return false
        }
        guard await requestSpeech() else {
            error = .speechDenied
            return false
        }
        guard let recognizer, recognizer.isAvailable else {
            error = .recognizerUnavailable
            return false
        }

        do {
            try configureSession()
        } catch {
            self.error = .audioSessionFailed(error.localizedDescription)
            return false
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 优先端侧识别：语音内容是这个产品里最私密的东西之一，
        // 能不出设备就不出设备。设备不支持时系统会自动回落到服务端。
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.removeTap(onBus: 0)
        // 内外两层都要 weak：引擎被 self 持有，tap 又被引擎持有，
        // 中间强引用 self 就是一条环，页面退出后麦克风不一定会停。
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            // 在音频回调里算电平，主线程只做展示
            let level = Self.level(of: buffer)
            Task { @MainActor in
                self?.level = level
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = .audioSessionFailed(error.localizedDescription)
            deactivateSession()
            return false
        }

        self.engine = engine
        self.request = request
        isRecording = true

        // 用 AsyncStream 承接识别结果，避免 continuation 多次 resume。
        let stream = AsyncStream<String> { continuation in
            self.task = recognizer.recognitionTask(with: request) { result, recognitionError in
                if let result {
                    continuation.yield(result.bestTranscription.formattedString)
                    if result.isFinal { continuation.finish() }
                }
                if recognitionError != nil { continuation.finish() }
            }
        }

        streamTask = Task { @MainActor [weak self] in
            for await text in stream {
                guard let self else { break }
                self.transcript = text
                // 说话停顿后识别会自动结束，UI 状态要跟上
                if self.task?.state == .completed { break }
            }
            self?.finishIfNeeded()
        }

        return true
    }

    /// 清掉错误提示（用户点了「知道了」之后）。
    func clearError() {
        error = nil
    }

    /// 停止听，保留已识别的文本。
    func stop() {
        guard isRecording else { return }
        finishIfNeeded()
    }

    /// 取消：停止并清空，不保留任何文字。
    func cancel() {
        guard isRecording else { return }
        finishIfNeeded()
        transcript = ""
    }

    // MARK: 内部

    private func finishIfNeeded() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        streamTask?.cancel()
        streamTask = nil
        isRecording = false
        level = 0
        deactivateSession()
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.measurement` 更贴近人声，且不做额外处理；`.record` 只录不放。
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestMicrophone() async -> Bool {
        // iOS 17 起录音权限迁到 `AVAudioApplication`，
        // `AVAudioSession.recordPermission` 已标记废弃。部署目标正好是 17.0，
        // 直接用新 API，避免以后升级 SDK 时才被迫改。
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func requestSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    /// 音频缓冲的 RMS 电平，归一化到 0…1。
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = data[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        // -50dB…0dB 映射到 0…1
        let db = 20 * log10(max(rms, 1e-7))
        return min(max(Double((db + 50) / 50), 0), 1)
    }
}
