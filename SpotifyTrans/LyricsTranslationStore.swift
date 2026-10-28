import Foundation
import NaturalLanguage
import Translation
import SwiftUI

struct LyricsTranslationInput: Hashable {
    struct Line: Hashable {
        let id: Int
        let text: String
    }
    let trackID: String
    let lines: [Line]
    let language: LyricsLanguage
    let sourceLanguage: String?

    init(trackID: String, document: LyricsDocument, language: LyricsLanguage, sourceLanguage: String? = nil) {
        self.trackID = trackID
        self.lines = document.lines.map { Line(id: $0.id, text: $0.words) }
        self.language = language
        self.sourceLanguage = sourceLanguage.flatMap { $0.isEmpty ? nil : $0 }
    }

    var textLines: [Line] {
        lines.filter { $0.text.unicodeScalars.contains(where: CharacterSet.letters.contains) }
    }
}

@MainActor
final class LyricsTranslationStore: ObservableObject {
    struct Result: Sendable {
        let id: String?
        let source: String
        let text: String
    }
    @Published private(set) var translations: [Int: String] = [:]
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    @Published private(set) var missingLanguages: [String] = []
    @Published private(set) var configuration: TranslationSession.Configuration?
    private var generation = UUID()
    private var completed = false
    private var enabled = false
    private var activeInput: LyricsTranslationInput?
    private var runningGeneration: UUID?
    private var lastConfiguration: TranslationSession.Configuration?
    private var plan: LyricsTranslationPlan?
    private var translatedParts: [LyricsTranslationPlan.Key: String] = [:]
    private var pending: [LyricsTranslationPlan.Group] = []
    private var failures: [String] = []
    private let availabilityCheck: ((String) async -> LanguageAvailability.Status)?
    private let availabilityRetryDelay: Duration

    init(availabilityCheck: ((String) async -> LanguageAvailability.Status)? = nil,
         availabilityRetryDelay: Duration = .milliseconds(350)) {
        self.availabilityCheck = availabilityCheck
        self.availabilityRetryDelay = availabilityRetryDelay
    }

    func configure(_ input: LyricsTranslationInput, enabled: Bool) async {
        let id = UUID()
        generation = id
        self.enabled = enabled
        configuration = nil
        runningGeneration = nil
        loading = false
        message = nil
        failures = []
        missingLanguages = []
        if activeInput != input {
            translations = [:]
            translatedParts = [:]
            completed = false
            activeInput = input
            plan = LyricsTranslationPlan(input)
        }
        guard enabled, !completed, let plan else { return }
        for request in plan.requests where request.sourceLanguage == "zh" {
            translatedParts[request.key] = request.text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? request.text
        }
        translations = plan.assembled(using: translatedParts)
        pending = plan.groups(excluding: Set(translatedParts.keys))
        guard !pending.isEmpty else { finish(); return }
        await prepareNextGroup(generation: id)
    }

    private func prepareNextGroup(generation id: UUID) async {
        guard generation == id else { return }
        guard !Task.isCancelled else { loading = false; return }
        guard !pending.isEmpty else { finish(); return }
        loading = true
        #if targetEnvironment(simulator)
        if availabilityCheck == nil {
            loading = false
            message = "本機翻譯需在 iPhone 或 iPad 上使用。"
            return
        }
        #endif
        let target = TranslationModels.target
        while let group = pending.first {
            guard let code = group.requests.first?.sourceLanguage else {
                failures.append("部分歌詞的語言無法確認或尚不支援翻譯。")
                pending.removeFirst()
                continue
            }
            do {
                guard let status = await confirmedAvailability(code, generation: id) else { return }
                if status != .installed {
                    if status == .supported {
                        if !missingLanguages.contains(code) { missingLanguages.append(code) }
                    } else {
                        failures.append("此裝置不支援\(TranslationModels.name(code))翻譯。")
                    }
                    pending.removeFirst()
                    continue
                }
            }
            activate(group, target: target)
            return
        }
        finish()
    }

