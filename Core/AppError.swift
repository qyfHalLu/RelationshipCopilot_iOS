//
//  AppError.swift
//  RelationshipCopilot
//
//  统一错误类型。
//  修复报告 A4：原实现 13 处 `try?` 静默吞错、6 处 `print` 代替提示，
//  且 `RecordingView` 把所有 catch 都映射成「需要麦克风权限」，误导用户去翻设置。
//
//  每个 case 都自带面向用户的文案与「下一步该做什么」，UI 不再各自判断。
//

import Foundation

/// 用户可理解的错误，携带建议动作。
enum AppError: LocalizedError, Equatable {
    // 权限
    case microphoneDenied
    case speechRecognitionDenied
    case speechRecognitionRestricted

    // 录音
    case audioSessionFailed(String)
    case recorderFailed(String)
    case transcriptionFailed(String)
    case emptyTranscription

    // 网络与 AI
    case offline
    case timedOut
    case serverError(Int)
    case unauthorized
    case quotaExceeded
    case malformedAIResponse(String)
    case aiNotConfigured
    case busy

    /// 撞到模型服务端的速率上限（RPM / TPM）。与 `quotaExceeded` 不同：
    /// 后者是"今天用完了"，前者是"这一分钟太密了，等几秒就好"。
    /// 两者混淆会让用户以为要等明天，实际只需要等 20 秒。
    case rateLimited(String)

    // 认证
    case invalidPhone
    case invalidCode
    case biometricUnavailable
    case keychainFailed(String)

    // 数据
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "没有麦克风权限，无法录音"
        case .speechRecognitionDenied:
            return "没有语音识别权限，无法把录音转成文字"
        case .speechRecognitionRestricted:
            return "此设备限制了语音识别功能"
        case .audioSessionFailed:
            return "音频初始化失败"
        case .recorderFailed:
            return "录音启动失败"
        case .transcriptionFailed:
            return "转录失败"
        case .emptyTranscription:
            return "没有识别到内容，可能环境太吵或录音太短"
        case .offline:
            return "网络不可用"
        case .timedOut:
            return "请求超时"
        case .serverError(let code):
            return "服务暂时不可用（\(code)）"
        case .unauthorized:
            return "AI 服务凭证无效，已停止本次调用"
        case .quotaExceeded:
            return "今日免费分析次数已用完"
        case .malformedAIResponse:
            return "AI 返回的内容无法解析"
        case .aiNotConfigured:
            return "AI 服务尚未配置"
        case .busy:
            return "正在分析中，请稍候"
        case .rateLimited(let message):
            return message
        case .invalidPhone:
            return "请输入 11 位手机号"
        case .invalidCode:
            return "验证码不正确"
        case .biometricUnavailable:
            return "此设备未启用面容 ID"
        case .keychainFailed:
            return "安全存储读写失败"
        case .persistenceFailed:
            return "数据保存失败"
        }
    }

    /// 建议动作：UI 据此决定展示「去设置」/「重试」/「升级」按钮。
    enum Recovery: Equatable {
        case openSettings
        case retry
        case upgrade
        case reenter
        case dismiss
        case none
    }

    var recovery: Recovery {
        switch self {
        case .microphoneDenied, .speechRecognitionDenied: return .openSettings
        case .speechRecognitionRestricted:                return .dismiss
        case .audioSessionFailed, .recorderFailed:        return .retry
        case .transcriptionFailed, .emptyTranscription:   return .retry
        case .offline, .timedOut, .serverError:           return .retry
        case .unauthorized:                               return .dismiss
        case .quotaExceeded:                              return .upgrade
        case .rateLimited:                                return .retry
        case .malformedAIResponse:                        return .retry
        case .aiNotConfigured:                            return .dismiss
        case .busy:                                       return .none
        case .invalidPhone, .invalidCode:                 return .reenter
        case .biometricUnavailable:                       return .reenter
        case .keychainFailed, .persistenceFailed:         return .retry
        }
    }

    /// 是否值得在 UI 上打断用户（配额不足属于正常业务流，用轻提示）。
    var isBlocking: Bool {
        switch self {
        case .quotaExceeded, .rateLimited: return false
        default: return true
        }
    }

    /// 把底层错误归一化，避免把 URLError 直接抛给用户。
    static func fromNetwork(_ error: Error) -> AppError {
        guard let urlError = error as? URLError else {
            return .serverError(-1)
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .offline
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .timedOut
        default:
            return .serverError(urlError.errorCode)
        }
    }
}
