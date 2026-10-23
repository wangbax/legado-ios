import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct SourceSwitchPreviewTests {
    @Test func previewPreservesTheCurrentDirectoryUntilConfirmationAndReusesItsBody() async throws {
        let f = SourcePreviewFixture(sharedBookURL: true)
        await f.model.select(f.candidates[0], sources: f.sources)
        let preview = try #require(f.model.preview)
        #expect(preview.report.book.durChapterIndex == 1)
        #expect(preview.report.book.durChapterPos == 42)
        #expect(preview.report.exactChapterMatch)
        #expect(preview.report.verifiedContent?.content == "甲源本章正文")
        #expect(await f.repository.load(bookURL: f.book.bookUrl) == f.oldChapters)
        #expect(f.model.canConfirm)

        let confirmed = try #require(await f.model.confirmSelection())
        #expect(confirmed.source.id == "a")
        #expect(confirmed.report.verifiedContent?.content == preview.report.verifiedContent?.content)
        #expect(await f.loader.requestCount("a") == 1)
        #expect(await f.loader.requestedChapter("a") == "第二章·灯塔")
        #expect(await f.repository.load(bookURL: f.book.bookUrl) == confirmed.report.chapters)
        #expect(!f.model.canConfirm)
        #expect(await f.model.confirmSelection() == nil)
    }

    @Test func revisitingPreviewsUsesTheCacheAndExposesApproximateChapterMatching() async throws {
        let f = SourcePreviewFixture()
        await f.model.select(f.candidates[0], sources: f.sources)
        await f.model.select(f.candidates[1], sources: f.sources)
        #expect(f.model.preview?.report.exactChapterMatch == false)
        #expect(f.model.preview?.report.book.durChapterTitle == "第二节灯塔")
        #expect(f.model.preview?.report.book.durChapterPos == 0)
        await f.model.select(f.candidates[0], sources: f.sources)
        #expect(f.model.preview?.report.verifiedContent?.content == "甲源本章正文")
        #expect(await f.loader.requestCount("a") == 1)
        #expect(await f.loader.requestCount("b") == 1)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
        #expect(await f.repository.load(bookURL: "b-book").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func slowerOldSelectionCannotReplaceTheNewestPreview() async {
        let f = SourcePreviewFixture(suspended: ["a"])
        let first = Task { await f.model.select(f.candidates[0], sources: f.sources) }
        await f.loader.waitForRequest("a")
        await f.model.select(f.candidates[1], sources: f.sources)
        await f.loader.resume("a")
        await first.value
        #expect(f.model.selectedCandidate?.id == f.candidates[1].id)
        #expect(f.model.preview?.report.verifiedContent?.content == "乙源本章正文")
        #expect(f.model.errorMessage == nil)
        #expect(f.model.canConfirm)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationDiscardsAnUnfinishedPreview() async {
        let f = SourcePreviewFixture(suspended: ["a"])
        let pending = Task { await f.model.select(f.candidates[0], sources: f.sources) }
        await f.loader.waitForRequest("a")
        f.model.cancelSelection()
        await f.loader.resume("a")
        await pending.value
        #expect(f.model.preview == nil)
        #expect(f.model.selectedCandidate == nil)
        #expect(!f.model.isPreviewLoading)
        #expect(!f.model.canConfirm)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test func failedPreviewCanBeRetriedAndDoesNotPreventTryingAnotherSource() async {
        let f = SourcePreviewFixture(bodyA: " \n\t")
        await f.model.select(f.candidates[0], sources: f.sources)
        #expect(f.model.errorMessage != nil)
        #expect(!f.model.canConfirm)
        #expect(await f.model.confirmSelection() == nil)
        await f.loader.setBody("甲源恢复后的正文", source: "a")
        await f.model.select(f.candidates[0], sources: f.sources)
        #expect(f.model.preview?.report.verifiedContent?.content == "甲源恢复后的正文")
        #expect(f.model.errorMessage == nil)
        await f.model.select(f.candidates[1], sources: f.sources)
        #expect(f.model.preview?.report.verifiedContent?.content == "乙源本章正文")
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func loadingANewPreviewCannotConfirmThePreviouslySelectedSource() async {
        let f = SourcePreviewFixture(suspended: ["b"])
        await f.model.select(f.candidates[0], sources: f.sources)
        let pending = Task { await f.model.select(f.candidates[1], sources: f.sources) }
        await f.loader.waitForRequest("b")
        #expect(f.model.preview == nil)
        #expect(f.model.isPreviewLoading)
        #expect(!f.model.canConfirm)
        #expect(await f.model.confirmSelection() == nil)
        await f.loader.resume("b")
        await pending.value
        #expect(f.model.preview?.source.id == "b")
        #expect(f.model.canConfirm)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test func aRemovedSourceDoesNotLeaveThePreviousPreviewConfirmable() async {
        let f = SourcePreviewFixture()
        await f.model.select(f.candidates[0], sources: f.sources)
        await f.model.select(f.candidates[1], sources: [f.sources[0]])
        #expect(f.model.preview == nil)
        #expect(f.model.errorMessage != nil)
        #expect(!f.model.canConfirm)
    }
}

@MainActor
private struct SourcePreviewFixture {
    let book: Book
    let sources: [BookSource]
    let candidates: [BookSourceCandidate]
    let oldChapters: [BookChapter]
    let repository: InMemoryBookChapterRepository
    let loader: SourcePreviewContentLoader
    let model: SourceSwitchViewModel

    init(sharedBookURL: Bool = false, suspended: Set<String> = [], bodyA: String = "甲源本章正文") {
        var current = Book(bookUrl: "old-book", name: "书", origin: "old")
        current.durChapterIndex = 1
        current.durChapterTitle = "第二章 灯塔"
        current.durChapterPos = 42
        current.totalChapterNum = 3
        book = current
        sources = ["a", "b"].map { BookSource(bookSourceUrl: $0, bookSourceName: $0) }
        candidates = sources.map { source in
            .init(book: SearchBook(bookURL: sharedBookURL && source.id == "a" ? current.bookUrl : source.id + "-book",
                                   origin: source.id, originName: source.bookSourceName, type: 0, name: current.name), score: 100)
        }
        oldChapters = (0..<3).map { BookChapter(url: "old-\($0)", title: "旧章节\($0)", bookUrl: current.bookUrl, index: $0) }
        repository = InMemoryBookChapterRepository(values: [current.bookUrl: oldChapters])
        loader = SourcePreviewContentLoader(bodies: ["a": bodyA, "b": "乙源本章正文"], suspended: suspended)
        let directory = SourcePreviewDirectoryLoader()
        let service = BookSourceSwitchService(detailLoader: directory, chapterLoader: directory,
                                              contentLoader: loader, chapterRepository: repository)
        model = SourceSwitchViewModel(book: current, service: service, candidates: candidates)
    }
}

private struct SourcePreviewDirectoryLoader: BookDetailLoading, ChapterListLoading {
    func loadDetail(searchBook: SearchBook, source: BookSource) async -> BookDetailReport {
        .init(book: Book(bookUrl: searchBook.bookURL, name: searchBook.name, origin: source.id))
    }

    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport {
        let titles = ["第一章雨夜", source.id == "a" ? "第二章·灯塔" : "第二节灯塔", "第三章潮声"]
        return .init(chapters: titles.enumerated().map {
            BookChapter(url: source.id + "/\($0.offset)", title: $0.element, bookUrl: book.bookUrl, index: $0.offset)
        })
    }
}

private actor SourcePreviewContentLoader: ChapterContentLoading {
    private var bodies: [String: String]
    private var suspended: Set<String>
    private var requests: [(String, String)] = []
    private var pending: [String: CheckedContinuation<ChapterContentReport, Never>] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(bodies: [String: String], suspended: Set<String>) {
        self.bodies = bodies
        self.suspended = suspended
    }

    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        requests.append((source.id, chapter.title))
        return await withCheckedContinuation { continuation in
            if suspended.contains(source.id) { pending[source.id] = continuation }
            else { continuation.resume(returning: .init(content: bodies[source.id] ?? "")) }
            for waiter in waiters.removeValue(forKey: source.id) ?? [] { waiter.resume() }
        }
    }

    func waitForRequest(_ source: String) async {
        if requests.contains(where: { $0.0 == source }) { return }
        await withCheckedContinuation { waiters[source, default: []].append($0) }
    }

    func resume(_ source: String) {
        suspended.remove(source)
        pending.removeValue(forKey: source)?.resume(returning: .init(content: bodies[source] ?? ""))
    }

    func requestCount(_ source: String) -> Int { requests.filter { $0.0 == source }.count }
    func requestedChapter(_ source: String) -> String? { requests.first { $0.0 == source }?.1 }
    func setBody(_ body: String, source: String) { bodies[source] = body }
}
