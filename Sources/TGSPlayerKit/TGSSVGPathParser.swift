import CoreGraphics
import Foundation

public enum TGSSVGPathParserError: Error, Equatable {
    case invalidXML
    case missingPath
    case invalidPathData
}

public struct TGSSVGParsedPath: Equatable {
    public let path: CGPath
    public let viewBox: CGRect

    public init(path: CGPath, viewBox: CGRect) {
        self.path = path
        self.viewBox = viewBox
    }

    public static func == (lhs: TGSSVGParsedPath, rhs: TGSSVGParsedPath) -> Bool {
        lhs.viewBox == rhs.viewBox && lhs.path == rhs.path
    }
}

public enum TGSSVGPathParser {
    public static func parse(_ data: Data) throws -> TGSSVGParsedPath {
        let extractor = SVGExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        guard parser.parse(), extractor.error == nil else {
            throw TGSSVGPathParserError.invalidXML
        }

        let pathStrings = extractor.paths
        guard !pathStrings.isEmpty else {
            throw TGSSVGPathParserError.missingPath
        }

        let combined = CGMutablePath()
        for d in pathStrings {
            let parsed = try parsePathData(d)
            combined.addPath(parsed)
        }

        let viewBox = extractor.viewBox ?? combined.boundingBox
        return TGSSVGParsedPath(path: combined, viewBox: viewBox)
    }

