//
// RemoteHandoverView.swift
// 关系Copilot
//
// 远程模式下「等对方写」这一屏。
//
// ## 它与同机模式的 `handoverScreen` 不是同一个东西
//
// 同机模式那一屏的全部作用是**把屏幕清空、把手机递过去** ——
// 它刻意连"已收到"这样的动画都没有，因为任何停留都在延长上一份内容的暴露时间。
//
// 远程模式恰好相反：这一屏要停留很久（可能是几小时，对方不一定马上看到），
// 所以它必须承载状态、给出动作、回答"现在到哪一步了"。
// 复用一个视图会让两边都变差，所以分开写。
//
// ## 这一屏必须回答的三个问题
//
//   1. 链接在哪 → 一眼能看到，能复制、能直接分享到微信
//   2. 对方到哪一步了 → 打开了没 / 写完了没（这两件事对用户意义完全不同）
//   3. 现在能做什么 → 催一下 / 换个方式发 / 干脆改成同机模式
//
// 第三条是产品诚实的体现：链接可能永远没人点。不给退路的话，
// 用户会卡在这一屏，唯一的出路是删掉这件案卷重来。
//

import SwiftUI

struct RemoteHandoverView: View {
    let inviteURL: URL?
    let status: InviteStatus?
    let isRefreshing: Bool
    let errorMessage: String?
    /// 已经查过几次。用来把"TA 还没提交"这句软化掉 —— 见 `progressCard` 里的说明。
    let pollCount: Int
    let relationshipLabel: String?
    let onRefresh: () -> Void
    let onCopy: () -> Void
    let onSwitchToSameDevice: () -> Void
    let onCancel: () -> Void

