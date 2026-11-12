import XCTest
@testable import DonkNetworkUI

final class NetworkSelectionTests: XCTestCase {
    private let ids = (0..<5).map { _ in UUID() }

    func testToggleAddsAndRemoves() {
        var selection = NetworkSelection()
        selection.toggle(ids[0])
        selection.toggle(ids[1])
        XCTAssertEqual(selection.count, 2)
        selection.toggle(ids[0])
        XCTAssertFalse(selection.contains(ids[0]))
        XCTAssertTrue(selection.contains(ids[1]))
    }

    func testSelectAllCoversOnlyVisibleRows() {
        var selection = NetworkSelection([ids[4]])
        let visible = Array(ids[0..<3])
        selection.selectAll(visible)
        XCTAssertEqual(selection.ids, Set(visible))
        XCTAssertTrue(selection.covers(visible))
        XCTAssertFalse(selection.covers(ids))
        XCTAssertFalse(selection.covers([]))
    }

    func testCoversIsFalseForPartialSelection() {
        let selection = NetworkSelection([ids[0], ids[1]])
        XCTAssertFalse(selection.covers(Array(ids[0..<3])))
    }

    func testRetainDropsVanishedRows() {
        var selection = NetworkSelection([ids[0], ids[1], ids[2]])
        XCTAssertFalse(selection.retain(Set(ids)))
        XCTAssertTrue(selection.retain([ids[1], ids[3]]))
        XCTAssertEqual(selection.ids, [ids[1]])
        XCTAssertTrue(selection.retain([]))
        XCTAssertTrue(selection.isEmpty)
    }

    func testOrderedFollowsListOrder() {
        let selection = NetworkSelection([ids[3], ids[0], ids[2]])
        let visible = [ids[4], ids[3], ids[2], ids[1]]
        XCTAssertEqual(selection.ordered(visible), [ids[3], ids[2]])
        XCTAssertEqual(NetworkSelection().ordered(visible), [])
    }
}