    public static func parsePathData(_ string: String) throws -> CGPath {
        var scanner = SVGPathScanner(string: string)
        let path = CGMutablePath()

        var currentPoint = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadraticControl: CGPoint?
        var previousCommand: Character = " "

        while let command = scanner.scanCommand() {
            let isRelative = command.isLowercase
            let normalized = Character(command.uppercased())

            switch normalized {
            case "M":
                guard let p = scanner.scanPoint() else {
                    throw TGSSVGPathParserError.invalidPathData
                }
                let target = isRelative ? CGPoint(x: currentPoint.x + p.x, y: currentPoint.y + p.y) : p
                path.move(to: target)
                currentPoint = target
                subpathStart = target
                lastCubicControl = nil
                lastQuadraticControl = nil
                while let next = scanner.scanPoint() {
                    let lineTo = isRelative ? CGPoint(x: currentPoint.x + next.x, y: currentPoint.y + next.y) : next
                    path.addLine(to: lineTo)
                    currentPoint = lineTo
                }
            case "L":
                guard let p = scanner.scanPoint() else {
                    throw TGSSVGPathParserError.invalidPathData
                }
                var target = isRelative ? CGPoint(x: currentPoint.x + p.x, y: currentPoint.y + p.y) : p
                path.addLine(to: target)
                currentPoint = target
                while let next = scanner.scanPoint() {
                    target = isRelative ? CGPoint(x: currentPoint.x + next.x, y: currentPoint.y + next.y) : next
                    path.addLine(to: target)
                    currentPoint = target
                }
                lastCubicControl = nil
                lastQuadraticControl = nil
            case "H":
                guard let x = scanner.scanNumber() else {
                    throw TGSSVGPathParserError.invalidPathData
                }
                var nextX = isRelative ? currentPoint.x + CGFloat(x) : CGFloat(x)
                path.addLine(to: CGPoint(x: nextX, y: currentPoint.y))
                currentPoint.x = nextX
                while let n = scanner.scanNumber() {
                    nextX = isRelative ? currentPoint.x + CGFloat(n) : CGFloat(n)
                    path.addLine(to: CGPoint(x: nextX, y: currentPoint.y))
                    currentPoint.x = nextX
                }
                lastCubicControl = nil
                lastQuadraticControl = nil
            case "V":
                guard let y = scanner.scanNumber() else {
                    throw TGSSVGPathParserError.invalidPathData
                }
                var nextY = isRelative ? currentPoint.y + CGFloat(y) : CGFloat(y)
                path.addLine(to: CGPoint(x: currentPoint.x, y: nextY))
                currentPoint.y = nextY
                while let n = scanner.scanNumber() {
                    nextY = isRelative ? currentPoint.y + CGFloat(n) : CGFloat(n)
                    path.addLine(to: CGPoint(x: currentPoint.x, y: nextY))
                    currentPoint.y = nextY
                }
                lastCubicControl = nil
                lastQuadraticControl = nil
            case "C":
                guard let c1 = scanner.scanPoint(),
                      let c2 = scanner.scanPoint(),
                      let end = scanner.scanPoint() else {
                    throw TGSSVGPathParserError.invalidPathData
                }
                var control1 = isRelative ? CGPoint(x: currentPoint.x + c1.x, y: currentPoint.y + c1.y) : c1
                var control2 = isRelative ? CGPoint(x: currentPoint.x + c2.x, y: currentPoint.y + c2.y) : c2
                var endPoint = isRelative ? CGPoint(x: currentPoint.x + end.x, y: currentPoint.y + end.y) : end
                path.addCurve(to: endPoint, control1: control1, control2: control2)
                currentPoint = endPoint
                lastCubicControl = control2
                lastQuadraticControl = nil
                while let nextC1 = scanner.scanPoint(),
                      let nextC2 = scanner.scanPoint(),
                      let nextEnd = scanner.scanPoint() {
                    control1 = isRelative ? CGPoint(x: currentPoint.x + nextC1.x, y: currentPoint.y + nextC1.y) : nextC1
                    control2 = isRelative ? CGPoint(x: currentPoint.x + nextC2.x, y: currentPoint.y + nextC2.y) : nextC2
                    endPoint = isRelative ? CGPoint(x: currentPoint.x + nextEnd.x, y: currentPoint.y + nextEnd.y) : nextEnd
                    path.addCurve(to: endPoint, control1: control1, control2: control2)
                    currentPoint = endPoint
                    lastCubicControl = control2
                }
            case "S":
                let prev = Character(String(previousCommand).uppercased())
                guard let c2 = scanner.scanPoint(), let end = scanner.scanPoint() else {
                    throw TGSSVGPathParserError.invalidPathData
                }
                var reflected: CGPoint
                if prev == "C" || prev == "S", let last = lastCubicControl {
                    reflected = CGPoint(x: 2 * currentPoint.x - last.x, y: 2 * currentPoint.y - last.y)
                } else {
                    reflected = currentPoint
                }
                var control2 = isRelative ? CGPoint(x: currentPoint.x + c2.x, y: currentPoint.y + c2.y) : c2
                var endPoint = isRelative ? CGPoint(x: currentPoint.x + end.x, y: currentPoint.y + end.y) : end
                path.addCurve(to: endPoint, control1: reflected, control2: control2)
                currentPoint = endPoint
                lastCubicControl = control2
                lastQuadraticControl = nil
                while let nextC2 = scanner.scanPoint(), let nextEnd = scanner.scanPoint() {
                    if let last = lastCubicControl {
                        reflected = CGPoint(x: 2 * currentPoint.x - last.x, y: 2 * currentPoint.y - last.y)
                    } else {
                        reflected = currentPoint
                    }
                    control2 = isRelative ? CGPoint(x: currentPoint.x + nextC2.x, y: currentPoint.y + nextC2.y) : nextC2
                    endPoint = isRelative ? CGPoint(x: currentPoint.x + nextEnd.x, y: currentPoint.y + nextEnd.y) : nextEnd
                    path.addCurve(to: endPoint, control1: reflected, control2: control2)
                    currentPoint = endPoint
                    lastCubicControl = control2
                }
            case "Q":
                guard let c1 = scanner.scanPoint(), let end = scanner.scanPoint() else {
                    throw TGSSVGPathParserError.invalidPathData
                }
                var control = isRelative ? CGPoint(x: currentPoint.x + c1.x, y: currentPoint.y + c1.y) : c1
                var endPoint = isRelative ? CGPoint(x: currentPoint.x + end.x, y: currentPoint.y + end.y) : end
                path.addQuadCurve(to: endPoint, control: control)
                currentPoint = endPoint
                lastQuadraticControl = control
                lastCubicControl = nil
                while let nextC1 = scanner.scanPoint(), let nextEnd = scanner.scanPoint() {
                    control = isRelative ? CGPoint(x: currentPoint.x + nextC1.x, y: currentPoint.y + nextC1.y) : nextC1
                    endPoint = isRelative ? CGPoint(x: currentPoint.x + nextEnd.x, y: currentPoint.y + nextEnd.y) : nextEnd
                    path.addQuadCurve(to: endPoint, control: control)
                    currentPoint = endPoint
                    lastQuadraticControl = control
                }
            case "T":
                let prev = Character(String(previousCommand).uppercased())
                guard let end = scanner.scanPoint() else {
                    throw TGSSVGPathParserError.invalidPathData
                }
                var reflected: CGPoint
                if prev == "Q" || prev == "T", let last = lastQuadraticControl {
                    reflected = CGPoint(x: 2 * currentPoint.x - last.x, y: 2 * currentPoint.y - last.y)
                } else {
                    reflected = currentPoint
                }
                var endPoint = isRelative ? CGPoint(x: currentPoint.x + end.x, y: currentPoint.y + end.y) : end
                path.addQuadCurve(to: endPoint, control: reflected)
                currentPoint = endPoint
                lastQuadraticControl = reflected
                lastCubicControl = nil
                while let nextEnd = scanner.scanPoint() {
                    if let last = lastQuadraticControl {
                        reflected = CGPoint(x: 2 * currentPoint.x - last.x, y: 2 * currentPoint.y - last.y)
                    } else {
                        reflected = currentPoint
                    }
                    endPoint = isRelative ? CGPoint(x: currentPoint.x + nextEnd.x, y: currentPoint.y + nextEnd.y) : nextEnd
                    path.addQuadCurve(to: endPoint, control: reflected)
                    currentPoint = endPoint
                    lastQuadraticControl = reflected
                }
            case "A":
                guard let arc = scanner.scanArc() else {
                    throw TGSSVGPathParserError.invalidPathData
                }
                let endPoint = isRelative ? CGPoint(x: currentPoint.x + arc.end.x, y: currentPoint.y + arc.end.y) : arc.end
                appendArc(
                    to: path,
                    from: currentPoint,
                    to: endPoint,
                    rx: arc.rx,
                    ry: arc.ry,
                    xAxisRotationDegrees: arc.xAxisRotation,
                    largeArc: arc.largeArc,
                    sweep: arc.sweep
                )
                currentPoint = endPoint
                lastCubicControl = nil
                lastQuadraticControl = nil
                while let next = scanner.scanArc() {
                    let nextEnd = isRelative ? CGPoint(x: currentPoint.x + next.end.x, y: currentPoint.y + next.end.y) : next.end
                    appendArc(
                        to: path,
                        from: currentPoint,
                        to: nextEnd,
                        rx: next.rx,
                        ry: next.ry,
                        xAxisRotationDegrees: next.xAxisRotation,
                        largeArc: next.largeArc,
                        sweep: next.sweep
                    )
                    currentPoint = nextEnd
                }
            case "Z":
                path.closeSubpath()
                currentPoint = subpathStart
                lastCubicControl = nil
                lastQuadraticControl = nil
            default:
                throw TGSSVGPathParserError.invalidPathData
            }

            previousCommand = command
        }

        return path
    }