    @State private var showFullURL = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: ThemeManager.Spacing.lg) {
                // 辅助功能字号下，标题与说明文字会占掉大半屏。
                //
                // 截图实测：XXXL 时「等 TA 在自己手机上写完」折成两行、
                // 下面那段说明折成五行，加起来把链接卡片整个推到了屏幕外 ——
                // 而链接是这一屏唯一需要交给对方的东西。
                // 所以大字号下只留标题（它已经说清在等什么），把说明压到链接之后。
                if dynamicTypeSize.isAccessibilitySize {
                    // 大字号下的顺序与常规字号不同，这是**故意的**。
                    //
                    // 截图实测：XXXL 时标题折两行 + 说明折五行，把链接卡片
                    // 整个挤出首屏；改成"标题 → 链接 → 说明"之后链接回来了，
                    // 但说明又被排到最下面、压在浮动 tab bar 底下。
                    //
                    // 所以这里把说明**放在链接之前**、并砍掉一半字数：
                    // 它解释的是"这东西怎么用"，而用户此刻要的是链接本身。
                    compactHeader
                    compactExplanation
                    refreshErrorCard
                    if let inviteURL {
                        linkCard(inviteURL)
                        progressCard
                    } else {
                        missingLinkCard
                    }
                } else {
                    header
                    // 错误条放在头部下方，而不是进度卡与按钮之间。
                    //
                    // 截图暴露的问题：早先它排在进度卡之后，
                    // 一旦出现（尤其配上「缺链接」那张卡），整屏内容变长，
                    // 错误条本身被挤到屏幕下沿截断，而它下面那行
                    // 「改成同一台手机」—— 唯一的退路 —— 直接落在屏幕外。
                    // 出错时用户最先要看到的就是错误，不是先滚一屏。
                    refreshErrorCard
                    if let inviteURL {
                        linkCard(inviteURL)
                        progressCard
                    } else {
                        missingLinkCard
                    }
                }
                actions
                fallback
            }
            .padding(.horizontal, ThemeManager.Spacing.md)
            .padding(.top, ThemeManager.Spacing.lg)
            // 底部要给浮动 tab bar 留量。这一屏内容比同机那屏长得多，
            // 不留的话最后一行会被压住 —— 而那正好是"退出"这类退路按钮。
            .padding(.bottom, ThemeManager.Spacing.xxl + ThemeManager.Spacing.lg)
        }
    }

    // MARK: 头部

    /// 常规字号：图 + 标题 + 说明，三段式。
    private var header: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "paperplane")
                .font(.system(.largeTitle, design: .rounded))
                .foregroundStyle(ThemeManager.Colors.primary)
                .accessibilityHidden(true)

            Text("等 TA 在自己手机上写完")
                .font(ThemeManager.Typography.title2)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .multilineTextAlignment(.center)

            explanation
        }
        .padding(.top, ThemeManager.Spacing.md)
    }

    /// 大字号：只保留标题。图标省掉（它不含信息）。
    private var compactHeader: some View {
        Text("等 TA 在自己手机上写完")
            .font(ThemeManager.Typography.title2)
            .foregroundStyle(ThemeManager.Colors.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, ThemeManager.Spacing.sm)
    }

    /// 大字号下的说明：只保留"要做什么"，砍掉安全说明。
    ///
    /// 砍掉的不是废话 —— 它仍然完整地出现在下面 `fallback` 的声明里。
    /// 大字号下屏幕能装的内容只有常规字号的三分之一左右，
    /// 这时候的取舍标准是"用户此刻必须知道什么才能往下走"。
    private var compactExplanation: some View {
        Text(inviteURL != nil
             ? "把链接发给 TA，TA 写的东西在提交前你看不到。"
             : "没能生成链接。你那份已存好。")
            .font(ThemeManager.Typography.footnote)
            .foregroundStyle(ThemeManager.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 说明文案。跟着"有没有链接"变 ——
    /// 链接生成失败时还在说「把下面的链接发给 TA」会让用户先找链接、找不到、
    /// 再怀疑自己漏点了什么。文案与实际状态矛盾，比没有文案更糟。
    private var explanation: some View {
        Text(inviteURL != nil
             ? "把下面的链接发给 TA。TA 写的内容在提交前不会显示在这里，也不会以明文经过服务器。"
             : "这次没能生成链接。你写的那一份已经存好了。")
            .font(ThemeManager.Typography.callout)
            .foregroundStyle(ThemeManager.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(4)
    }

    /// 底部那行小字。同样跟着"有没有链接"变。
    ///
    /// 缺链接时**整句都不显示**，而不是换一句。
    /// 截图里数过：那一屏已经把"你那份已经存好了"说过两遍
    /// （说明文案一次、缺链接卡片一次），再补第三遍不会多传递任何信息，
    /// 只会让这一屏读起来像在反复安抚。这时候还缺的信息是"我可以退出去"，
    /// 也就是下面那个按钮本身。
    private var footnote: String? {
        guard inviteURL != nil else { return nil }
        return "链接 7 天后失效。TA 写完后你可以在这里刷新看到。"
    }

    // MARK: 链接

    private func linkCard(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            HStack {
                Text("邀请链接")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                Spacer()
                // 链接带一次性密钥，长得没法看。默认只显示头尾，
                // 但用户可能需要核对"发给谁的那条"——所以给一个展开开关。
                Button(showFullURL ? "收起" : "完整显示") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showFullURL.toggle()
                    }
                }
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.primary)
            }

            Text(showFullURL ? url.absoluteString : abbreviated(url))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .lineLimit(showFullURL ? nil : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ThemeManager.Spacing.sm)
                .background(ThemeManager.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.sm, style: .continuous))

            // 大字号下两个按钮并排一定会被压成竖排文字（截图已实测）。
            // 改成上下堆叠：每个都拿到整行宽度，文字不会折。
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: ThemeManager.Spacing.sm))
                : AnyLayout(HStackLayout(spacing: ThemeManager.Spacing.sm))

            layout {
                Button(action: onCopy) {
                    Label("复制链接", systemImage: "doc.on.doc")
                        .font(ThemeManager.Typography.subheadline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                // 用 ShareLink 而不是自制 UIActivityViewController：
                // 它是系统分享面板，微信/短信/隔空投送都在里面，
                // 而且自带链接预览与"复制"以外的全部系统能力。
                ShareLink(
                    item: url,
                    subject: Text("想请你一起说清一件事"),
                    message: Text(InviteLink.shareMessage(relationshipLabel: relationshipLabel))
                ) {
                    Label("发给 TA", systemImage: "square.and.arrow.up")
                        .font(ThemeManager.Typography.subheadline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
    }

    /// 只显示域名 + 一小段 caseId。
    ///
    /// ## 这里修的是一个真实缺陷
    ///
    /// 早先写的是 `"\(host)/…/\(url.lastPathComponent.prefix(8))…"`。
    /// 对这条链接来说 `lastPathComponent` **永远是 "page"** ——
    /// 于是缩写在截图里渲染成 `invite.example.com/…/page…`，
    /// 完全看不出是哪一次邀请，用户拿它核对"发给谁的那条"时毫无用处。
    ///
    /// 现在取 caseId 的前几位：它是随机的，所以短前缀在用户自己的
    /// 几件案卷之间就足以区分，同时仍然远不足以还原整个 id。
    ///
    /// 密钥部分一律不显示 —— 那是这个方案里唯一真正需要保密的东西。
    private func abbreviated(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        // 路径形如 /[前缀/]v1/invite/{caseId}/page
        let components = url.path.split(separator: "/").map(String.init)
        guard let inviteIndex = components.firstIndex(of: "invite"),
              components.count > inviteIndex + 1 else {
            return "\(host)/…"
        }
        let caseId = components[inviteIndex + 1]
        return "\(host)/…/\(caseId.prefix(8))…"
    }

    // MARK: 进度

    /// 「TA 写完了」这一行的说明文字。
    ///
    /// 具体措辞与"为什么不能说『还没提交』"都在 `Core/WaitingCopy.swift` 里，
    /// 那里是能自动化验证的；这里只负责把状态传进去。
    private var counterpartWrittenDetail: String {
        WaitingCopy.counterpartDetail(
            hasWritten: status?.counterpartHasWritten == true,
            missCount: pollCount
        )
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("现在到哪一步了")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)

            // 「TA 打开了链接」这一行。
            //
            // 措辞规则在 `Core/WaitingCopy.swift`：`status == nil`（连不上服务端、
            // 或还没查过）时**不能**说「还没有打开」—— 那时我们不知道对方做了什么。
            stepRow(
                done: status?.counterpartOpenedLink == true,
                inProgress: WaitingCopy.openedLinkIsInProgress(opened: status?.counterpartOpenedLink),
                title: "TA 打开了链接",
                detail: WaitingCopy.openedLinkDetail(opened: status?.counterpartOpenedLink)
            )

            stepRow(
                done: status?.counterpartHasWritten == true,
                inProgress: status?.counterpartOpenedLink == true && status?.counterpartHasWritten != true,
                title: "TA 写完了",
                detail: counterpartWrittenDetail
            )

            Button(action: onRefresh) {
                HStack(spacing: ThemeManager.Spacing.xs) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRefreshing ? "正在查看…" : "刷新看看")
                }
                .font(ThemeManager.Typography.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
    }

    private func stepRow(done: Bool, inProgress: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: ThemeManager.Spacing.sm) {
            Image(systemName: done ? "checkmark.circle.fill" : (inProgress ? "circle.dotted" : "circle"))
                .foregroundStyle(
                    done ? ThemeManager.Colors.accent
                    : (inProgress ? ThemeManager.Colors.primary : ThemeManager.Colors.textSecondary)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                Text(detail)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(detail)")
    }

    // MARK: 异常

    /// 缺链接时的卡片。
    ///
    /// 分工：上面 `explanation` 只说"没生成链接、你的内容已存好"，
    /// 这里只负责"那怎么办"。早先两边都把两件事说全了，
    /// 截图里读起来是同一段话连说两遍。
    private var missingLinkCard: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Label("这个邀请没有生成成功", systemImage: "exclamationmark.triangle")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.danger)
            Text("用递手机的方式也能评完。点下面的按钮，TA 在那台手机上接着写。")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
    }

    /// 刷新失败时的提示。
    ///
    /// 只在**有链接**时显示。缺链接那一路已经有了 `missingLinkCard`，
    /// 里面把"你这份已存好、点下面改成同一台手机"说得更完整；
    /// 再叠一条红条不仅重复，实测截图里还会和卡片说同一件事的两句话，
    /// 而且红条那句「还没连上服务端」在这个场景下是**归因错误** ——
    /// 链接根本没生成，问题不在网络。
    @ViewBuilder
    private var refreshErrorCard: some View {
        if let errorMessage, inviteURL != nil {
            Text(errorMessage)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(ThemeManager.Spacing.sm)
                .background(ThemeManager.Colors.danger.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.sm, style: .continuous))
        }
    }

    // MARK: 退路

    private var actions: some View {
        VStack(spacing: ThemeManager.Spacing.sm) {
            Button(action: onSwitchToSameDevice) {
                Text("改成同一台手机")
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(ThemeManager.Colors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.top, ThemeManager.Spacing.sm)
    }

    private var fallback: some View {
        VStack(spacing: ThemeManager.Spacing.xs) {
            // 这句话必须跟着「有没有链接」走。
            // 截图实测过：缺链接那一屏（`remoteNoLink`）照样把
            // 「链接 7 天后失效」印在底部 —— 而那一屏根本没有链接，
            // 读起来像是界面把状态搞丢了，用户会反复下拉想找链接回来。
            if let footnote {
                Text(footnote)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onCancel) {
                Text("先不评了")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.top, ThemeManager.Spacing.md)
    }
}
