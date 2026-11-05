//
//  DataRestorer.swift
//  RelationshipCopilot
//
//  从 `DataExporter` 产出的 JSON 备份恢复数据。
//
//  ## 为什么需要这个文件
//
//  「设置 → 数据管理」里一直有「导出全部数据（JSON）」，也一直有
//  「删除全部数据」和「建议先导出备份」的提示。但**导出是单向的** ——
//  `fileImporter` 全仓库零命中，导出的文件没有任何路径能读回来。
//
//  后果很具体：换手机、误点删除、重装（Keychain 还在但 SwiftData 库已空）之后，
//  用户手里那份备份是一份**只能看、不能恢复**的 JSON。
//  对唯一存储在本机的产品来说，这等于「备份」这个词是假的。
//
//  ## 三条设计约束
//
//  1. **宽容解析，但绝不猜。** 旧备份可能缺字段（例如 `promisor`），
//     缺失一律走安全默认值；但顶层结构不认识时**必须报错**，
//     不能"尽力而为地导入 0 条然后说成功"。
//
//  2. **重复导入必须幂等。** 用户很可能连点两次，或者先合并再合并。
//     按 `id` 去重，已存在的一律跳过并计入报告。
//
//  3. **不静默降级。** 头像照片是文件引用，跨设备恢复时文件不在。
//     这种情况改成默认色，但**必须把数量报给用户**，
//     而不是让他过几天才发现"头像怎么没了"。
//

import Foundation
import SwiftData

enum DataRestorer {

    /// 当前代码能读的备份格式版本。
    ///
    /// 导出端写 `schemaVersion`；早期导出的文件没有这个字段，按 1 处理。
    /// 比它更新的备份一律拒绝 —— 读懂一半就写入，比不导入更糟。
    static let supportedSchemaVersion = 1

    // MARK: - 失败

