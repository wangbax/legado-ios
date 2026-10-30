import SwiftUI

@MainActor
final class LocalBookDetailViewModel: ObservableObject {
    @Published private(set) var chapters: [BookChapter] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service = LocalBookService.live()

    func load(book: Book) async {
        guard chapters.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let report = try await Task.detached { [service] in try service.loadChapters(book: book) }.value
            chapters = report.chapters
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LocalBookDetailView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @Environment(\.dismiss) private var dismiss
    let book: Book
    @StateObject private var model = LocalBookDetailViewModel()
    @State private var showsTableOfContents = false
    @State private var showsRemoveConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 14) {
                    BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.customCoverUrl ?? book.coverUrl, width: 108, height: 154)
                    Text(book.name).font(.title2.bold())
                    if !book.author.isEmpty { Text(book.author).font(.subheadline).foregroundStyle(.secondary) }
                    HStack {
                        StatusPill(text: "本地 " + (URL(string: book.bookUrl)?.pathExtension.uppercased() ?? "TXT"), systemImage: "doc.text.fill")
                        if let charset = book.charset { StatusPill(text: charset, color: ReadingTheme.coral, systemImage: "character") }
                    }
                    Text(book.originName).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 12)

                if let intro = book.intro, !intro.isEmpty {
                    ReadingCard { Text(intro).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading) }
                }
                ReadingCard {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Label("目录", systemImage: "list.bullet.rectangle.portrait.fill").font(.headline)
                            Spacer()
                            Text("\(model.chapters.count) 章").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 12)
                        if model.isLoading {
                            HStack { Spacer(); ProgressView("正在识别章节…"); Spacer() }.padding(.vertical, 28)
                        } else if let error = model.errorMessage {
                            ReadingUnavailableView("无法读取本地书", systemImage: "doc.badge.ellipsis", description: Text(error))
                        } else {
                            ForEach(model.chapters.prefix(8)) { chapter in
                                Divider()
                                NavigationLink {
                                    ReaderView(book: book, chapters: model.chapters, initialIndex: chapter.index)
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(String(format: "%02d", chapter.index + 1))
                                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 28)
                                        Text(chapter.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 12)
                                }
                            }
                            if model.chapters.count > 8 {
                                Divider()
                                Button("查看全部目录", systemImage: "list.bullet") {
                                    showsTableOfContents = true
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 30)
        }
        .background(ReadingTheme.canvas)
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("全部目录", systemImage: "list.bullet") { showsTableOfContents = true }
                    Button("移出书架", systemImage: "trash", role: .destructive) { showsRemoveConfirmation = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await model.load(book: book) }
        .sheet(isPresented: $showsTableOfContents) {
            LocalBookTableOfContentsView(book: book, chapters: model.chapters)
        }
        .confirmationDialog("从书架移除《\(book.name)》？", isPresented: $showsRemoveConfirmation) {
            Button("移出书架", role: .destructive) {
                Task { await library.remove(bookURL: book.bookUrl); dismiss() }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

private struct LocalBookTableOfContentsView: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let chapters: [BookChapter]
    @State private var query = ""
    @State private var descending = false

    private var displayed: [BookChapter] {
        let filtered = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? chapters
            : chapters.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return descending ? Array(filtered.reversed()) : filtered
    }

    var body: some View {
        ReadingNavigationStack {
            List(displayed) { chapter in
                NavigationLink {
                    ReaderView(book: book, chapters: chapters, initialIndex: chapter.index)
                } label: {
                    HStack {
                        Text("\(chapter.index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                        Text(chapter.title).lineLimit(2)
                        Spacer()
                        if chapter.index == book.durChapterIndex {
                            Image(systemName: "location.fill").foregroundStyle(ReadingTheme.accent)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索目录")
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(descending ? "正序" : "倒序", systemImage: "arrow.up.arrow.down") { descending.toggle() }
                }
            }
        }
    }
}
