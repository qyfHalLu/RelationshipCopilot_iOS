import SwiftUI
import UIKit

// MARK: - 快速工具视图
struct QuickToolsView: View {
    @State private var selectedTool: QuickTool?
    @State private var showToolSheet = false
    
    let tools: [QuickTool] = [
        QuickTool(id: "conflict", title: "吵架复盘", icon: "bubble.left.and.bubble.right.fill", color: .purple, description: "分析吵架原因，提供解决方案"),
        QuickTool(id: "phrase", title: "话术急救", icon: "bandage.fill", color: .blue, description: "提供高情商聊天话术"),
        QuickTool(id: "apology", title: "道歉生成", icon: "envelope.fill", color: .green, description: "生成真诚的道歉文案"),
        QuickTool(id: "checkup", title: "关系体检", icon: "heart.text.fill", color: .red, description: "评估关系健康状态")
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: ThemeManager.Spacing.md) {
                    ForEach(tools) { tool in
                        QuickToolCard(tool: tool) {
                            selectedTool = tool
                            showToolSheet = true
                        }
                    }
                }
                .padding(ThemeManager.Spacing.md)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("快速工具")
            .sheet(isPresented: $showToolSheet) {
                if let tool = selectedTool {
                    QuickToolDetailView(tool: tool)
                }
            }
        }
    }
}

// MARK: - 工具数据模型
struct QuickTool: Identifiable {
    let id: String
    let title: String
    let icon: String
    let color: Color
    let description: String
}

// MARK: - 工具卡片
struct QuickToolCard: View {
    let tool: QuickTool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                Image(systemName: tool.icon)
                    .font(.title)
                    .foregroundColor(tool.color)
                
                Text(tool.title)
                    .font(ThemeManager.Typography.headline)
                    .foregroundColor(ThemeManager.Colors.textPrimary)
                
                Text(tool.description)
                    .font(ThemeManager.Typography.caption)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ThemeManager.Spacing.md)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.lg))
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 工具详情视图
struct QuickToolDetailView: View {
    let tool: QuickTool
    @Environment(\.dismiss) private var dismiss
    @State private var userInput: String = ""
    @State private var aiResponse: String = ""
    @State private var isLoading = false
    @State private var hasGenerated = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {
                    // 工具标题
                    HStack {
                        Image(systemName: tool.icon)
                            .font(.title)
                            .foregroundColor(tool.color)
                        Text(tool.title)
                            .font(ThemeManager.Typography.title2)
                            .foregroundColor(ThemeManager.Colors.textPrimary)
                    }
                    
                    // 输入区域
                    VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                        Text(inputPrompt)
                            .font(ThemeManager.Typography.subheadline)
                            .foregroundColor(ThemeManager.Colors.textSecondary)
                        
                        TextEditor(text: $userInput)
                            .frame(minHeight: 120)
                            .padding(ThemeManager.Spacing.sm)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
                            .overlay(
                                RoundedRectangle(cornerRadius: ThemeManager.Radius.md)
                                    .stroke(ThemeManager.Colors.border, lineWidth: 1)
                            )
                    }
                    
                    // 生成按钮
                    Button(action: generateResponse) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                            Text(isLoading ? "生成中..." : "生成")
                        }
                        .font(ThemeManager.Typography.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            LinearGradient(
                                colors: [tool.color, tool.color.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
                    }
                    .disabled(userInput.isEmpty || isLoading)
                    .opacity(userInput.isEmpty ? 0.6 : 1)
                    
                    // AI回复
                    if hasGenerated {
                        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                            Text("AI回复")
                                .font(ThemeManager.Typography.subheadline)
                                .foregroundColor(ThemeManager.Colors.textSecondary)
                            
                            Text(aiResponse)
                                .font(ThemeManager.Typography.body)
                                .foregroundColor(ThemeManager.Colors.textPrimary)
                                .padding(ThemeManager.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
                                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
                            
                            // 复制按钮
                            Button(action: copyToClipboard) {
                                HStack {
                                    Image(systemName: "doc.on.doc")
                                    Text("复制")
                                }
                                .font(ThemeManager.Typography.subheadline)
                                .foregroundColor(tool.color)
                            }
                        }
                    }
                }
                .padding(ThemeManager.Spacing.md)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("快速工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
    
    private var inputPrompt: String {
        switch tool.id {
        case "conflict": return "请描述吵架的经过（什么时候，因为什么吵架，双方说了什么）"
        case "phrase": return "请描述当前面临的沟通场景（如：对方心情不好/想表白/要拒绝）"
        case "apology": return "请描述需要道歉的事情经过"
        case "checkup": return "请描述你们最近的相处情况（沟通频率、是否吵架等）"
        default: return "请输入内容"
        }
    }
    
    private func generateResponse() {
        isLoading = true
        hasGenerated = false
        
        // 模拟AI生成
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
            await MainActor.run {
                aiResponse = generateAIResponse()
                isLoading = false
                hasGenerated = true
            }
        }
    }
    
    private func generateAIResponse() -> String {
        switch tool.id {
        case "conflict":
            return """
            吵架分析报告：
            
            1. 冲突根源：从你的描述来看，主要分歧在于「\(userInput.prefix(20))...」
            
            2. 问题分析：
            - 沟通方式：双方可能都带有情绪，应该等冷静后再沟通
            - 表达方式：建议使用「我感受」而不是「你总是」
            
            3. 建议解决方案：
            - 步骤一：双方先冷静10分钟
            - 步骤二：轮流陈述事实，不评价对错
            - 步骤三：表达自己的感受和需求
            - 步骤四：共同寻找双赢方案
            
            4. 后续建议：约定以后遇到分歧时，先冷静再沟通。
            """
            
        case "phrase":
            return """
            建议话术：
            
            当对方心情不好时：
            - 「我注意到你今天不太开心，发生什么事了吗？我想听听」
            - 「不管发生什么，我都在你身边」
            
            想表白时：
            - 「最近和你在一起的时光都很开心，我想认真告诉你...」
            - 「我有很重要的话想对你说...」
            
            需要拒绝时：
            - 「我理解你的想法，但是...」
            - 「谢谢你的好意，不过...」
            """
            
        case "apology":
            return """
            道歉文案模板：
            
            亲爱的[名字]，
            
            我深刻反思了自己的行为，意识到这件事让你感到[具体感受]。
            
            发生这样的事，我很自责。让我明白了我在[某方面]做得不够好。
            
            我真心请求你的原谅。我保证以后会[具体承诺]。
            
            虽然现在可能很难立刻恢复，但我会用行动证明我的改变。
            
            爱你的人
            """
            
        case "checkup":
            return """
            关系健康评估报告：
            
            基于你的描述，我给出以下评估：
            
            ▸ 沟通质量：★★☆☆☆
            建议：每天至少30分钟深度交流
            
            ▸ 情感表达：★★★☆☆
            建议：多表达感恩和欣赏
            
            ▸ 冲突处理：★★☆☆☆
            建议：学习非暴力沟通技巧
            
            ▸ 亲密度：★★★☆☆
            建议：每周安排一次约会/共同活动
            
            综合评分：72/100
            建议：需要更多高质量的沟通
            """
            
        default:
            return "功能开发中..."
        }
    }
    
    private func copyToClipboard() {
        UIPasteboard.general.string = aiResponse
    }
}

#Preview {
    QuickToolsView()
}