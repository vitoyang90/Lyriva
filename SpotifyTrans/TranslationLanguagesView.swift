import SwiftUI
import Translation

enum TranslationModels {
    static let target = Locale.Language(identifier: "zh-Hant")
    static func name(_ code: String) -> String {
        switch code {
        case "ja": return "日文"
        case "en": return "英文"
        case "ko": return "韓文"
        default: return Locale(identifier: "zh-Hant").localizedString(forIdentifier: code) ?? code
        }
    }
    static func languageCodes(from languages: [Locale.Language]) -> [String] {
        Set(languages.filter { $0.languageCode?.identifier != "zh" }.map(\.minimalIdentifier))
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
    static func supportedCodes() async -> [String] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--landscape-ui-fixture") {
            if ProcessInfo.processInfo.arguments.contains("--translation-language-list-ui-fixture") {
                return languageCodes(from: ["ar", "bg", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "hr", "hu", "id", "it", "ja", "ko", "ms", "nb", "nl", "pl", "pt", "ro", "ru", "sk", "sv", "th", "tr", "uk", "vi"].map { Locale.Language(identifier: $0) })
            }
            return languageCodes(from: ["ja", "en", "ko", "fr", "de", "es"].map { Locale.Language(identifier: $0) })
        }
        #endif
        return languageCodes(from: await LanguageAvailability().supportedLanguages)
    }
    static func status(_ code: String) async -> LanguageAvailability.Status {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--translation-model-status-ui-fixture") {
            return code == "ja" || code == "en" ? .installed : (code == "fr" ? .supported : .unsupported)
        }
        #endif
        #if targetEnvironment(simulator)
        return .unsupported
        #else
        return await LanguageAvailability().status(from: Locale.Language(identifier: code), to: target)
        #endif
    }

    static func rank(_ status: LanguageAvailability.Status?) -> Int {
        switch status {
        case .installed: return 0
        case .supported: return 1
        case nil: return 2
        default: return 3
        }
    }

    static func orderedCodes(_ codes: [String], statuses: [String: LanguageAvailability.Status],
                             preferred: [String]) -> [String] {
        codes.sorted {
            let left = rank(statuses[$0]), right = rank(statuses[$1])
            if left != right { return left < right }
            let leftPreference = preferred.firstIndex(of: $0) ?? Int.max
            let rightPreference = preferred.firstIndex(of: $1) ?? Int.max
            if leftPreference != rightPreference { return leftPreference < rightPreference }
            return name($0).localizedStandardCompare(name($1)) == .orderedAscending
        }
    }

    static func sectionTitle(_ status: LanguageAvailability.Status?) -> String {
        switch status {
        case .installed: return "已下載"
        case .supported: return "未下載"
        case nil: return "檢查中"
        default: return "不支援"
        }
    }
}

struct TranslationLanguagesView: View {
    var preferredLanguages: [String] = []
    @AppStorage("lyricsTranslationSourceLanguage") private var sourceLanguage = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var languages: [String] = []
    @State private var loading = true
    @State private var search = ""
    @State private var statuses: [String: LanguageAvailability.Status] = [:]
    @State private var sourceChoices: SourceLanguageChoices?

    private struct SourceLanguageChoices: Identifiable {
        let id = UUID()
        let codes: [String]
    }

    private var orderedLanguages: [String] {
        TranslationModels.orderedCodes(languages, statuses: statuses, preferred: preferredLanguages)
    }

    private var displayedLanguages: [String] {
        orderedLanguages.filter { search.isEmpty || TranslationModels.name($0).localizedStandardContains(search)
            || $0.localizedStandardContains(search) }
    }

    private var selectableLanguages: [String] {
        Array(Set(languages + (sourceLanguage.isEmpty ? [] : [sourceLanguage]))).sorted {
            TranslationModels.name($0).localizedStandardCompare(TranslationModels.name($1)) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("翻譯範圍").font(.headline)
                    Button {
                        // Snapshot the choices for this presentation; model-status
                        // updates must not rebuild or reorder the open list.
                        sourceChoices = SourceLanguageChoices(codes: selectableLanguages)
                    } label: {
                        HStack {
                            Text(sourceLanguage.isEmpty ? "全部語言" : "只翻\(TranslationModels.name(sourceLanguage))")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Studio.accent)
                    .disabled(loading)
                    .tint(Studio.accent)
                    .accessibilityLabel("翻譯範圍")
                    .accessibilityValue(sourceLanguage.isEmpty ? "全部語言" : "只翻\(TranslationModels.name(sourceLanguage))")
                    .accessibilityIdentifier("translation-source-language")
                    Text("只翻指定語言時，其他語言保留原文；同一句混合語言也只翻譯符合的片段。")
                        .font(.caption).foregroundStyle(Studio.muted)
                }.padding(22).background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
                Text("選擇需要的語言，下載後即可在本機翻譯。")
                    .font(.subheadline).foregroundStyle(Studio.muted)
                if loading { ProgressView("檢查可用語言…") }
                if !loading, displayedLanguages.isEmpty {
                    Text(search.isEmpty ? "此裝置目前沒有可用的翻譯語言。" : "找不到符合的語言。")
                        .font(.subheadline).foregroundStyle(Studio.muted)
                }
                VStack(spacing: 0) {
                    ForEach(orderedLanguages, id: \.self) { code in
                        // Keep every card at the same ForEach identity when its
                        // status changes, so sorting/searching preserves downloads.
                        VStack(alignment: .leading, spacing: 12) {
                            if displayedLanguages.first(where: {
                                TranslationModels.rank(statuses[$0]) == TranslationModels.rank(statuses[code])
                            }) == code {
                                Text(TranslationModels.sectionTitle(statuses[code]))
                                    .font(.headline).foregroundStyle(Studio.muted)
                                    .accessibilityIdentifier("language-section-\(TranslationModels.rank(statuses[code]))")
                            }
                            TranslationLanguageCard(code: code, status: Binding(
                                get: { statuses[code] }, set: { statuses[code] = $0 }
                            ))
                                .accessibilityIdentifier("language-card-\(code)")
                        }
                            .padding(.bottom, 18)
                            .frame(height: displayedLanguages.contains(code) ? nil : 0)
                            .clipped()
                            .accessibilityHidden(!displayedLanguages.contains(code))
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("管理已下載語言", systemImage: "internaldrive").font(.headline)
                    Text("刪除語言請至 iPhone「設定 → App → 翻譯 → 已下載的語言」。需安裝 Apple「翻譯」App。")
                        .font(.subheadline).foregroundStyle(Studio.muted)
                    Text("語言模型由系統共用，刪除後也會影響其他 App 的本機翻譯。")
                        .font(.caption).foregroundStyle(Studio.muted)
                }.padding(22).background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
            }.padding(24)
        }
        .background(Studio.background).foregroundStyle(Studio.ink).tint(Studio.accent)
        .navigationTitle("翻譯語言").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜尋語言")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let codes = await TranslationModels.supportedCodes()
            guard !Task.isCancelled else { return }
            languages = codes
            loading = false
        }
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Studio.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $sourceChoices) { choices in
            TranslationSourceLanguageSheet(codes: choices.codes, selection: $sourceLanguage)
        }
    }
}