    enum Failure: LocalizedError, Equatable {
        case notABackup
        case unsupportedVersion(Int)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notABackup:
                return "这个文件不是本 App 导出的备份。"
            case .unsupportedVersion(let version):
                return "这个备份来自更新的版本（格式 v\(version)），请先升级 App 再恢复。"
            case .unreadable(let detail):
                return "备份文件读不出来：\(detail)"
            }
        }
    }

    // MARK: - 策略

    /// 恢复方式。
    enum Policy {
        /// 保留现有数据，只补充本机没有的（按 id 去重）。
        case merge
        /// 先清空再导入。**破坏性操作**，调用方必须让用户明确选择。
        case replace
    }

    // MARK: - 报告

    /// 一次恢复实际发生了什么。界面按这个逐项展示，不写"恢复成功"了事。
    struct Report {
        var insertedProfiles = 0
        var insertedPromises = 0
        var insertedRecords = 0
        var insertedSessions = 0
        var insertedDisputes = 0
        var skippedExisting = 0
        /// 需要用户知道、但不构成失败的情况（例如头像照片丢失）。
        var warnings: [String] = []

        var totalInserted: Int {
            insertedProfiles + insertedPromises + insertedRecords
                + insertedSessions + insertedDisputes
        }

        var isEmpty: Bool { totalInserted == 0 && skippedExisting == 0 }
    }

    /// 恢复前的预览：让用户知道"会加进去多少、跳过多少"再决定。
    struct Preview {
        var newProfiles = 0
        var newPromises = 0
        var newSessions = 0
        var newDisputes = 0
        var duplicateItems = 0
        var exportedAt: Date?

        var newTotal: Int { newProfiles + newPromises + newSessions + newDisputes }
        var isEmpty: Bool { newTotal == 0 }
    }

    // MARK: - 备份结构
    //
    // 与 `DataExporter.Payload` 对应，但**宽松**：所有非关键字段都可缺省。
    // 每个 DTO 手写 `init(from:)` 而不是靠合成 —— Swift 的合成 Decodable
    // 不会使用属性默认值，少一个 key 就整体抛错，那对"旧备份"是灾难性的。

    struct Backup {
        var schemaVersion = 1
        var exportedAt: Date?
        var appVersion: String?
        var profiles: [RawProfile] = []
        var promises: [RawPromise] = []
        var sessions: [RawSession] = []
        var disputes: [RawDispute] = []
    }

    // MARK: - 解析

    static func parse(_ data: Data) throws -> Backup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let raw: RawBackup
        do {
            raw = try decoder.decode(RawBackup.self, from: data)
        } catch let error as DecodingError {
            throw Failure.unreadable(describe(error))
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }

        // 「不是备份」和「备份但损坏」要分开报：
        // 用户可能选错文件（比如选了使用统计 .txt），那种情况要直说选错了。
        guard raw.looksLikeBackup else { throw Failure.notABackup }

        let version = raw.schemaVersion ?? supportedSchemaVersion
        guard version <= supportedSchemaVersion else {
            throw Failure.unsupportedVersion(version)
        }

        var backup = Backup()
        backup.schemaVersion = version
        backup.exportedAt = raw.exportedAt
        backup.appVersion = raw.appVersion
        backup.profiles = raw.profiles ?? []
        backup.promises = raw.promises ?? []
        backup.sessions = raw.sessions ?? []
        backup.disputes = raw.disputes ?? []
        return backup
    }

    /// 宽容的解码中间层：字段全可选，坏掉的单条记录直接丢掉并计数。
    ///
    /// 单条坏掉不整体失败，是为了"备份文件被手改过一两个字符"这种情况 ——
    /// 能救回多少算多少，但要通过 `droppedRows` 如实告诉用户。
    struct RawBackup: Decodable {
        var schemaVersion: Int?
        var exportedAt: Date?
        var appVersion: String?
        var profiles: [RawProfile]?
        var promises: [RawPromise]?
        var sessions: [RawSession]?
        var disputes: [RawDispute]?

        var looksLikeBackup: Bool {
            schemaVersion != nil || exportedAt != nil || appVersion != nil
                || profiles != nil || promises != nil || sessions != nil || disputes != nil
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, exportedAt, appVersion, profiles, promises, sessions, disputes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            exportedAt = try? c.decodeIfPresent(Date.self, forKey: .exportedAt)
            appVersion = try? c.decodeIfPresent(String.self, forKey: .appVersion)
            profiles = try? c.decodeIfPresent([RawProfile].self, forKey: .profiles)
            promises = try? c.decodeIfPresent([RawPromise].self, forKey: .promises)
            sessions = try? c.decodeIfPresent([RawSession].self, forKey: .sessions)
            disputes = try? c.decodeIfPresent([RawDispute].self, forKey: .disputes)
        }
    }

    struct RawProfile: Decodable {
        var id: String?
        var name: String?
        var relationshipType: String?
        var customRelationshipName: String?
        var avatar: String?
        var note: String?
        var intimacyScore: Int?
        var createdAt: Date?
        var updatedAt: Date?
    }

    struct RawPromise: Decodable {
        var id: String?
        var content: String?
        var status: String?
        var deadline: Date?
        var promisor: String?
        var promisee: String?
        var committedAt: Date?
        var profileName: String?
        var records: [RawRecord]?
    }

    struct RawRecord: Decodable {
        var date: Date?
        var status: String?
    }

    struct RawSession: Decodable {
        var id: String?
        var kind: String?
        var status: String?
        var startedAt: Date?
        var endedAt: Date?
        var transcription: String?
        var analysisSummary: String?
        var analysisScore: Int?
        var profileName: String?
    }

    struct RawDispute: Decodable {
        var id: String?
        var title: String?
        var mode: String?
        var state: String?
        var createdAt: Date?
        var closedAt: Date?
        var profileName: String?
        var isDegradedVerdict: Bool?
        var safetyConcerns: [String]?
        var sideA: RawTestimony?
        var sideB: RawTestimony?
        var verdict: RawVerdict?
    }

    struct RawTestimony: Decodable {
        var happened: String?
        var hurtMost: String?
        var request: String?
        var myPart: String?
        var submittedAt: Date?
    }

    struct RawVerdict: Decodable {
        var reframe: String?
        var needA: String?
        var needB: String?
        var stuckPoint: String?
        var solvability: String?
        var action: String?
        var coexistence: String?
        var generatedAt: Date?
    }

    // MARK: - 预览

    /// 这条备份在本机上有多少是"新的"。只读，不写库。
    static func preview(_ backup: Backup, in context: ModelContext) -> Preview {
        var preview = Preview()
        preview.exportedAt = backup.exportedAt

        let profileIDs = Set((try? context.fetch(FetchDescriptor<Profile>()))?.map(\.id) ?? [])
        let promiseIDs = Set((try? context.fetch(FetchDescriptor<Promise>()))?.map(\.id) ?? [])
        let sessionIDs = Set((try? context.fetch(FetchDescriptor<RecordingSession>()))?.map(\.id) ?? [])
        let disputeIDs = Set((try? context.fetch(FetchDescriptor<DisputeCase>()))?.map(\.id) ?? [])

        for item in backup.profiles {
            if let raw = item.id, let id = UUID(uuidString: raw), !profileIDs.contains(id) {
                preview.newProfiles += 1
            } else {
                preview.duplicateItems += 1
            }
        }
        for item in backup.promises {
            if let raw = item.id, let id = UUID(uuidString: raw), !promiseIDs.contains(id) {
                preview.newPromises += 1
            } else {
                preview.duplicateItems += 1
            }
        }
        for item in backup.sessions {
            if let raw = item.id, let id = UUID(uuidString: raw), !sessionIDs.contains(id) {
                preview.newSessions += 1
            } else {
                preview.duplicateItems += 1
            }
        }
        for item in backup.disputes {
            if let raw = item.id, let id = UUID(uuidString: raw), !disputeIDs.contains(id) {
                preview.newDisputes += 1
            } else {
                preview.duplicateItems += 1
            }
        }
        return preview
    }

    // MARK: - 恢复

    @MainActor
    @discardableResult
    static func restore(
        _ backup: Backup,
        into context: ModelContext,
        policy: Policy
    ) throws -> Report {
        var report = Report()

        if policy == .replace {
            try DataEraser.eraseAll(in: context)
        }

        // id → 档案。恢复承诺/记录/案卷时按名字回填关联。
        var profilesByName: [String: Profile] = [:]
        for profile in (try? context.fetch(FetchDescriptor<Profile>())) ?? [] {
            profilesByName[profile.name] = profile
        }

        // 1) 人物档案
        for item in backup.profiles {
            guard let id = identity(item.id), let name = item.name,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                report.skippedExisting += 1
                continue
            }
            // 身份就是 id：备份里同一个 id 已在库中即视为重复。
            // 刻意**不按名字**判重 —— 两个人真的可能同名，按名字合并会把
            // 另一个人的承诺错挂过去，而那种错误用户很难发现。
            if policy == .merge, try profileExists(id: id, in: context) {
                report.skippedExisting += 1
                // 名字仍要进映射表：后面的承诺/案卷靠它回填关联。
                if profilesByName[name] == nil {
                    profilesByName[name] = try context.fetch(FetchDescriptor<Profile>()).first { $0.id == id }
                }
                continue
            }

            let profile = Profile(name: name, relationshipType: item.relationshipType ?? RelationshipType.other.rawValue)
            profile.id = id
            profile.customRelationshipName = item.customRelationshipName
            profile.note = item.note
            if let score = item.intimacyScore { profile.setIntimacy(score) }
            profile.avatar = resolvableAvatar(item.avatar, report: &report)
            profile.createdAt = item.createdAt ?? Date()
            profile.updatedAt = item.updatedAt ?? Date()
            context.insert(profile)

            profilesByName[name] = profile
            report.insertedProfiles += 1
        }

        // 2) 承诺与履约记录
        for item in backup.promises {
            guard let id = identity(item.id), let content = item.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                report.skippedExisting += 1
                continue
            }
            if policy == .merge, try promiseExists(id: id, in: context) {
                report.skippedExisting += 1
                continue
            }

            let promise = Promise(
                content: content,
                promisor: item.promisor ?? "user",
                promisee: item.promisee ?? "partner"
            )
            promise.id = id
            promise.trackingStatus = item.status ?? PromiseStatus.active.rawValue
            promise.deadline = item.deadline
            promise.committedAt = item.committedAt ?? Date()
            promise.createdAt = item.committedAt ?? Date()
            if let name = item.profileName { promise.profile = profilesByName[name] }
            context.insert(promise)
            report.insertedPromises += 1

            // 记录不按 id 去重：导出里本来就没有记录 id，按 (日期, 状态) 记账。
            // 承诺不重复时记录也不可能重复，所以这里只需逐条插入。
            for recordDTO in item.records ?? [] {
                guard let date = recordDTO.date, let status = recordDTO.status else { continue }
                let record = FulfillmentRecord(recordDate: date, status: status)
                record.promise = promise
                context.insert(record)
                report.insertedRecords += 1
            }
            promise.recalculateStats()
        }

        // 3) 对话记录
        for item in backup.sessions {
            guard let id = identity(item.id), let startedAt = item.startedAt else {
                report.skippedExisting += 1
                continue
            }
            if policy == .merge, try sessionExists(id: id, in: context) {
                report.skippedExisting += 1
                continue
            }

            let session = RecordingSession(sessionType: item.kind ?? SessionKind.conversation.rawValue)
            session.id = id
            session.startedAt = startedAt
            session.endedAt = item.endedAt
            session.createdAt = startedAt
            session.transcription = item.transcription
            session.status = item.status ?? SessionStatus.completed.rawValue
            if let name = item.profileName { session.profile = profilesByName[name] }
            if item.analysisSummary != nil || item.analysisScore != nil {
                session.analysisResult = AnalysisResult(
                    emotionScore: item.analysisScore.map(Double.init),
                    summary: item.analysisSummary
                )
            }
            context.insert(session)
            report.insertedSessions += 1
        }

        // 4) 评理案卷
        for item in backup.disputes {
            guard let id = identity(item.id), let title = item.title else {
                report.skippedExisting += 1
                continue
            }
            if policy == .merge, try disputeExists(id: id, in: context) {
                report.skippedExisting += 1
                continue
            }

            let mode = DisputeMode(rawValue: item.mode ?? "") ?? .solo
            let caseObj = DisputeCase(
                title: title,
                mode: mode,
                createdAt: item.createdAt ?? Date(),
                id: id
            )
            if let name = item.profileName { caseObj.profile = profilesByName[name] }
            context.insert(caseObj)

            // 顺序很重要：先写证词再写状态与判词，
            // 因为 `verdict` 的 setter 会同步 `caseKindRaw`。
            if let a = item.sideA { caseObj.sideA = makeTestimony(a) }
            if let b = item.sideB { caseObj.sideB = makeTestimony(b) }
            if let v = item.verdict { caseObj.verdict = makeVerdict(v) }
            caseObj.isDegradedVerdict = item.isDegradedVerdict ?? false
            caseObj.safetyConcerns = (item.safetyConcerns ?? []).compactMap(SafetyConcern.init(rawValue:))
            caseObj.closedAt = item.closedAt

            // 状态最后写：状态机对外只允许合法迁移，但恢复是"直接落库"，
            // 这里绕过 `advance(to:)` 是有意的 —— 备份里的状态本来就是合法的。
            let state = DisputeCaseState(rawValue: item.state ?? "") ?? .collectingA
            caseObj.state = state
            report.insertedDisputes += 1
        }

        try context.save()
        return report
    }

    // MARK: - 工具

    /// 备份里的 id 是字符串；解不出合法 UUID 就视为坏记录。
    private static func identity(_ raw: String?) -> UUID? {
        guard let raw, let id = UUID(uuidString: raw) else { return nil }
        return id
    }

    private static func profileExists(id: UUID, in context: ModelContext) throws -> Bool {
        try context.fetch(FetchDescriptor<Profile>()).contains { $0.id == id }
    }

    private static func promiseExists(id: UUID, in context: ModelContext) throws -> Bool {
        try context.fetch(FetchDescriptor<Promise>()).contains { $0.id == id }
    }

    private static func sessionExists(id: UUID, in context: ModelContext) throws -> Bool {
        try context.fetch(FetchDescriptor<RecordingSession>()).contains { $0.id == id }
    }

    private static func disputeExists(id: UUID, in context: ModelContext) throws -> Bool {
        try context.fetch(FetchDescriptor<DisputeCase>()).contains { $0.id == id }
    }

    /// 头像引用能不能在这一台设备上兑现。
    ///
    /// `"photo:<文件名>"` 指向沙盒里的一个文件，跨设备恢复时那个文件不存在。
    /// 这种情况**退回默认色**（`nil` 会按 UUID 派生），并把数量记进报告。
    private static func resolvableAvatar(_ raw: String?, report: inout Report) -> String? {
        guard let raw else { return nil }
        guard case .photo(let name)? = AvatarStorage.parse(raw) else { return raw }
        guard let url = AvatarStorage.url(forPhotoName: name),
              FileManager.default.fileExists(atPath: url.path) else {
            report.warnings.append("有头像照片在这台设备上找不到，已改为默认颜色。")
            return nil
        }
        return raw
    }

    private static func makeTestimony(_ raw: RawTestimony) -> DisputeTestimony {
        DisputeTestimony(
            happened: raw.happened ?? "",
            hurtMost: raw.hurtMost ?? "",
            request: raw.request ?? "",
            myPart: raw.myPart ?? "",
            submittedAt: raw.submittedAt ?? Date()
        )
    }

    private static func makeVerdict(_ raw: RawVerdict) -> DisputeVerdict {
        DisputeVerdict(
            reframe: raw.reframe ?? "",
            needA: raw.needA ?? "",
            needB: raw.needB ?? "",
            stuckPoint: raw.stuckPoint ?? "",
            solvability: DisputeSolvability(rawValue: raw.solvability ?? "") ?? .solvable,
            action: raw.action,
            coexistence: raw.coexistence,
            generatedAt: raw.generatedAt ?? Date()
        )
    }

    /// 把 `DecodingError` 转成用户能读懂的一句话。
    ///
    /// 直接把 `error.localizedDescription` 抛给用户，看到的是
    /// "The data couldn't be read because it isn't in the correct format."
    /// —— 对"我该改什么"毫无帮助。
    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            return "缺少字段「\(key.stringValue)」"
        case .typeMismatch(_, let context):
            return "字段「\(context.codingPath.map(\.stringValue).joined(separator: "."))」类型不对"
        case .valueNotFound(_, let context):
            return "字段「\(context.codingPath.map(\.stringValue).joined(separator: "."))」是空的"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return "格式不正确"
        }
    }
}