    private static func appendArc(
        to path: CGMutablePath,
        from start: CGPoint,
        to end: CGPoint,
        rx rxIn: CGFloat,
        ry ryIn: CGFloat,
        xAxisRotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if start == end {
            return
        }
        if rxIn == 0 || ryIn == 0 {
            path.addLine(to: end)
            return
        }

        var rx = abs(rxIn)
        var ry = abs(ryIn)
        let angle = xAxisRotationDegrees * .pi / 180
        let cosA = cos(angle)
        let sinA = sin(angle)

        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cosA * dx + sinA * dy
        let y1p = -sinA * dx + cosA * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        let rxSq = rx * rx
        let rySq = ry * ry
        let x1pSq = x1p * x1p
        let y1pSq = y1p * y1p

        var radicand = (rxSq * rySq - rxSq * y1pSq - rySq * x1pSq) / (rxSq * y1pSq + rySq * x1pSq)
        if radicand < 0 { radicand = 0 }
        var coef = sqrt(radicand)
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)

        let cx = cosA * cxp - sinA * cyp + (start.x + end.x) / 2
        let cy = sinA * cxp + cosA * cyp + (start.y + end.y) / 2

        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry

        let theta1 = vectorAngle(ux: 1, uy: 0, vx: ux, vy: uy)
        var deltaTheta = vectorAngle(ux: ux, uy: uy, vx: vx, vy: vy)
        if !sweep && deltaTheta > 0 {
            deltaTheta -= 2 * .pi
        } else if sweep && deltaTheta < 0 {
            deltaTheta += 2 * .pi
        }

        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let delta = deltaTheta / CGFloat(segments)
        let t = 8 / 3 * pow(sin(delta / 4), 2) / sin(delta / 2)

        var theta = theta1
        var startSeg = start
        for _ in 0..<segments {
            let theta2 = theta + delta
            let endSeg = arcPoint(cx: cx, cy: cy, rx: rx, ry: ry, sinA: sinA, cosA: cosA, angle: theta2)

            let dx1 = -rx * sin(theta) * cosA - ry * cos(theta) * sinA
            let dy1 = -rx * sin(theta) * sinA + ry * cos(theta) * cosA
            let dx2 = -rx * sin(theta2) * cosA - ry * cos(theta2) * sinA
            let dy2 = -rx * sin(theta2) * sinA + ry * cos(theta2) * cosA

            let control1 = CGPoint(x: startSeg.x + t * dx1, y: startSeg.y + t * dy1)
            let control2 = CGPoint(x: endSeg.x - t * dx2, y: endSeg.y - t * dy2)
            path.addCurve(to: endSeg, control1: control1, control2: control2)

            startSeg = endSeg
            theta = theta2
        }
    }

    private static func arcPoint(
        cx: CGFloat,
        cy: CGFloat,
        rx: CGFloat,
        ry: CGFloat,
        sinA: CGFloat,
        cosA: CGFloat,
        angle: CGFloat
    ) -> CGPoint {
        let x = cosA * rx * cos(angle) - sinA * ry * sin(angle) + cx
        let y = sinA * rx * cos(angle) + cosA * ry * sin(angle) + cy
        return CGPoint(x: x, y: y)
    }

    private static func vectorAngle(ux: CGFloat, uy: CGFloat, vx: CGFloat, vy: CGFloat) -> CGFloat {
        let dot = ux * vx + uy * vy
        let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
        var c = len == 0 ? 0 : dot / len
        if c < -1 { c = -1 }
        if c > 1 { c = 1 }
        let sign: CGFloat = (ux * vy - uy * vx) < 0 ? -1 : 1
        return sign * acos(c)
    }
}

