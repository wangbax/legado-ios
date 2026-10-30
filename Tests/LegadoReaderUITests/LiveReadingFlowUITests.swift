import XCTest

@MainActor
final class LiveReadingFlowUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        // Xcode's runtime-issue callback can crash on Network.framework's log
        // quarantine with thousands of failing hosts. Keep server testing active.
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
    }

    func testSearchLatencyAndCachedQuery() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_SEARCH_UI_BENCHMARK"] == "1" else {
            throw XCTSkip("Use the LegadoSearchPerformanceUITests scheme with the imported catalog")
        }
        continueAfterFailure = false
        app.launchArguments = ["-uiDemoTab", "search", "-uiAutomationSearch", "极道天魔", "-themeMode", "1"]
        let started = Date()
        app.launch()
        let exact = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "极道天魔, 滚开")).firstMatch
        XCTAssertTrue(exact.waitForExistence(timeout: 90))
        print("[SearchPerformance] launch_to_exact_seconds=\(Date().timeIntervalSince(started))")
        attach("all-sources-search-latency")
        app.buttons["搜索选项"].tap()
        if app.buttons["停止搜索"].exists { app.buttons["停止搜索"].tap() }
        let search = app.searchFields["书名或作者"]
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "极道天")
        let repeated = Date()
        search.typeText("\n")
        XCTAssertTrue(app.staticTexts["“极道天”"].waitForExistence(timeout: 10))
        XCTAssertTrue(exact.exists)
        print("[SearchPerformance] cached_query_to_result_seconds=\(Date().timeIntervalSince(repeated))")
        attach("cached-search-result")
        exact.tap()
        XCTAssertTrue(app.navigationBars["书籍详情"].waitForExistence(timeout: 10))
        attach("detail-from-running-search")
    }

    func testImportSearchDetailReadSwitchAndResume() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_LIVE_UI_TESTS"] == "1" else {
            throw XCTSkip("Use the LegadoLiveReadingUITests scheme for real-server testing")
        }
        continueAfterFailure = false
        defer {
            if (testRun?.failureCount ?? 0) > 0 {
                attach("failure")
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "failure-accessibility-tree"
                tree.lifetime = .keepAlways
                add(tree)
            }
        }
        app.launchArguments = ["-uiDemoTab", "search", "-uiAutomationSearch", "极道天魔", "-pageAnim", "0", "-themeMode", "1"]
        app.launch()
        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 30))
        app.buttons["搜索选项"].tap()
        app.buttons["书源管理"].tap()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 10))
        app.buttons["更多"].firstMatch.tap()
        app.buttons["URL 或粘贴 JSON"].tap()
        let url = app.textFields["https://example.com/sources.json"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        url.tap()
        url.typeText("https://legado.aoaostar.com/sources/b778fe6b.json")
        app.navigationBars["导入书源"].buttons["导入"].tap()
        XCTAssertTrue(app.navigationBars["书源导入预检"].waitForExistence(timeout: 120))
        app.navigationBars["书源导入预检"].buttons["选择"].tap()
        app.buttons["全选"].tap()
        attach("01-import-preview")
        XCTAssertTrue(app.navigationBars["书源导入预检"].buttons["导入"].isEnabled)
        app.navigationBars["书源导入预检"].buttons["导入"].tap()
        XCTAssertTrue(app.alerts["书源导入完成"].waitForExistence(timeout: 90))
        attach("02-import-completed")
        app.alerts.buttons["好"].tap()
        app.navigationBars["书源"].buttons.element(boundBy: 0).tap()
        selectSearchSource("DragonQuestQBall")
        let search = app.searchFields["书名或作者"]
        search.tap()
        search.typeText("\n")
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "极道天魔, 滚开")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 90))
        attach("03-search")
        title.tap()
        XCTAssertTrue(app.navigationBars["书籍详情"].waitForExistence(timeout: 10))
        let start = app.buttons.matching(NSPredicate(format: "label IN %@", ["开始阅读", "继续阅读"])).firstMatch
        waitUntil("Readable directory", timeout: 90) { start.exists && start.isEnabled }
        XCTAssertTrue(app.staticTexts["滚开"].exists)
        attach("04-detail")
        if app.buttons["继续阅读"].exists {
            let firstChapter = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "道法无情")).firstMatch
            XCTAssertTrue(firstChapter.exists)
            firstChapter.tap()
        } else {
            start.tap()
        }
        waitForBody(containing: "道法无情")
        attach("05-reading")
        showReaderMenu()
        let currentSourceName = app.buttons["reader.changeSource"].value as? String
        let replacementID = currentSourceName == "💰QQ阅读[浏览器]" ? "DragonQuestQBall" : "https://bookshelf.html5.qq.com/"
        let replacementName = currentSourceName == "💰QQ阅读[浏览器]" ? "●QB男生<qq♛" : "💰QQ阅读[浏览器]"
        app.buttons["下一章"].tap()
        waitForBody(containing: "作弊器")
        attach("06-next-chapter")
        showReaderMenu()
        app.buttons["换源"].tap()
        XCTAssertTrue(app.navigationBars["为《极道天魔》换源"].waitForExistence(timeout: 10))
        let replacement = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "sourceSwitch.candidate." + replacementID + "|", "滚开"
        )).firstMatch
        XCTAssertTrue(replacement.waitForExistence(timeout: 240))
        attach("07-source-candidates")
        replacement.tap()
        waitUntil("Source switch sheet dismissed", timeout: 90) {
            !self.app.navigationBars["为《极道天魔》换源"].exists
        }
        waitForBody(containing: "作弊器")
        showReaderMenu()
        waitUntil("Replacement source active", timeout: 20) {
            self.app.buttons["reader.changeSource"].value as? String == replacementName
        }
        attach("08-switched-reading")
        app.buttons["返回"].tap()
        app.terminate()
        app.launchArguments = ["-pageAnim", "0", "-themeMode", "1"]
        app.launch()
        let resume = app.buttons["bookshelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 30))
        resume.tap()
        waitForBody(containing: "作弊器")
        showReaderMenu()
        XCTAssertEqual(app.buttons["reader.changeSource"].value as? String, replacementName)
        attach("09-resumed-reading")
    }

    private func selectSearchSource(_ sourceID: String) {
        app.buttons["搜索选项"].tap()
        if app.buttons["停止搜索"].exists {
            app.buttons["停止搜索"].tap()
            app.buttons["搜索选项"].tap()
        }
        app.buttons["分组或书源"].tap()
        app.segmentedControls.buttons["书源"].tap()
        let filter = app.searchFields["筛选书源"]
        filter.tap()
        filter.typeText(sourceID)
        let source = app.staticTexts[sourceID].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        app.buttons["确定"].tap()
    }

    private func waitForBody(containing chapter: String) {
        let body = app.textViews["reader.text"]
        waitUntil("Body of \(chapter)", timeout: 90) {
            guard body.exists, body.isHittable else { return false }
            let value = body.value as? String ?? ""
            return value.contains(chapter) && value.count > 500
        }
        let value = body.value as? String ?? ""
        XCTAssertGreaterThan(value.components(separatedBy: "\n").count, 5)
        XCTAssertFalse(value.contains("<p>"))
        XCTAssertFalse(value.contains(#"\r\n"#))
    }

    private func showReaderMenu() {
        if !app.buttons["换源"].exists {
            app.textViews["reader.text"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["换源"].waitForExistence(timeout: 10))
    }

    private func waitUntil(_ name: String, timeout: TimeInterval, condition: @escaping () -> Bool) {
        let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        ready.expectationDescription = name
        wait(for: [ready], timeout: timeout)
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
