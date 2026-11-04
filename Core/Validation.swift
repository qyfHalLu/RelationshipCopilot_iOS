//
//  Validation.swift
//  RelationshipCopilot
//
//  输入校验的唯一入口。
//  修复报告 C7：原实现 `isFormValid` 仅判断 `phoneNumber.count == 11`，
//  任意 11 个字符都能通过；验证码同样只数字数。
//

import Foundation

enum Validation {

    /// 中国大陆手机号：1 开头 + 第二位 3-9 + 共 11 位。
    static func isValidPhone(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 11 else { return false }
        guard digits.hasPrefix("1") else { return false }
        let second = digits[digits.index(digits.startIndex, offsetBy: 1)]
        return ("3456789".contains(second))
    }

    /// 归一化手机号：去掉空格、横线、+86 前缀。
    static func normalizePhone(_ raw: String) -> String {
        var digits = raw.filter(\.isNumber)
        for prefix in ["86"] where digits.count == 13 && digits.hasPrefix(prefix) {
            digits = String(digits.dropFirst(prefix.count))
        }
        return String(digits.prefix(11))
    }

    /// 验证码：6 位数字。
    static func isValidCode(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        return digits.count == 6
    }

    /// 只保留数字，并限制最大长度（用于 TextField 实时过滤）。
    static func digitsOnly(_ raw: String, maxLength: Int) -> String {
        String(raw.filter(\.isNumber).prefix(maxLength))
    }

    /// 姓名/承诺内容等必填文本。
    static func isNonEmpty(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 备注类可选文本归一化：全空白视为 nil。
    static func optionalText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
