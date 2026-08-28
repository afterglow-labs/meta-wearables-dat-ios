import Foundation
import XCTest

@testable import MWDATDisplayLive

final class DwaDisplayWireTests: XCTestCase {
  func testEncodesMP4StreamStartRequest() {
    XCTAssertEqual(
      DwaDisplayWire.encodeStart(codecRawValue: 1),
      Data([0x2A, 0x02, 0x08, 0x01]))
  }

  func testEncodesVideoChunkRequest() {
    XCTAssertEqual(
      DwaDisplayWire.encodeChunk(
        offset: 300,
        data: Data([0xAA, 0xBB]),
        isLast: true,
        sequenceNumber: 7),
      Data([
        0x32, 0x0B,
        0x08, 0xAC, 0x02,
        0x12, 0x02, 0xAA, 0xBB,
        0x18, 0x01,
        0x20, 0x07,
      ]))
  }

  func testEncodesVideoStopRequest() {
    XCTAssertEqual(DwaDisplayWire.encodeStop(), Data([0x3A, 0x00]))
  }

  func testDecodesReadyAckFromDisplayEventEnvelope() {
    let event = Data([
      0x10, 0x01,
      0x32, 0x07,
      0x1A, 0x05,
      0x08, 0x01,
      0x10, 0xAC, 0x02,
    ])

    XCTAssertEqual(
      DwaDisplayWire.decodeAck(fromDwaEvent: event),
      DwaVideoStreamAck(status: .ready, bytesReceived: 300, errorMessage: ""))
  }

  func testDecodesBufferFullAckAndErrorMessage() {
    let message = Data("slow".utf8)
    let ack = Data([0x08, 0x02, 0x10, 0x20, 0x1A, UInt8(message.count)]) + message
    let displayEvent = Data([0x1A, UInt8(ack.count)]) + ack
    let event = Data([0x10, 0x01, 0x32, UInt8(displayEvent.count)]) + displayEvent

    XCTAssertEqual(
      DwaDisplayWire.decodeAck(fromDwaEvent: event),
      DwaVideoStreamAck(status: .bufferFull, bytesReceived: 32, errorMessage: "slow"))
  }

  func testRejectsNonDisplayAndMalformedEvents() {
    XCTAssertNil(DwaDisplayWire.decodeAck(fromDwaEvent: Data([0x10, 0x02])))
    XCTAssertNil(DwaDisplayWire.decodeAck(fromDwaEvent: Data([0x10, 0x01, 0x32, 0x08, 0x1A])))
  }
}
