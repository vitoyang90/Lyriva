import SwiftUI

struct ReadingReviewSelection: Identifiable {
    let trackID: String
    let line: LyricsDocument.Line
    var id: String { "\(trackID):\(line.id)" }
}

struct ReadingReviewView: View {
    @ObservedObject var store: PhoneLyricsStore
    let selection: ReadingReviewSelection
    @Environment(\.dismiss) private var dismiss
    @State private var applying = false

    private var isCurrent: Bool {
        store.displayedTrackID == selection.trackID &&
        store.document?.lines.contains(where: { $0.id == selection.line.id && $0.words == selection.line.words }) == true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isCurrent {
                        Text(selection.line.words).font(.title3.bold())
                            .accessibilityIdentifier("reading-review-original")
                        Text("聽起來比較像哪一個？選擇後會更新這句羅馬字，也可以保留原文或還原系統讀音。")
                            .font(.subheadline).foregroundStyle(Studio.muted)
                        ForEach(store.readingIssues[selection.line.id] ?? []) { issue in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(issue.reason.rawValue).font(.caption).foregroundStyle(Studio.accent)
                                Text("\(issue.original) → \(issue.current)").font(.headline)
                                ForEach(issue.candidates) { candidate in
                                    choiceButton("\(issue.original) → \(candidate.reading)",
                                                 hint: candidate.hint, choice: "reading:" + candidate.id, issue: issue)
                                }
                                if issue.candidates.isEmpty {
                                    Text("目前沒有足夠可靠的候選讀法，請參考原文。")
                                        .font(.subheadline).foregroundStyle(Studio.muted)
                                }
                                choiceButton("保留原文：\(issue.original)", hint: nil,
                                             choice: issue.originalChoice, issue: issue)
                                choiceButton("使用系統讀音", hint: nil, choice: nil, issue: issue)
                            }
                            .padding(18)
                            .background(Studio.surface, in: RoundedRectangle(cornerRadius: 20))
                        }
                        if let error = store.readingChoiceError {
                            Text(error).font(.callout).foregroundStyle(Studio.accent)
                        }
                        Text("候選讀法依詞語整理，無法判定歌手的特殊唱法。你的選擇只套用到這首歌的這個位置，並保存在此裝置。")
                            .font(.footnote).foregroundStyle(Studio.muted)
                    } else {
                        Text("歌曲或歌詞已變更，請回到歌詞重新選擇。")
                    }
                }
                .padding(22).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .background(Studio.background.ignoresSafeArea())
            .navigationTitle("讀音檢查")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .foregroundStyle(Studio.ink).tint(Studio.accent).preferredColorScheme(.dark)
    }

    private func choiceButton(_ title: String, hint: String?, choice: String?, issue: ReadingIssue) -> some View {
        let selected = store.readingChoices[issue.id] == choice
        return Button {
            applying = true
            Task {
                await store.chooseReading(choice, issueID: issue.id, lineID: selection.line.id,
                                          trackID: selection.trackID, originalLine: selection.line.words)
                applying = false
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let hint { Text(hint).font(.caption).foregroundStyle(Studio.muted) }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Studio.accent : Studio.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(10).background(Studio.raised, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(applying || store.loading || !isCurrent)
        .accessibilityValue(selected ? "已選擇" : "未選擇")
    }
}
