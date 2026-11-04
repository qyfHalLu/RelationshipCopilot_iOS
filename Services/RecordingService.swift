//
//  RecordingService.swift
//  RelationshipCopilot
//
//  录音 + 实时转写。
//
//  修复报告 B1 / B2 / B3 / B4 / B5：
//   - B1：权限请求拆成麦克风 / 语音识别两条，并返回**具体**失败原因（原 `checkPermissions()` 只回 Bool，
//         UI 无法区分是哪一项被拒，只能笼统提示"需要麦克风权限"）。
//   - B2：原实现用 `withCheckedContinuation` 包 `recognitionTask` 回调，每个回调都 `resume()`，
//         第二次会触发 SWIFT TASK CONTINUATION MISUSE 崩溃；且非 final 回调也会提前 resume。
//         现改为「单次 resume 守卫」并用 AVAudioEngine 流式识别，天然避免该问题。
//   - B3：音频落 `Documents`（会进 iCloud 备份）且取消路径不删文件。现改存 `Caches/Recordings`，
//         设 `isExcludedFromBackup`，分析完成/取消后删除，并在启动时清理孤儿文件。
//   - B4：`UIBackgroundModes` 增加 `audio`，配置 `AVAudioSession` 与中断处理，
//         锁屏/切后台不中断录音（这是"记录真实对话"的前提）。
//   - B5：改为流式识别（`SFSpeechAudioBufferRecognitionRequest`），不再受单次 URL 请求
//         约 1 分钟的时长限制；同时给出实时转写，用户能立刻发现"没录到声音"。
//
//  iOS 27 适配：
//   - 使用 `AVAudioApplication.requestRecordPermission`（`AVAudioSession.requestRecordPermission` 已废弃）。
//   - 不使用 `AVAssetExportSession.exportAsynchronously`（iOS 18 起废弃），因此不采用"切片导出"方案。
//   - 音频线程只做写入，所有 UI 状态通过 `Task { @MainActor in }` 回主线程。
//

import AVFoundation
import Speech
import Foundation

// MARK: - 权限

enum RecordingPermission: Equatable {
    case granted
    case microphoneDenied
    case speechDenied
    case speechRestricted

    var isGranted: Bool { self == .granted }

    var asAppError: AppError? {
        switch self {
        case .granted:            return nil
        case .microphoneDenied:   return .microphoneDenied
        case .speechDenied:       return .speechRecognitionDenied
        case .speechRestricted:   return .speechRecognitionRestricted
        }
    }
}

// MARK: - 服务

@MainActor
@Observable
final class RecordingService {

    // MARK: 状态

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case finished

        var isActive: Bool { self == .recording || self == .paused }
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// 流式转写文本（实时更新）。
    private(set) var transcription: String = ""
    /// 本次录音的输出文件。
    private(set) var audioFileURL: URL?
    var error: AppError?

    // MARK: 依赖

    private let speechRecognizer: SFSpeechRecognizer?
    private let audioSession = AVAudioSession.sharedInstance()

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var startedAt: Date?
    private var accumulatedBeforePause: TimeInterval = 0