    private func confirmedAvailability(_ code: String, generation id: UUID) async -> LanguageAvailability.Status? {
        let check = availabilityCheck ?? TranslationModels.status
        var status = await check(code)
        guard generation == id else { return nil }
        guard !Task.isCancelled else { loading = false; return nil }
        // A supported pair may not be ready yet. Confirm before showing a
        // download prompt, without treating old installed status as permanent.
        if status == .supported {
            do { try await Task.sleep(for: availabilityRetryDelay) }
            catch {
                if generation == id { loading = false }
                return nil
            }
            guard generation == id else { return nil }
            status = await check(code)
            guard generation == id else { return nil }
            guard !Task.isCancelled else { loading = false; return nil }
        }
        return status
    }

    private func activate(_ group: LyricsTranslationPlan.Group, target: Locale.Language = TranslationModels.target) {
        // Publish only after availability checks finish. Clearing configuration
        // while awaiting would cancel the translation task performing the check.
        var next = lastConfiguration ?? TranslationModels.configuration(source: group.source, target: target)
        next.source = group.source
        next.target = target
        next.invalidate()
        lastConfiguration = next
        configuration = next
    }

    func refreshMissingModels(_ input: LyricsTranslationInput) async {
        guard enabled, activeInput == input, !loading, configuration == nil,
              !missingLanguages.isEmpty, let plan else { return }
        let id = generation
        for code in missingLanguages {
            let status = await (availabilityCheck ?? TranslationModels.status)(code)
            guard generation == id, enabled, activeInput == input, !Task.isCancelled,
                  !loading, configuration == nil else { return }
            guard status == .installed else { continue }
            let groups = plan.groups(excluding: Set(translatedParts.keys)).filter {
                $0.requests.first?.sourceLanguage == code
            }
            guard let group = groups.first else { continue }
            pending = groups
            runningGeneration = nil
            loading = true
            message = nil
            missingLanguages.removeAll { $0 == code }
            // No suspension after publishing: the view's monitoring task may
            // cancel itself when missingLanguages/loading changes.
            activate(group)
            return
        }
    }

    func translate(_ input: LyricsTranslationInput, using session: TranslationSession,
                   configuration: TranslationSession.Configuration) async {
        guard self.configuration == configuration, enabled, activeInput == input,
              runningGeneration != generation, let group = pending.first else { return }
        let id = generation
        runningGeneration = id
        guard let source = group.source, let code = group.requests.first?.sourceLanguage,
              let status = await confirmedAvailability(code, generation: id) else { return }
        guard status == .installed else {
            runningGeneration = nil
            await prepareNextGroup(generation: id)
            return
        }
        guard generation == id, !Task.isCancelled else { return }
        await process(group, generation: id) { requests in
            let activeSession: TranslationSession
            if #available(iOS 26.0, *) {
                activeSession = TranslationModels.installedSession(source: source)
            } else {
                activeSession = session
            }
            let results = try await activeSession.translations(from: requests.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
            })
            return results.map { Result(id: $0.clientIdentifier, source: $0.sourceText, text: $0.targetText) }
        }
        guard generation == id, !Task.isCancelled else { return }
        runningGeneration = nil
        await prepareNextGroup(generation: id)
    }

    // Testable equivalent of the sequential per-language session workflow.
    func translate(_ input: LyricsTranslationInput,
                   perform: ([LyricsTranslationPlan.Request]) async throws -> [Result]) async {
        guard enabled, activeInput == input, !completed, runningGeneration != generation else { return }
        let id = generation
        runningGeneration = id
        loading = true
        message = nil
        while let group = pending.first {
            await process(group, generation: id, perform: perform)
            guard generation == id, !Task.isCancelled else { return }
            if availabilityCheck != nil {
                await prepareNextGroup(generation: id)
                guard generation == id, !Task.isCancelled else { return }
            }
        }
        runningGeneration = nil
        finish()
    }

    private func process(_ group: LyricsTranslationPlan.Group, generation id: UUID,
                         perform: ([LyricsTranslationPlan.Request]) async throws -> [Result]) async {
        do {
            let results = try await perform(group.requests)
            guard generation == id else { return }
            try Task.checkCancellation()
            let requests = Dictionary(uniqueKeysWithValues: group.requests.map { ($0.id, $0) })
            for result in results {
                guard let key = result.id, let original = requests[key], original.text == result.source,
                      !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                translatedParts[original.key] = result.text
            }
            translations = plan?.assembled(using: translatedParts) ?? [:]
        } catch {
            guard generation == id else { return }
            if Task.isCancelled {
                loading = false
                message = "翻譯已取消。"
                return
            }
            switch error {
            case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage,
                 TranslationError.unsupportedLanguagePairing:
                failures.append("部分語言暫不支援本機翻譯。")
            case TranslationError.unableToIdentifyLanguage:
                failures.append("部分歌詞無法辨識語言，請重試。")
            case is CancellationError:
                failures.append("翻譯已取消。")
            default:
                failures.append("翻譯未完成，請重試。")
            }
        }
        pending.removeFirst()
    }

    private func finish() {
        loading = false
        configuration = nil
        completed = plan.map { plan in plan.requests.allSatisfy { translatedParts[$0.key] != nil } } ?? false
        message = completed ? nil : (failures.first ?? "部分歌詞未完成翻譯，請重試。")
        if !missingLanguages.isEmpty {
            message = "需要下載\(missingLanguages.map(TranslationModels.name).joined(separator: "、"))翻譯模型"
        }
    }

    func cancel() {
        enabled = false
        generation = UUID()
        configuration = nil
        runningGeneration = nil
        loading = false
    }
}

