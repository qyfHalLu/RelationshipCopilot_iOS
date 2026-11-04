//
//  RelationshipCopilotWidget.swift
//  RelationshipCopilotWidget
//
//  小组件。
//
//  改版说明（删除关系健康度）：
//  原 Widget 的全部三个尺寸都在展示一个 0–100 的「健康分」，那个分数由
//  `70 + intimacy * 3` 得出 —— 用户自己拖滑块的值。桌面是产品**曝光最频繁**的界面，
//  把伪指标放在这里，等于每天几十次强化「有人在评估你的关系」这个错误印象。
//
//  现在改为三个**可数**的量：
//    · 今天还没打卡的承诺
//    · 进行中的评理
//    · 上次评理距今多久
//  它们不需要任何解释性免责，因为每一个都能指到具体的那条数据。
//

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct RelationshipEntry: TimelineEntry {
    let date: Date
    let profileName: String
    /// 今天还没打卡的承诺数。
    let pendingPromiseCount: Int
    /// 进行中的评理件数（写到一半或已就绪未查看）。
    let activeCaseCount: Int
    let lastCaseDate: Date?
    let lastAnalysisDate: Date?
    let hasNewNotifications: Bool
    var hasData: Bool = true

    static func placeholder() -> RelationshipEntry {
        RelationshipEntry(
            date: Date(),
            profileName: "小林",
            pendingPromiseCount: 2,
            activeCaseCount: 1,
            lastCaseDate: Date().addingTimeInterval(-3600 * 5),
            lastAnalysisDate: Date().addingTimeInterval(-86400),
            hasNewNotifications: false,
            hasData: true
        )
    }

    static func empty() -> RelationshipEntry {
        RelationshipEntry(
            date: Date(),
            profileName: "",
            pendingPromiseCount: 0,
            activeCaseCount: 0,
            lastCaseDate: nil,
            lastAnalysisDate: nil,
            hasNewNotifications: false,
            hasData: false
        )
    }
}

// MARK: - Timeline Provider

struct RelationshipProvider: TimelineProvider {
    func placeholder(in context: Context) -> RelationshipEntry {
        .placeholder()
    }

    func getSnapshot(in context: Context, completion: @escaping (RelationshipEntry) -> Void) {
        completion(context.isPreview ? .placeholder() : Self.currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RelationshipEntry>) -> Void) {
        let entry = Self.currentEntry()
        // 主 App 写入后会 reloadAllTimelines；这里只做兜底。
        // 「今天还没打卡」是跨零点会变的量，因此下一次刷新对齐到次日 0:05。
        let nextMidnight = Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 5),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }

    static func currentEntry() -> RelationshipEntry {
        let groupID = "group.com.relationshipcopilot.app"
        guard let defaults = UserDefaults(suiteName: groupID),
              defaults.bool(forKey: "widgetHasData"),
              let name = defaults.string(forKey: "widgetProfileName"),
              !name.isEmpty else {
            return .empty()
        }

        let caseTimestamp = defaults.double(forKey: "widgetLastCaseAt")
        let analysisTimestamp = defaults.double(forKey: "widgetLastAnalysis")

        return RelationshipEntry(
            date: Date(),
            profileName: name,
            pendingPromiseCount: defaults.integer(forKey: "widgetPendingPromiseCount"),
            activeCaseCount: defaults.integer(forKey: "widgetActiveCaseCount"),
            lastCaseDate: caseTimestamp > 0 ? Date(timeIntervalSince1970: caseTimestamp) : nil,
            lastAnalysisDate: analysisTimestamp > 0 ? Date(timeIntervalSince1970: analysisTimestamp) : nil,
            hasNewNotifications: defaults.bool(forKey: "widgetHasNewNotifications"),
            hasData: true
        )
    }
}

// MARK: - 小尺寸

