import Foundation
import XCTest

@testable import MWDATDisplayLive

final class DisplayFeedTransportTests: XCTestCase {
  func testDoesNotRegisterOrSendUntilTransferStarts() async {
    let channel = MockDisplayFeedChannel()
    _ = DisplayFeedTransport(channel: channel, chunkSize: 4)

    XCTAssertEqual(channel.registrationCount, 0)
    XCTAssertTrue(channel.sentPayloads.isEmpty)
  }

  func testSendsMP4BytesInBoundedChunksAndMarksOnlyTheFinalChunk() async throws {
    let channel = MockDisplayFeedChannel()
    let transport = DisplayFeedTransport(channel: channel, chunkSize: 4)
    let video = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])

    let transfer = Task {
      try await transport.send(video)
    }

    let sentStart = await waitUntil { channel.sentPayloads.count == 1 }
    XCTAssertTrue(sentStart)
    channel.emit(event: readyAck())
    let sentAllChunks = await waitUntil { channel.sentPayloads.count == 4 }
    XCTAssertTrue(sentAllChunks)
    XCTAssertEqual(channel.unregisterCount, 0)
    channel.emit(event: readyAck(bytesReceived: 10))
    try await transfer.value

    XCTAssertEqual(channel.sentPayloads, [
      DwaDisplayWire.encodeStart(codecRawValue: 1),
      DwaDisplayWire.encodeChunk(
        offset: 0,
        data: Data([0, 1, 2, 3]),
        isLast: false,
        sequenceNumber: 0),
      DwaDisplayWire.encodeChunk(
        offset: 4,
        data: Data([4, 5, 6, 7]),
        isLast: false,
        sequenceNumber: 1),
      DwaDisplayWire.encodeChunk(
        offset: 8,
        data: Data([8, 9]),
        isLast: true,
        sequenceNumber: 2),
    ])
    XCTAssertEqual(channel.unregisterCount, 1)
  }

  func testWaitsForReadyAfterFourOutstandingRequestsAndHonorsBufferFull() async throws {
    let channel = MockDisplayFeedChannel()
    let transport = DisplayFeedTransport(channel: channel, chunkSize: 4)
    let video = Data(repeating: 0xAB, count: 24)

    let transfer = Task {
      try await transport.send(video)
    }

    let sentStart = await waitUntil { channel.sentPayloads.count == 1 }
    XCTAssertTrue(sentStart)
    channel.emit(event: readyAck())
    let filledWindow = await waitUntil { channel.sentPayloads.count == 5 }
    XCTAssertTrue(filledWindow)

    channel.emit(event: bufferFullAck(bytesReceived: 8))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(channel.sentPayloads.count, 5)

    channel.emit(event: readyAck(bytesReceived: 16))
    let sentFinalChunks = await waitUntil { channel.sentPayloads.count == 7 }
    XCTAssertTrue(sentFinalChunks)
    channel.emit(event: readyAck(bytesReceived: 24))
    try await transfer.value
    XCTAssertEqual(channel.sentPayloads.count, 7)
  }

  func testSurfacesErrorAfterFinalChunkAndStopsIncompleteStream() async {
    let channel = MockDisplayFeedChannel()
    let transport = DisplayFeedTransport(channel: channel, chunkSize: 4)

    let transfer = Task {
      try await transport.send(Data([0, 1, 2, 3]))
    }

    let sentStart = await waitUntil { channel.sentPayloads.count == 1 }
    XCTAssertTrue(sentStart)
    channel.emit(event: readyAck())
    let sentFinalChunk = await waitUntil { channel.sentPayloads.count == 2 }
    XCTAssertTrue(sentFinalChunk)
    channel.emit(event: errorAck(bytesReceived: 4, message: "decoder rejected MP4"))

    do {
      try await transfer.value
      XCTFail("Expected the final acknowledgement error to fail the transfer")
    } catch {
      XCTAssertEqual(
        error as? LiveDisplayFeedError,
        .displayRejected("decoder rejected MP4"))
    }

    XCTAssertEqual(channel.sentPayloads.last, DwaDisplayWire.encodeStop())
    XCTAssertEqual(channel.unregisterCount, 1)
  }

  func testStopSendsVideoStopWithoutStartingAStream() async {
    let channel = MockDisplayFeedChannel()
    let transport = DisplayFeedTransport(channel: channel, chunkSize: 4)

    await transport.stop()

    XCTAssertEqual(channel.sentPayloads, [DwaDisplayWire.encodeStop()])
    XCTAssertEqual(channel.registrationCount, 0)
  }
}

private final class MockDisplayFeedChannel: DisplayFeedChannel, @unchecked Sendable {
  private let lock = NSLock()
  private var eventHandler: (@Sendable (Data) -> Void)?
  private var payloadStorage: [Data] = []
  private var registrationCountStorage = 0
  private var unregisterCountStorage = 0

  var sentPayloads: [Data] {
    lock.withLock { payloadStorage }
  }

  var registrationCount: Int {
    lock.withLock { registrationCountStorage }
  }

  var unregisterCount: Int {
    lock.withLock { unregisterCountStorage }
  }

  func registerCallbacks(
    onResponse: (@Sendable (Data) -> Void)?,
    onEvent: (@Sendable (Data) -> Void)?,
    onError: (@Sendable (UInt16) -> Void)?,
    onClosed: (@Sendable () -> Void)?
  ) -> any DisplayFeedCallbackRegistration {
    lock.withLock {
      registrationCountStorage += 1
      eventHandler = onEvent
    }
    return MockRegistration { [weak self] in
      self?.lock.withLock {
        self?.unregisterCountStorage += 1
        self?.eventHandler = nil
      }
    }
  }

  func send(payload: Data, messageID: String) -> Bool {
    lock.withLock {
      payloadStorage.append(payload)
    }
    return true
  }

  func emit(event: Data) {
    let handler = lock.withLock { eventHandler }
    handler?(event)
  }
}

private final class MockRegistration: DisplayFeedCallbackRegistration, @unchecked Sendable {
  private let unregisterHandler: @Sendable () -> Void

  init(unregisterHandler: @escaping @Sendable () -> Void) {
    self.unregisterHandler = unregisterHandler
  }

  func unregister() {
    unregisterHandler()
  }
}

private func waitUntil(
  timeout: Duration = .seconds(1),
  condition: @escaping @Sendable () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if condition() {
      return true
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

private func readyAck(bytesReceived: UInt8 = 0) -> Data {
  displayEvent(ackStatus: 1, bytesReceived: bytesReceived)
}

private func bufferFullAck(bytesReceived: UInt8) -> Data {
  displayEvent(ackStatus: 2, bytesReceived: bytesReceived)
}

private func errorAck(bytesReceived: UInt8, message: String) -> Data {
  displayEvent(ackStatus: 3, bytesReceived: bytesReceived, message: message)
}

private func displayEvent(
  ackStatus: UInt8,
  bytesReceived: UInt8,
  message: String = ""
) -> Data {
  var ack = Data([
    0x08, ackStatus,
    0x10, bytesReceived,
  ])
  if !message.isEmpty {
    let messageData = Data(message.utf8)
    precondition(messageData.count < 128)
    ack.append(contentsOf: [0x1A, UInt8(messageData.count)])
    ack.append(messageData)
  }

  var displayPayload = Data([0x1A, UInt8(ack.count)])
  displayPayload.append(ack)
  var event = Data([
    0x10, 0x01,
    0x32, UInt8(displayPayload.count),
  ])
  event.append(displayPayload)
  return event
}
