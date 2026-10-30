import SwiftUI
import ImageIO

struct EPUBIllustrationsView: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let chapter: BookChapter
    @State private var images: [EPUBIllustration] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                LazyVStack(spacing: 24) {
                    if isLoading {
                        ProgressView("正在读取插图…").padding()
                    } else if let errorMessage {
                        ReadingUnavailableView("无法读取插图", systemImage: "photo", description: Text(errorMessage))
                    } else if images.isEmpty {
                        ReadingUnavailableView("本章没有插图", systemImage: "photo", description: Text(chapter.title))
                    } else {
                        ForEach(images) { image in
                            VStack(spacing: 8) {
                                EPUBIllustrationImage(data: image.data)
                                Text("插图 \(image.id)\(image.caption.isEmpty ? "" : " · " + image.caption)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding()
            }
            .background(ReadingTheme.canvas)
            .navigationTitle("本章插图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: chapter.id) {
                isLoading = true
                errorMessage = nil
                do {
                    images = try await Task.detached { try LocalBookService().loadIllustrations(book: book, chapter: chapter) }.value
                } catch { errorMessage = error.localizedDescription }
                isLoading = false
            }
        }
    }
}

private struct EPUBIllustrationImage: View {
    let data: Data
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("书籍插图")
            } else {
                Text("图片无法显示").foregroundStyle(.secondary)
            }
        }
        .task {
            // Decode a bounded thumbnail off the main thread, even for huge source dimensions.
            image = await Task.detached {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2_048,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return Optional<UIImage>.none }
                return UIImage(cgImage: thumbnail)
            }.value
        }
    }
}
