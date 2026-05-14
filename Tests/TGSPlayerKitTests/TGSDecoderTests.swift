import XCTest
@testable import TGSPlayerKit

final class TGSDecoderTests: XCTestCase {
    func testPlainJSONIsAcceptedForFixtureAndPreviewUse() throws {
        let data = #"{"v":"5.7.4","w":512,"h":512,"fr":60,"op":180}"#.data(using: .utf8)!
        let decoder = TGSDecoder()

        let json = try decoder.decode(data)

        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains(#""w":512"#))
    }

    func testOversizedCompressedPayloadIsRejectedBeforeDecode() {
        let decoder = TGSDecoder(limits: .init(maxCompressedBytes: 3, maxDecodedBytes: 128))

        XCTAssertThrowsError(try decoder.decode(Data(repeating: 0, count: 4))) { error in
            XCTAssertEqual(error as? TGSPlayerError, .sourceTooLarge)
        }
    }

    func testUnknownBinaryPayloadReturnsGzipDecodeFailure() {
        let decoder = TGSDecoder()

        XCTAssertThrowsError(try decoder.decode(Data([0x00, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? TGSPlayerError, .gzipDecodeFailed)
        }
    }
}
