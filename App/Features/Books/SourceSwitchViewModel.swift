import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class SourceSwitchViewModel: ObservableObject {
    enum State: Equatable { case idle, searching, ready, empty }

    @Published private(set) var state: State = .idle
    @Published private(set) var candidates: [BookSourceCandidate] = []
    @Published private(set) var selectedCandidate: BookSourceCandidate?
    @Published private(set) var preview: AvailableBookSource?
    @Published private(set) var isPreviewLoading = false
    @Published private(set) var isSwitching = false
    @Published private(set) var errorMessage: String?
    @Published var sourceQuery = ""

    private let book: Book
    private let service: BookSourceSwitchService
    private var selectionGeneration = 0
    private var preparationTask: Task<BookSourceSwitchReport?, Never>?
    private var previews: [String: AvailableBookSource] = [:]
    private var hasConfirmedSelection = false

    var bookName: String { book.name }
    var currentChapterTitle: String? { book.durChapterTitle }
    var filteredCandidates: [BookSourceCandidate] {
        let query = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.book.originName.localizedStandardContains(query) || $0.book.origin.localizedStandardContains(query)
        }
    }
    var canConfirm: Bool {
        preview != nil && !isPreviewLoading && !isSwitching && !hasConfirmedSelection
    }

    init(book: Book, service: BookSourceSwitchService = .init(), candidates: [BookSourceCandidate] = []) {
        self.book = book
        self.service = service
        self.candidates = candidates
        state = candidates.isEmpty ? .idle : .ready
    }

    func load(sources: [BookSource]) async {
        guard state == .idle else { return }
        state = .searching
        for await update in await service.candidateUpdates(for: book, sources: sources) {
            guard !Task.isCancelled else { state = candidates.isEmpty ? .idle : .ready; return }
            candidates = update
        }
        guard !Task.isCancelled else { state = candidates.isEmpty ? .idle : .ready; return }
        state = candidates.isEmpty ? .empty : .ready
    }

    func select(_ candidate: BookSourceCandidate, sources: [BookSource]) async {
        guard !isSwitching, !hasConfirmedSelection else { return }
        if selectedCandidate?.id == candidate.id, preview != nil || isPreviewLoading { return }
        preparationTask?.cancel()
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectedCandidate = candidate
        preview = nil
        errorMessage = nil
        isPreviewLoading = false
        guard let source = sources.first(where: { $0.bookSourceUrl == candidate.book.origin }) else {
            errorMessage = "该书源已不可用，请选择其他书源。"
            return
        }
        if let cached = previews[candidate.id] {
            preview = cached
            return
        }
        isPreviewLoading = true
        let task = Task {
            await service.prepareSwitch(current: book, candidate: candidate.book, source: source, persistChapters: false)
        }
        preparationTask = task
        let report = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == selectionGeneration else { return }
        preparationTask = nil
        isPreviewLoading = false
        guard !Task.isCancelled else { return }
        guard let report else {
            errorMessage = "无法读取这个书源的目录或本章正文，请重试或选择其他书源。"
            return
        }
        let available = AvailableBookSource(report: report, source: source)
        previews[candidate.id] = available
        preview = available
    }

    func confirmSelection() async -> AvailableBookSource? {
        guard canConfirm, let preview else { return nil }
        isSwitching = true
        let generation = selectionGeneration
        defer { isSwitching = false }
        let report = await service.persistPreparedSwitch(preview.report)
        guard generation == selectionGeneration, !Task.isCancelled else { return nil }
        hasConfirmedSelection = true
        return AvailableBookSource(report: report, source: preview.source)
    }

    func cancelSelection() {
        selectionGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        selectedCandidate = nil
        preview = nil
        errorMessage = nil
        isPreviewLoading = false
    }
}
