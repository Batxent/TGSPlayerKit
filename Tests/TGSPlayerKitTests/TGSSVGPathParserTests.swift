import CoreGraphics
import XCTest
@testable import TGSPlayerKit

final class TGSSVGPathParserTests: XCTestCase {
    func testParsesAbsoluteMoveLineAndClose() throws {
        let data = svgWithPath(d: "M 10 20 L 30 40 L 50 60 Z", viewBox: "0 0 100 100")
        let parsed = try TGSSVGPathParser.parse(data)
        XCTAssertEqual(parsed.viewBox, CGRect(x: 0, y: 0, width: 100, height: 100))

        let elements = collectElements(parsed.path)
        XCTAssertEqual(elements.count, 4)
        XCTAssertEqual(elements[0].type, .moveToPoint)
        XCTAssertEqual(elements[0].points[0], CGPoint(x: 10, y: 20))
        XCTAssertEqual(elements[1].type, .addLineToPoint)
        XCTAssertEqual(elements[1].points[0], CGPoint(x: 30, y: 40))
        XCTAssertEqual(elements[2].type, .addLineToPoint)
        XCTAssertEqual(elements[2].points[0], CGPoint(x: 50, y: 60))
        XCTAssertEqual(elements[3].type, .closeSubpath)
    }

    func testParsesRelativeCommandsAndImpliedLinetos() throws {
        let path = try TGSSVGPathParser.parsePathData("m 5 5 10 10 -5 0")
        let elements = collectElements(path)
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements[0].type, .moveToPoint)
        XCTAssertEqual(elements[0].points[0], CGPoint(x: 5, y: 5))
        XCTAssertEqual(elements[1].type, .addLineToPoint)
        XCTAssertEqual(elements[1].points[0], CGPoint(x: 15, y: 15))
        XCTAssertEqual(elements[2].type, .addLineToPoint)
        XCTAssertEqual(elements[2].points[0], CGPoint(x: 10, y: 15))
    }

    func testParsesCubicBezier() throws {
        let path = try TGSSVGPathParser.parsePathData("M 0 0 C 10 10 20 20 30 30")
        let elements = collectElements(path)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[1].type, .addCurveToPoint)
        XCTAssertEqual(elements[1].points[0], CGPoint(x: 10, y: 10))
        XCTAssertEqual(elements[1].points[1], CGPoint(x: 20, y: 20))
        XCTAssertEqual(elements[1].points[2], CGPoint(x: 30, y: 30))
    }

    func testParsesShorthandSmoothCubic() throws {
        let path = try TGSSVGPathParser.parsePathData("M 0 0 C 0 10 10 10 10 0 S 20 -10 20 0")
        let elements = collectElements(path)
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements[2].type, .addCurveToPoint)
        XCTAssertEqual(elements[2].points[0], CGPoint(x: 10, y: -10))
        XCTAssertEqual(elements[2].points[1], CGPoint(x: 20, y: -10))
        XCTAssertEqual(elements[2].points[2], CGPoint(x: 20, y: 0))
    }

    func testParsesQuadAndShorthand() throws {
        let path = try TGSSVGPathParser.parsePathData("M 0 0 Q 10 20 20 0 T 40 0")
        let elements = collectElements(path)
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements[1].type, .addQuadCurveToPoint)
        XCTAssertEqual(elements[1].points[0], CGPoint(x: 10, y: 20))
        XCTAssertEqual(elements[1].points[1], CGPoint(x: 20, y: 0))
        XCTAssertEqual(elements[2].type, .addQuadCurveToPoint)
        XCTAssertEqual(elements[2].points[0], CGPoint(x: 30, y: -20))
        XCTAssertEqual(elements[2].points[1], CGPoint(x: 40, y: 0))
    }

    func testParsesHorizontalAndVertical() throws {
        let path = try TGSSVGPathParser.parsePathData("M 5 5 H 25 V 30 h -10 v -5")
        let elements = collectElements(path)
        XCTAssertEqual(elements.count, 5)
        XCTAssertEqual(elements[1].points[0], CGPoint(x: 25, y: 5))
        XCTAssertEqual(elements[2].points[0], CGPoint(x: 25, y: 30))
        XCTAssertEqual(elements[3].points[0], CGPoint(x: 15, y: 30))
        XCTAssertEqual(elements[4].points[0], CGPoint(x: 15, y: 25))
    }

    func testFallsBackToBoundingBoxWhenViewBoxMissing() throws {
        let data = """
        <svg xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M 0 0 L 50 30 Z\"/></svg>
        """.data(using: .utf8)!
        let parsed = try TGSSVGPathParser.parse(data)
        XCTAssertEqual(parsed.viewBox, CGRect(x: 0, y: 0, width: 50, height: 30))
    }

    func testParsesArcExpandsToCubicSegments() throws {
        let path = try TGSSVGPathParser.parsePathData("M 0 50 A 50 50 0 0 1 100 50")
        let elements = collectElements(path)
        XCTAssertEqual(elements[0].type, .moveToPoint)
        XCTAssertGreaterThan(elements.count, 1)
        for element in elements.dropFirst() {
            XCTAssertEqual(element.type, .addCurveToPoint)
        }
        let last = elements.last!
        XCTAssertEqual(last.points[2].x, 100, accuracy: 0.001)
        XCTAssertEqual(last.points[2].y, 50, accuracy: 0.001)
    }

    func testThrowsOnMalformedXML() {
        let data = "<svg<".data(using: .utf8)!
        XCTAssertThrowsError(try TGSSVGPathParser.parse(data))
    }

    func testThrowsOnMissingPath() {
        let data = "<svg></svg>".data(using: .utf8)!
        XCTAssertThrowsError(try TGSSVGPathParser.parse(data)) { error in
            XCTAssertEqual(error as? TGSSVGPathParserError, .missingPath)
        }
    }

    private func svgWithPath(d: String, viewBox: String) -> Data {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(viewBox)\"><path d=\"\(d)\"/></svg>"
        return svg.data(using: .utf8)!
    }

    private struct PathElement {
        let type: CGPathElementType
        let points: [CGPoint]
    }

    private func collectElements(_ path: CGPath) -> [PathElement] {
        var elements: [PathElement] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let count: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                count = 1
            case .addQuadCurveToPoint:
                count = 2
            case .addCurveToPoint:
                count = 3
            case .closeSubpath:
                count = 0
            @unknown default:
                count = 0
            }
            var points: [CGPoint] = []
            for index in 0..<count {
                points.append(element.points[index])
            }
            elements.append(PathElement(type: element.type, points: points))
        }
        return elements
    }
}
