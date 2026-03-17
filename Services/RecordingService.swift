import AVFoundation
import Speech

@Observable
class ManualConflictRecordingService {
    var isRecording = false
    var recordingDuration: TimeInterval = 0
    var audioRecorder: AVAudioRecorder?
    var transcription: String = ""
    var error: RecordingError?
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var timer: Timer?
    
    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }
    
    // MARK: - 检查权限
    func checkPermissions() async -> Bool {
        // 检查麦克风权限
        let micStatus = await AVAudioSession.sharedInstance().requestRecordPermission()
        
        // 检查语音识别权限
        let speechStatus = await SFSpeechRecognizer.requestAuthorization()
        
        return micStatus && speechStatus == .authorized
    }
    
    // MARK: - 开始录音
    func startRecording() async throws {
        // 1. 确保权限已获取
        guard await checkPermissions() else {
            throw RecordingError.permissionDenied
        }
        
        // 2. 配置音频会话
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
        
        // 3. 配置录音器
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFileURL = documentsPath.appendingPathComponent("conflict_\(UUID().uuidString).m4a")
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        audioRecorder = try AVAudioRecorder(url: audioFileURL, settings: settings)
        audioRecorder?.record()
        isRecording = true
        
        // 4. 开始计时
        startTimer()
    }
    
    // MARK: - 停止录音
    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        stopTimer()
        
        // 转录音频
        Task {
            await transcribeAudio()
        }
    }
    
    // MARK: - 音频转录
    private func transcribeAudio() async {
        guard let audioURL = audioRecorder?.url else { return }
        
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        
        do {
            if let result = try await recognizer?.recognitionTask(with: request) {
                transcription = result.bestTranscription.formattedString
            }
        } catch {
            self.error = .transcriptionFailed(error)
        }
    }
    
    // MARK: - 取消录音
    func cancelRecording() {
        audioRecorder?.stop()
        isRecording = false
        stopTimer()
        recordingDuration = 0
        
        // 删除录音文件
        if let url = audioRecorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    // MARK: - 获取录音文件URL
    func getRecordingURL() -> URL? {
        return audioRecorder?.url
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

enum RecordingError: Error {
    case permissionDenied
    case setupFailed
    case transcriptionFailed(Error)
    case audioTooShort
    case audioTooLong
}
