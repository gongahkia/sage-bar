import XCTest
@testable import SageBar

final class SparklineRendererTests: XCTestCase {
    func testRenderWithValidValuesReturnsNonEmptyPath() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let path = SparklineRenderer.render(values: [1.0, 3.0, 2.0, 5.0, 4.0], in: rect)
        XCTAssertFalse(path.isEmpty)
    }

    func testRenderWithSingleValueReturnsEmptyPath() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let path = SparklineRenderer.render(values: [42.0], in: rect)
        XCTAssertTrue(path.isEmpty) // guard requires count >= 2
    }

    func testRenderWithAllZeroValuesDoesNotCrash() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let path = SparklineRenderer.render(values: [0.0, 0.0, 0.0, 0.0], in: rect)
        XCTAssertFalse(path.isEmpty) // range == 0 uses norm = 0.5, still draws
    }

    func testRenderWithEmptyValuesReturnsEmptyPath() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let path = SparklineRenderer.render(values: [], in: rect)
        XCTAssertTrue(path.isEmpty)
    }

    func testRenderWithTwoValuesProducesPath() {
        let rect = CGRect(x: 0, y: 0, width: 50, height: 25)
        let path = SparklineRenderer.render(values: [0.0, 10.0], in: rect)
        XCTAssertFalse(path.isEmpty)
    }
}
