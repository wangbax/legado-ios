import SwiftUI

struct SourceSwitchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SourceSwitchViewModel
    let sources: [BookSource]
    let onSwitched: @MainActor (BookSourceSwitchReport, BookSource) -> Void

    init(
        book: Book,
        sources: [BookSource],
        demoCandidates: [BookSourceCandidate] = [],
        service: BookSourceSwitchService = .init(),
        onSwitched: @escaping @MainActor (BookSourceSwitchReport, BookSource) -> Void
    ) {
        self.sources = sources
        self.onSwitched = onSwitched
        _model = StateObject(wrappedValue: SourceSwitchViewModel(book: book, service: service, candidates: demoCandidates))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                previewPanel
                    .frame(height: model.selectedCandidate == nil ? 112 : min(max(geometry.size.height * 0.44, 200), 340))
                Divider()
                candidatesContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                confirmationButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReadingTheme.canvas)
        .navigationTitle("为《\(model.bookName)》换源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { model.cancelSelection(); dismiss() }
                    .disabled(model.isSwitching)
            }
        }
        .task { await model.load(sources: sources) }
        .onDisappear { model.cancelSelection() }
        .interactiveDismissDisabled(model.isSwitching)
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedCandidate?.book.originName ?? "本章预览")
                        .font(.headline)
                    Text(model.currentChapterTitle.map { "当前阅读：\($0)" } ?? "按当前阅读进度匹配章节")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let preview = model.preview {
                    Text(preview.report.exactChapterMatch ? "章节已匹配" : "按进度定位")
                        .font(.caption)
                        .foregroundStyle(preview.report.exactChapterMatch ? Color.secondary : Color.orange)
                        .accessibilityIdentifier("sourceSwitch.preview.mapping")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private var previewContent: some View {
        if model.isPreviewLoading {
            ProgressView("正在获取本章正文…")
        } else if let preview = model.preview {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(preview.report.book.durChapterTitle ?? "章节正文")
                        .font(.headline)
                        .accessibilityIdentifier("sourceSwitch.preview.chapter")
                    Text(preview.report.verifiedContent?.content ?? "")
                        .font(.system(size: 16))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("sourceSwitch.preview.content")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .id(model.selectedCandidate?.id)
        } else if let message = model.errorMessage {
            VStack(spacing: 10) {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                Button("重试预览") {
                    if let candidate = model.selectedCandidate {
                        Task { await model.select(candidate, sources: sources) }
                    }
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        } else {
            Text("点选下方书源，先查看这一章的正文")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var candidatesContent: some View {
        if model.candidates.isEmpty && (model.state == .searching || model.state == .idle) {
            VStack(spacing: 14) {
                ProgressView()
                Text("正在从其他书源查找同名作品…").foregroundStyle(.secondary)
            }
        } else if model.state == .empty {
            ReadingUnavailableView(
                "没有可用换源",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text("仅显示书名一致的候选，并优先匹配作者。请确认其他书源已启用且支持搜索。")
            )
        } else {
            List {
                if model.state == .searching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("仍在查找其他书源，可直接选择已找到的结果")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.candidates) { candidate in candidateRow(candidate) }
            }
            .listStyle(.insetGrouped)
            .readingScrollContentBackgroundHidden()
            .background(ReadingTheme.canvas)
        }
    }

    private var confirmationButton: some View {
        Button {
            Task {
                if let available = await model.confirmSelection() {
                    onSwitched(available.report, available.source)
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: 10) {
                if model.isSwitching { ProgressView() }
                Text("使用此书源")
            }
            .frame(maxWidth: .infinity)
        }
        .readingProminentButtonStyle()
        .disabled(!model.canConfirm)
        .accessibilityIdentifier("sourceSwitch.confirm")
        .padding(16)
        .background(ReadingTheme.canvas)
    }

    private func candidateRow(_ candidate: BookSourceCandidate) -> some View {
        Button {
            Task { await model.select(candidate, sources: sources) }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "network")
                    .foregroundStyle(ReadingTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(ReadingTheme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.book.originName).font(.headline).foregroundStyle(.primary)
                    Text(candidate.book.author.isEmpty ? "作者信息缺失" : candidate.book.author)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if model.selectedCandidate?.id == candidate.id, model.isPreviewLoading {
                        Text("正在加载本章预览…").font(.caption).foregroundStyle(.secondary)
                    } else if let latest = candidate.book.latestChapterTitle, !latest.isEmpty {
                        Text(latest).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if model.selectedCandidate?.id == candidate.id, model.isPreviewLoading {
                    ProgressView()
                } else {
                    Image(systemName: model.selectedCandidate?.id == candidate.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(ReadingTheme.accent)
                }
            }
            .padding(.vertical, 5)
        }
        .disabled(model.isSwitching)
        .accessibilityHint("预览当前章节，确认后换源")
        .accessibilityIdentifier("sourceSwitch.candidate.\(candidate.book.origin)")
    }
}