private struct TranslationSourceLanguageSheet: View {
    let codes: [String]
    @Binding var selection: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredCodes: [String] {
        codes.filter {
            search.isEmpty || TranslationModels.name($0).localizedStandardContains(search)
                || $0.localizedStandardContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                option("全部語言", code: "")
                ForEach(filteredCodes, id: \.self) { code in
                    option("只翻\(TranslationModels.name(code))", code: code)
                }
                if !search.isEmpty, filteredCodes.isEmpty {
                    Text("找不到符合的語言。")
                        .foregroundStyle(Studio.muted).listRowBackground(Studio.surface)
                }
            }
            .accessibilityIdentifier("translation-source-list")
            .scrollContentBackground(.hidden)
            .background(Studio.background)
            .searchable(text: $search, prompt: "搜尋語言名稱或代碼")
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .navigationTitle("翻譯範圍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .foregroundStyle(Studio.ink).tint(Studio.accent)
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private func option(_ title: String, code: String) -> some View {
        Button {
            selection = code
            dismiss()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selection == code {
                    Image(systemName: "checkmark").foregroundStyle(Studio.accent)
                }
            }.frame(minHeight: 32).contentShape(Rectangle())
        }
        .listRowBackground(Studio.surface)
        .accessibilityIdentifier("translation-source-option-\(code.isEmpty ? "all" : code)")
        .accessibilityAddTraits(selection == code ? [.isSelected] : [])
    }
}

private struct TranslationLanguageCard: View {
    let code: String
    @Environment(\.scenePhase) private var scenePhase
    @Binding var status: LanguageAvailability.Status?
    @State private var configuration: TranslationSession.Configuration?
    @State private var generation = UUID()
    @State private var downloading = false
    @State private var message: String?
    @State private var session: TranslationSession?

    var body: some View {
        let current = configuration
        let token = generation
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(TranslationModels.name(code)).font(.title3.bold())
                Image(systemName: "arrow.right").foregroundStyle(Studio.muted)
                Text("繁體中文").font(.subheadline)
                Spacer()
                if status == .installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Studio.accent) }
            }
            HStack {
                if downloading { ProgressView().controlSize(.small) }
                Text(message ?? statusText).font(.subheadline).foregroundStyle(Studio.muted)
            }
            if downloading {
                Button("取消") { cancel() }.buttonStyle(StudioButton())
            } else if status == .supported {
                Button(message == nil ? "下載" : "重試") {
                    generation = UUID()
                    message = nil
                    downloading = true
                    configuration = TranslationSession.Configuration(source: Locale.Language(identifier: code), target: TranslationModels.target)
                }.buttonStyle(StudioButton(prominent: true))
            }
        }
        .padding(22).background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
        .task(id: scenePhase) {
            if scenePhase == .active, !downloading {
                let refreshed = await TranslationModels.status(code)
                guard !Task.isCancelled, !downloading else { return }
                status = refreshed
                if refreshed != .supported { message = nil }
            }
        }
        .translationTask(current) { value in
            guard current != nil, downloading, generation == token else { return }
            session = value
            do {
                try await value.prepareTranslation()
                let refreshed = await TranslationModels.status(code)
                guard generation == token, !Task.isCancelled else { return }
                status = refreshed
                message = refreshed == .installed ? nil : "下載未完成，請重試。"
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                message = "下載未完成，請重試。"
            }
            downloading = false
            session = nil
            configuration = nil
        }
        .onDisappear { cancel() }
    }

    private var statusText: String {
        if downloading { return "準備下載…" }
        switch status {
        case .installed: return "已下載"
        case .supported: return "尚未下載"
        case .unsupported: return "此裝置不支援此語言"
        default: return "檢查中…"
        }
    }

    private func cancel() {
        guard downloading else { return }
        generation = UUID()
        if #available(iOS 26.0, *) { session?.cancel() }
        session = nil
        configuration = nil
        downloading = false
        message = "已取消下載要求"
    }
}