// Identity is the song and its actual words, not its advancing playback position.
// A new song gets its own store and translation session; obsolete callbacks cannot
// change the next song's subtitles.
struct TranslatedLyricsContent<Content: View>: View {
    let input: LyricsTranslationInput
    let enabled: Bool
    @ViewBuilder let content: ([Int: String]) -> Content
    @StateObject private var store = LyricsTranslationStore()
    @State private var retry = 0
    @Environment(\.scenePhase) private var scenePhase

    private struct Request: Equatable {
        let enabled: Bool
        let retry: Int
    }

    private struct ModelRefreshRequest: Equatable {
        let active: Bool
        let loading: Bool
        let languages: [String]
    }

    var body: some View {
        let configuration = store.configuration
        return VStack(alignment: .leading, spacing: 12) {
            if enabled, store.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("翻譯中…").font(.caption).foregroundStyle(Studio.muted)
                }
            }
            if enabled, let message = store.message {
                HStack(alignment: .top, spacing: 12) {
                    Text(message).font(.caption).foregroundStyle(Studio.muted)
                    Spacer(minLength: 0)
                    if !store.missingLanguages.isEmpty {
                        NavigationLink("前往設定") { TranslationLanguagesView(preferredLanguages: store.missingLanguages) }
                            .font(.caption.weight(.medium))
                    } else {
                        Button("重試") { retry += 1 }.font(.caption.weight(.medium))
                    }
                }
            }
            content(enabled ? store.translations : [:])
        }
        .task(id: Request(enabled: enabled, retry: retry)) {
            await store.configure(input, enabled: enabled)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--translated-lyrics-ui-fixture"), input.trackID == "landscape-fixture-song" {
                await store.translate(input) { requests in
                    requests.map { .init(id: $0.id, source: $0.text, text: LandscapeUITestFixture.translation($0.text)) }
                }
            }
            #endif
        }
        .translationTask(configuration) { session in
            guard let configuration else { return }
            await store.translate(input, using: session, configuration: configuration)
        }
        .task(id: ModelRefreshRequest(active: enabled && scenePhase == .active,
                                     loading: store.loading, languages: store.missingLanguages)) {
            guard enabled, scenePhase == .active, !store.loading, !store.missingLanguages.isEmpty else { return }
            // Recover delayed system readiness while the player is visible.
            // Bound polling so genuinely missing models do not keep being queried.
            for seconds in [1, 2, 4, 8] {
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return }
                await store.refreshMissingModels(input)
                guard !Task.isCancelled else { return }
            }
        }
        .onDisappear { store.cancel() }
        .onAppear { retry += 1 }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { retry += 1 }
        }
    }
}