    /// 单次录音时长上限（30 分钟）。避免无限增长与后台被系统回收后的数据丢失。
    static let maxDuration: TimeInterval = 30 * 60

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }

    // MARK: - 权限

    /// 分别请求麦克风与语音识别权限，返回具体结果。
    func requestPermissions() async -> RecordingPermission {
        let micGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micGranted else { return .microphoneDenied }

        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        switch speechStatus {
        case .authorized: return .granted
        case .denied:     return .speechDenied
        case .restricted: return .speechRestricted
        case .notDetermined: return .speechDenied
        @unknown default: return .speechDenied
        }
    }

    // MARK: - 开始

    func start() async throws {
        guard state == .idle || state == .finished else { return }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw AppError.speechRecognitionRestricted
        }

        let permission = await requestPermissions()
        if let appError = permission.asAppError { throw appError }

        state = .preparing
        defer { if state == .preparing { state = .idle } }

        // 1) 音频会话：录音 + 允许蓝牙耳机（伴侣对话常戴耳机/免提）
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .idle
            throw AppError.audioSessionFailed(error.localizedDescription)
        }

        // 2) 输出文件：Caches/Recordings，且不进 iCloud 备份
        let url: URL
        do {
            url = try Self.makeOutputURL()
        } catch {
            state = .idle
            throw AppError.recorderFailed("无法创建录音文件")
        }

        // 3) 引擎 + 文件句柄
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            state = .idle
            throw AppError.recorderFailed("麦克风不可用")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            state = .idle
            throw AppError.recorderFailed("无法写入录音文件")
        }

        // 4) 流式识别请求
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            // 优先端侧识别：更快、不把对话内容发往服务器，隐私更好
            request.requiresOnDeviceRecognition = true
        }

        let recognizerRef = recognizer
        let requestRef = request
        // 音频线程只做 buffer 写入与 append，不触碰 UI 状态
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            try? file.write(from: buffer)
            requestRef.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            state = .idle
            throw AppError.recorderFailed(error.localizedDescription)
        }

        self.engine = engine
        self.audioFile = file
        self.recognitionRequest = request
        self.audioFileURL = url
        self.startedAt = Date()
        self.accumulatedBeforePause = 0
        self.elapsed = 0
        self.transcription = ""
        self.error = nil

        startRecognitionTask(with: recognizerRef, request: requestRef)
        startTimer()
        registerInterruptionObserver()

        state = .recording
        AppLog.recording.info("Recording started, onDevice=\(recognizer.supportsOnDeviceRecognition, privacy: .public)")
    }

    private func startRecognitionTask(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest) {
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, taskError in
            // 回调在任意线程，统一切回主线程再改状态
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcription = result.bestTranscription.formattedString
                }
                if let taskError, self.state.isActive {
                    AppLog.recording.error("Recognition failed: \(taskError.localizedDescription, privacy: .public)")
                    // 识别失败不应终止录音：音频仍在写入，用户可稍后重试识别
                    self.error = .transcriptionFailed(taskError.localizedDescription)
                }
            }
        }
    }

    // MARK: - 暂停 / 继续

    func pause() {
        guard state == .recording else { return }
        accumulatedBeforePause = elapsed
        engine?.pause()
        stopTimer()
        state = .paused
    }

    func resume() throws {
        guard state == .paused else { return }
        do {
            try engine?.start()
        } catch {
            throw AppError.recorderFailed(error.localizedDescription)
        }
        startTimer()
        state = .recording
    }

    // MARK: - 结束

    /// 结束录音并返回音频文件（可能为 nil）。
    @discardableResult
    func stop() -> URL? {
        guard state.isActive else { return audioFileURL }
        teardown()
        state = .finished
        AppLog.recording.info("Recording stopped, duration=\(self.elapsed, privacy: .public)")
        return audioFileURL
    }

    /// 取消：结束并删除文件（修复 B3：原取消路径调的是 `stopRecording()`，文件从未被删）。
    func cancel() {
        let url = audioFileURL
        if state.isActive { teardown() }
        state = .idle
        transcription = ""
        elapsed = 0
        audioFileURL = nil
        if let url { Self.removeFile(at: url) }
    }

    /// 分析完成后调用：释放音频文件，只保留文本。
    func discardAudioFile() {
        if let url = audioFileURL {
            Self.removeFile(at: url)
        }
        audioFileURL = nil
    }

    private func teardown() {
        stopTimer()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        audioFile = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
    }

    // MARK: - 计时

    private func startTimer() {
        timer?.invalidate()
        let base = accumulatedBeforePause
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = base + Date().timeIntervalSince(start)
                self.elapsed = now
                if now >= Self.maxDuration {
                    // 到达上限自动停止，避免后台被回收导致文件损坏
                    _ = self.stop()
                }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 中断处理（来电、闹钟）

    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            switch type {
            case .began:
                self.pause()
            case .ended:
                let optionsRaw = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume) {
                    try? self.audioSession.setActive(true)
                    try? self.resume()
                }
            @unknown default:
                break
            }
        }
    }

    // MARK: - 文件管理

    /// 录音目录：Caches/Recordings（不进 iCloud 备份，可被系统在空间不足时清理）。
    static func recordingsDirectory() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = directory
            try? mutable.setResourceValues(values)
        }
        return directory
    }

    private static func makeOutputURL() throws -> URL {
        let directory = try recordingsDirectory()
        return directory.appendingPathComponent("recording_\(UUID().uuidString).caf")
    }

    static func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 启动时清理孤儿音频：任何残留文件都删除。
    /// 因为音频只在本次录音内使用，分析完成后即删；遗留文件必然是异常退出产生。
    @discardableResult
    static func cleanupOrphanRecordings() -> Int {
        guard let directory = try? recordingsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else { return 0 }
        var removed = 0
        for file in files {
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        if removed > 0 {
            AppLog.recording.info("Cleaned \(removed) orphan recording(s)")
        }
        return removed
    }
}

// 兼容旧引用名（保留一个版本周期后删除）
@available(*, deprecated, renamed: "RecordingService")
typealias ManualConflictRecordingService = RecordingService

// MARK: - 错误类型（保留以兼容既有引用）

enum RecordingError: LocalizedError {
    case permissionDenied
    case setupFailed
    case transcriptionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:  return "录音权限被拒绝"
        case .setupFailed:       return "录音设置失败"
        case .transcriptionFailed(let error): return "转录失败: \(error.localizedDescription)"
        }
    }
}