struct SmallWidgetView: View {
    let entry: RelationshipEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.caption2)
                Text("评理")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.indigo)

            Spacer(minLength: 0)

            // 主数字：进行中的评理。为 0 时不显示 0，改显示一句状态 ——
            // 0 是个让人困惑的数字（"没评理"既不是好消息也不是坏消息）。
            if entry.activeCaseCount > 0 {
                Text("\(entry.activeCaseCount)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.indigo)
                Text("件没说完")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if entry.pendingPromiseCount > 0 {
                Text("\(entry.pendingPromiseCount)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                Text("条承诺待打卡")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("都清空了")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - 中尺寸

struct MediumWidgetView: View {
    let entry: RelationshipEntry

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.indigo)
                    Text(entry.profileName)
                        .font(.headline)
                        .lineLimit(1)
                }

                if let lastCase = entry.lastCaseDate {
                    Text("上次说清一件事 \(lastCase, style: .relative)前")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("还没有一起看过一次")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                stat(value: entry.activeCaseCount, label: "没说完", tint: .indigo, show: entry.activeCaseCount > 0)
                stat(value: entry.pendingPromiseCount, label: "待打卡", tint: .orange, show: entry.pendingPromiseCount > 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func stat(value: Int, label: String, tint: Color, show: Bool) -> some View {
        if show {
            VStack(spacing: 0) {
                Text("\(value)")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 大尺寸

struct LargeWidgetView: View {
    let entry: RelationshipEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .foregroundStyle(.indigo)
                Text("与\(entry.profileName)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.hasNewNotifications {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(.red)
                }
            }

            Divider()

            row(
                icon: "square.and.pencil",
                title: "没说完的",
                value: entry.activeCaseCount > 0 ? "\(entry.activeCaseCount) 件" : "—",
                tint: .indigo
            )
            row(
                icon: "checklist",
                title: "今天待打卡",
                value: entry.pendingPromiseCount > 0 ? "\(entry.pendingPromiseCount) 条" : "都做完了",
                tint: .orange
            )
            row(
                icon: "clock.arrow.circlepath",
                title: "上次说清一件事",
                value: relativeText(entry.lastCaseDate),
                tint: .secondary
            )

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.caption2)
                Text("内容只存在这台手机上")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func row(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private func relativeText(_ date: Date?) -> String {
        guard let date else { return "还没有过" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// `RelativeDateTimeFormatter` 构造开销不小，而 Widget 每次刷新都要重建视图树，
    /// 放在 body 求值路径里等于每次刷新都新建一次。这里提到 static。
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        return formatter
    }()
}

// MARK: - Bundle

@main
struct RelationshipCopilotWidgetBundle: WidgetBundle {
    var body: some Widget {
        RelationshipCopilotWidget()
    }
}

struct RelationshipCopilotWidget: Widget {
    let kind: String = "RelationshipCopilotWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RelationshipProvider()) { entry in
            RelationshipCopilotWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("今天要说的那件事")
        .description("看看有没有还没说完的事，以及今天要兑现的承诺。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RelationshipCopilotWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: RelationshipEntry

    var body: some View {
        if entry.hasData {
            switch family {
            case .systemSmall:
                SmallWidgetView(entry: entry)
            case .systemMedium:
                MediumWidgetView(entry: entry)
            case .systemLarge:
                LargeWidgetView(entry: entry)
            default:
                MediumWidgetView(entry: entry)
            }
        } else {
            WidgetEmptyView(family: family)
        }
    }
}

/// 无数据时的引导态。
struct WidgetEmptyView: View {
    let family: WidgetFamily

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: family == .systemSmall ? 22 : 26))
                .foregroundStyle(.secondary)
            Text("添加一个人")
                .font(.caption.weight(.medium))
            if family != .systemSmall {
                Text("打开 App 添加人物后，这里会显示还没说完的事")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Previews

#Preview(as: .systemSmall) {
    RelationshipCopilotWidget()
} timeline: {
    RelationshipEntry.placeholder()
}

#Preview(as: .systemMedium) {
    RelationshipCopilotWidget()
} timeline: {
    RelationshipEntry(
        date: Date(),
        profileName: "小林",
        pendingPromiseCount: 1,
        activeCaseCount: 0,
        lastCaseDate: Date().addingTimeInterval(-86400),
        lastAnalysisDate: nil,
        hasNewNotifications: false
    )
}

#Preview(as: .systemLarge) {
    RelationshipCopilotWidget()
} timeline: {
    RelationshipEntry.placeholder()
}