private final class SVGExtractor: NSObject, XMLParserDelegate {
    var paths: [String] = []
    var viewBox: CGRect?
    var error: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "svg" {
            if let vb = attributeDict["viewBox"] {
                let nums = vb.split { $0 == " " || $0 == "," }.compactMap { Double($0) }
                if nums.count == 4 {
                    viewBox = CGRect(
                        x: CGFloat(nums[0]),
                        y: CGFloat(nums[1]),
                        width: CGFloat(nums[2]),
                        height: CGFloat(nums[3])
                    )
                }
            } else if let widthString = attributeDict["width"],
                      let heightString = attributeDict["height"],
                      let width = Double(widthString.trimmingNumeric),
                      let height = Double(heightString.trimmingNumeric) {
                viewBox = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            }
        } else if elementName == "path" {
            if let d = attributeDict["d"] {
                paths.append(d)
            }
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }
}

private extension String {
    var trimmingNumeric: String {
        var result = ""
        for ch in self {
            if ch.isNumber || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E" {
                result.append(ch)
            } else {
                break
            }
        }
        return result
    }
}

private struct SVGArc {
    let rx: CGFloat
    let ry: CGFloat
    let xAxisRotation: CGFloat
    let largeArc: Bool
    let sweep: Bool
    let end: CGPoint
}

private struct SVGPathScanner {
    private let chars: [Character]
    private var index: Int = 0

    init(string: String) {
        self.chars = Array(string)
    }

    mutating func scanCommand() -> Character? {
        skipWhitespace()
        while index < chars.count {
            let ch = chars[index]
            if ch.isLetter {
                index += 1
                return ch
            }
            return nil
        }
        return nil
    }

    mutating func scanPoint() -> CGPoint? {
        let savedIndex = index
        guard let x = scanNumber() else {
            return nil
        }
        guard let y = scanNumber() else {
            index = savedIndex
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    mutating func scanArc() -> SVGArc? {
        let savedIndex = index
        guard let rx = scanNumber(),
              let ry = scanNumber(),
              let rotation = scanNumber(),
              let largeArc = scanFlag(),
              let sweep = scanFlag(),
              let end = scanPoint() else {
            index = savedIndex
            return nil
        }
        return SVGArc(
            rx: CGFloat(rx),
            ry: CGFloat(ry),
            xAxisRotation: CGFloat(rotation),
            largeArc: largeArc,
            sweep: sweep,
            end: end
        )
    }

    mutating func scanNumber() -> Double? {
        skipSeparator()
        let start = index
        var hasDigit = false
        if index < chars.count, chars[index] == "+" || chars[index] == "-" {
            index += 1
        }
        while index < chars.count, chars[index].isNumber {
            hasDigit = true
            index += 1
        }
        if index < chars.count, chars[index] == "." {
            index += 1
            while index < chars.count, chars[index].isNumber {
                hasDigit = true
                index += 1
            }
        }
        if hasDigit, index < chars.count, chars[index] == "e" || chars[index] == "E" {
            index += 1
            if index < chars.count, chars[index] == "+" || chars[index] == "-" {
                index += 1
            }
            while index < chars.count, chars[index].isNumber {
                index += 1
            }
        }
        guard hasDigit else {
            index = start
            return nil
        }
        return Double(String(chars[start..<index]))
    }

    mutating func scanFlag() -> Bool? {
        skipSeparator()
        guard index < chars.count else {
            return nil
        }
        let ch = chars[index]
        if ch == "0" {
            index += 1
            return false
        }
        if ch == "1" {
            index += 1
            return true
        }
        return nil
    }

    mutating func skipWhitespace() {
        while index < chars.count, chars[index].isWhitespace {
            index += 1
        }
    }

    mutating func skipSeparator() {
        while index < chars.count, chars[index].isWhitespace || chars[index] == "," {
            index += 1
        }
    }

}
