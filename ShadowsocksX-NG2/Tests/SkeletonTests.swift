import XCTest
@testable import ShadowsocksX_NG2

final class SkeletonTests: XCTestCase {
    // 以下两个 Bundle.main 断言依赖测试包以 app 为 TEST_HOST 注入（target dependency）；
    // 若移除该依赖，Bundle.main 不再是 app bundle，断言会失效。

    func testMenuBarAppDoesNotTerminateAfterLastWindowClosed() {
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    func testAppBundleIDInheritedFromLegacy() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.qiuyuzhou.ShadowsocksX-NG")
    }

    func testAppIsMenuBarAgent() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }
}
