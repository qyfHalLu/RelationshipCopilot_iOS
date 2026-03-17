//
//  RelationshipCopilotWidget.swift
//  RelationshipCopilotWidget
//
//  小组件 - 显示关系健康度和快速操作
//

import WidgetKit
import SwiftUI
import SwiftData

// MARK: - Timeline Entry

struct RelationshipEntry: TimelineEntry {
    let date: Date
    let profileName: String
    let healthScore: Int
    let lastAnalysisDate: Date?
    let hasNewNotifications: Bool
}

// MARK: - Timeline Provider

struct RelationshipProvider: TimelineProvider {
    func placeholder(in context: Context) -> RelationshipEntry {
        RelationshipEntry(
            date: Date(),
            profileName: "伴侣",
            healthScore: 85,
            lastAnalysisDate: Date(),
            hasNewNotifications: false
        )
    }
    
    func getSnapshot(in context: Context, completion: @escaping (RelationshipEntry) -> Void) {
        let entry = RelationshipEntry(
            date: Date(),
            profileName: "伴侣",
            healthScore: 85,
            lastAnalysisDate: Date(),
            hasNewNotifications: true
        )
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<RelationshipEntry>) -> Void) {
        var entries: [RelationshipEntry] = []
        
        let currentDate = Date()
        
        // 加载小组件数据
        let defaults = UserDefaults(suiteName: "group.com.relationshipcopilot.app")
        let profileName = defaults?.string(forKey: "widgetProfileName") ?? "伴侣"
        let healthScore = defaults?.integer(forKey: "widgetHealthScore") ?? 75
        let lastAnalysisTimestamp = defaults?.double(forKey: "widgetLastAnalysis") ?? 0
        let lastAnalysisDate = lastAnalysisTimestamp > 0 ? Date(timeIntervalSince1970: lastAnalysisTimestamp) : nil
        let hasNewNotifications = defaults?.bool(forKey: "widgetHasNewNotifications") ?? false
        
        // 创建当前 entry
        let entry = RelationshipEntry(
            date: currentDate,
            profileName: profileName,
            healthScore: healthScore,
            lastAnalysisDate: lastAnalysisDate,
            hasNewNotifications: hasNewNotifications
        )
        entries.append(entry)
        
        // 每小时更新一次
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: currentDate)!
        let timeline = Timeline(entries: entries, policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget Views

struct SmallWidgetView: View {
    let entry: RelationshipEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                Text("关系健康")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            
            Spacer()
            
            Text("\(entry.healthScore)")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(scoreColor)
            
            Text("/ 100")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
    
    var scoreColor: Color {
        if entry.healthScore >= 85 {
            return .green
        } else if entry.healthScore >= 70 {
            return .orange
        } else {
            return .red
        }
    }
}

struct MediumWidgetView: View {
    let entry: RelationshipEntry
    
    var body: some View {
        HStack(spacing: 16) {
            // 健康度圆环
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                
                Circle()
                    .trim(from: 0, to: CGFloat(entry.healthScore) / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                
                VStack(spacing: 2) {
                    Text("\(entry.healthScore)")
                        .font(.title2.bold())
                    Text("健康分")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 80, height: 80)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.pink)
                    Text(entry.profileName)
                        .font(.headline)
                }
                
                if let lastDate = entry.lastAnalysisDate {
                    Text("上次分析: \(lastDate, style: .relative)前")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.caption)
                    Text("点击开始录音")
                        .font(.caption)
                }
                .foregroundStyle(.pink)
            }
            
            Spacer()
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
    
    var scoreColor: Color {
        if entry.healthScore >= 85 {
            return .green
        } else if entry.healthScore >= 70 {
            return .orange
        } else {
            return .red
        }
    }
}

struct LargeWidgetView: View {
    let entry: RelationshipEntry
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                Text("关系 Copilot")
                    .font(.headline)
                Spacer()
                if entry.hasNewNotifications {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(.red)
                }
            }
            
            // Health Score
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 12)
                    
                    Circle()
                        .trim(from: 0, to: CGFloat(entry.healthScore) / 100)
                        .stroke(
                            AngularGradient(
                                colors: [.pink, .purple, .pink],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(), value: entry.healthScore)
                    
                    VStack(spacing: 4) {
                        Text("\(entry.healthScore)")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                        Text("健康度")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 140, height: 140)
                
                Text("与\(entry.profileName)的关系")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Quick Actions
            HStack(spacing: 20) {
                WidgetButton(icon: "mic.fill", label: "录音") {
                    // Deep link action
                }
                
                WidgetButton(icon: "text.bubble.fill", label: "分析") {
                    // Deep link action
                }
                
                WidgetButton(icon: "list.bullet.clipboard", label: "承诺") {
                    // Deep link action
                }
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct WidgetButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.pink.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Widget Bundle

@main
struct RelationshipCopilotWidgetBundle: WidgetBundle {
    var body: some Widget {
        RelationshipCopilotWidget()
    }
}

// MARK: - Widget

struct RelationshipCopilotWidget: Widget {
    let kind: String = "RelationshipCopilotWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RelationshipProvider()) { entry in
            RelationshipCopilotWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("关系健康度")
        .description("随时查看您与重要人的关系健康状况")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RelationshipCopilotWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: RelationshipEntry
    
    var body: some View {
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
    }
}

// MARK: - Previews

#Preview(as: .systemSmall) {
    RelationshipCopilotWidget()
} timeline: {
    RelationshipEntry(
        date: Date(),
        profileName: "伴侣",
        healthScore: 85,
        lastAnalysisDate: Date(),
        hasNewNotifications: true
    )
}

#Preview(as: .systemMedium) {
    RelationshipCopilotWidget()
} timeline: {
    RelationshipEntry(
        date: Date(),
        profileName: "伴侣",
        healthScore: 72,
        lastAnalysisDate: Date().addingTimeInterval(-86400),
        hasNewNotifications: false
    )
}

#Preview(as: .systemLarge) {
    RelationshipCopilotWidget()
} timeline: {
    RelationshipEntry(
        date: Date(),
        profileName: "伴侣",
        healthScore: 92,
        lastAnalysisDate: Date().addingTimeInterval(-3600),
        hasNewNotifications: true
    )
}