import XCTest
@testable import TGSPlayerKit

final class TGSPlayerStateTests: XCTestCase {
    func testStateMachineStopsAndClearsSourceForReuse() {
        var machine = TGSPlayerStateMachine()

        machine.setSource(.data(Data("{}".utf8), cacheKey: "sample"))
        machine.play()
        machine.prepareForReuse()

        XCTAssertNil(machine.source)
        XCTAssertEqual(machine.state, .idle)
    }

    func testChangingSourceAdvancesGeneration() {
        var machine = TGSPlayerStateMachine()
        let firstGeneration = machine.generation

        machine.setSource(.data(Data("{}".utf8), cacheKey: "sample"))

        XCTAssertGreaterThan(machine.generation, firstGeneration)
    }
}
