// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LegadoIOS",
    platforms: [
        .iOS(.v15),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LegadoCore", targets: ["LegadoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.5"),
        .package(url: "https://github.com/tid-kijyun/Kanna.git", exact: "6.1.0")
    ],
    targets: [
        .target(
            name: "LegadoCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Kanna", package: "Kanna")
            ],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("CryptoKit"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "LegadoCoreTests",
            dependencies: ["LegadoCore"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "LegadoAppModels",
            dependencies: ["LegadoCore"],
            path: "App/Features",
            exclude: [
                "Activity", "Explore", "RSS", "TTS", "Settings",
                "Sources/SourceManagementView.swift", "Sources/SourceDebugView.swift", "Sources/SourceLoginView.swift", "Sources/SourceEditorView.swift", "Sources/OnlineBookSourcesView.swift",
                "Rules/ReplaceRuleManagementView.swift", "Rules/ReplaceRuleEditorView.swift", "Rules/RuleSubscriptionView.swift", "Rules/TxtTocRuleManagementView.swift", "Rules/Editor",
                "Books/BookDetailView.swift", "Books/LocalBookDetailView.swift", "Books/SourceSwitchView.swift",
                "Reader/ReaderAppearance.swift", "Reader/ReaderSpeechController.swift", "Reader/ReaderSupport.swift",
                "Reader/ReaderTextView.swift", "Reader/ReaderScrollView.swift", "Reader/ReaderView.swift"
            ],
            sources: [
                "Sources/SourceLibraryModel.swift", "Rules/ReplaceRuleLibraryModel.swift", "Search/SearchViewModel.swift",
                "Books/BookLibraryModel.swift", "Books/BookDetailViewModel.swift", "Books/SourceSwitchViewModel.swift", "Books/SourceChapterVerification.swift", "Books/SourceSwitchCache.swift",
                "Books/BookshelfReadViewModel.swift", "Reader/ReaderViewModel.swift"
            ]
        ),
        .testTarget(
            name: "LegadoAppModelsTests",
            dependencies: ["LegadoAppModels", "LegadoCore"]
        )
    ]
)
