import Foundation
import MWDATCore

protocol DisplayFeedCallbackRegistration: Sendable {
  func unregister()
}

protocol DisplayFeedChannel: Sendable {
  func registerCallbacks(
    onResponse: (@Sendable (Data) -> Void)?,
    onEvent: (@Sendable (Data) -> Void)?,
    onError: (@Sendable (UInt16) -> Void)?,
    onClosed: (@Sendable () -> Void)?
  ) -> any DisplayFeedCallbackRegistration

  func send(payload: Data, messageID: String) -> Bool
}

struct DwaDisplayFeedChannel: DisplayFeedChannel {
  let channel: DwaCapabilityChannel

  func registerCallbacks(
    onResponse: (@Sendable (Data) -> Void)?,
    onEvent: (@Sendable (Data) -> Void)?,
    onError: (@Sendable (UInt16) -> Void)?,
    onClosed: (@Sendable () -> Void)?
  ) -> any DisplayFeedCallbackRegistration {
    DwaDisplayFeedCallbackRegistration(registration: channel.registerCallbacks(
      onResponse: onResponse,
      onEvent: onEvent,
      onError: onError,
      onClosed: onClosed))
  }

  func send(payload: Data, messageID: String) -> Bool {
    channel.sendCapabilityPayloadRequest(.display, payload: payload, messageID: messageID)
  }
}

private final class DwaDisplayFeedCallbackRegistration:
  DisplayFeedCallbackRegistration,
  @unchecked Sendable
{
  private let registration: any DwaCallbackRegistration

  init(registration: any DwaCallbackRegistration) {
    self.registration = registration
  }

  func unregister() {
    registration.unregister()
  }
}

actor DisplayFeedTransport {
  private enum Event: Sendable {
    case ack(DwaVideoStreamAck)
    case error(UInt16)
    case closed
  }

  private let channel: any DisplayFeedChannel
  private let chunkSize: Int
  private let maximumOutstandingRequests: Int
  private let handshakeTimeout: Duration
  private let flowControlTimeout: Duration

  private var registration: (any DisplayFeedCallbackRegistration)?
  private var activeGeneration: UUID?
  private var queuedEvents: [Event] = []
  private var eventWaiter: CheckedContinuation<Event, Error>?
  private var eventWaiterID: UUID?
  private var timeoutTask: Task<Void, Never>?

  init(
    channel: any DisplayFeedChannel,
    chunkSize: Int,
    maximumOutstandingRequests: Int = 4,
    handshakeTimeout: Duration = .seconds(10),
    flowControlTimeout: Duration = .seconds(30)
  ) {
    precondition((1...15_000).contains(chunkSize))
    precondition(maximumOutstandingRequests > 0)
    self.channel = channel
    self.chunkSize = chunkSize
    self.maximumOutstandingRequests = maximumOutstandingRequests
    self.handshakeTimeout = handshakeTimeout
    self.flowControlTimeout = flowControlTimeout
  }

  func send(_ video: Data) async throws {
    guard !video.isEmpty else {
      throw LiveDisplayFeedError.emptyVideo
    }
    guard activeGeneration == nil else {
      throw LiveDisplayFeedError.transferAlreadyInProgress
    }

    let generation = UUID()
    activeGeneration = generation
    queuedEvents.removeAll(keepingCapacity: true)
    registration = makeRegistration(generation: generation)
    defer {
      finish(generation: generation)
    }

    try sendRequest(DwaDisplayWire.encodeStart(codecRawValue: 1))
    var sentRequestCount = 1
    var acknowledgedRequestCount = 0
    try await waitUntilInitiallyReady(acknowledgedRequestCount: &acknowledgedRequestCount)

    var isBufferFull = false
    var offset = 0
    var sequenceNumber: Int32 = 0

    while offset < video.count {
      while isBufferFull || sentRequestCount - acknowledgedRequestCount >= maximumOutstandingRequests {
        let ack = try await nextAck(
          timeout: flowControlTimeout,
          timeoutError: .flowControlTimedOut)
        acknowledgedRequestCount += 1

        switch ack.status {
        case .ready:
          isBufferFull = false
        case .bufferFull:
          isBufferFull = true
        case .error:
          throw LiveDisplayFeedError.displayRejected(ack.errorMessage)
        case .unknown:
          throw LiveDisplayFeedError.displayRejected("The Meta display returned an unknown MP4 acknowledgement.")
        }
      }

      let end = min(offset + chunkSize, video.count)
      let chunk = video.subdata(in: offset..<end)
      try sendRequest(DwaDisplayWire.encodeChunk(
        offset: Int64(offset),
        data: chunk,
        isLast: end == video.count,
        sequenceNumber: sequenceNumber))
      sentRequestCount += 1
      offset = end
      sequenceNumber += 1
    }
  }

  func stop() {
    _ = channel.send(
      payload: DwaDisplayWire.encodeStop(),
      messageID: UUID().uuidString)
    cancelActiveTransfer()
  }

  private func makeRegistration(generation: UUID) -> any DisplayFeedCallbackRegistration {
    channel.registerCallbacks(
      onResponse: nil,
      onEvent: { [weak self] data in
        guard let ack = DwaDisplayWire.decodeAck(fromDwaEvent: data) else { return }
        Task { [weak self] in
          await self?.receive(.ack(ack), generation: generation)
        }
      },
      onError: { [weak self] code in
        Task { [weak self] in
          await self?.receive(.error(code), generation: generation)
        }
      },
      onClosed: { [weak self] in
        Task { [weak self] in
          await self?.receive(.closed, generation: generation)
        }
      })
  }

  private func sendRequest(_ payload: Data) throws {
    guard channel.send(payload: payload, messageID: UUID().uuidString) else {
      throw LiveDisplayFeedError.requestRejected
    }
  }

  private func waitUntilInitiallyReady(
    acknowledgedRequestCount: inout Int
  ) async throws {
    while true {
      let ack = try await nextAck(
        timeout: handshakeTimeout,
        timeoutError: .handshakeTimedOut)
      acknowledgedRequestCount += 1

      switch ack.status {
      case .ready:
        return
      case .bufferFull:
        continue
      case .error:
        throw LiveDisplayFeedError.displayRejected(ack.errorMessage)
      case .unknown:
        throw LiveDisplayFeedError.displayRejected("The Meta display returned an unknown MP4 acknowledgement.")
      }
    }
  }

  private func nextAck(
    timeout: Duration,
    timeoutError: LiveDisplayFeedError
  ) async throws -> DwaVideoStreamAck {
    switch try await nextEvent(timeout: timeout, timeoutError: timeoutError) {
    case let .ack(ack):
      return ack
    case let .error(code):
      throw LiveDisplayFeedError.transportError(code)
    case .closed:
      throw LiveDisplayFeedError.transportClosed
    }
  }

  private func nextEvent(
    timeout: Duration,
    timeoutError: LiveDisplayFeedError
  ) async throws -> Event {
    if !queuedEvents.isEmpty {
      return queuedEvents.removeFirst()
    }

    let waiterID = UUID()
    eventWaiterID = waiterID
    return try await withCheckedThrowingContinuation { continuation in
      eventWaiter = continuation
      timeoutTask = Task { [weak self] in
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        await self?.timeOutWaiter(id: waiterID, error: timeoutError)
      }
    }
  }

  private func receive(_ event: Event, generation: UUID) {
    guard activeGeneration == generation else { return }

    if let waiter = eventWaiter {
      clearWaiter()
      waiter.resume(returning: event)
    } else {
      queuedEvents.append(event)
    }
  }

  private func timeOutWaiter(id: UUID, error: LiveDisplayFeedError) {
    guard eventWaiterID == id, let waiter = eventWaiter else { return }
    clearWaiter()
    waiter.resume(throwing: error)
  }

  private func cancelActiveTransfer() {
    guard activeGeneration != nil else { return }
    if let waiter = eventWaiter {
      clearWaiter()
      waiter.resume(throwing: LiveDisplayFeedError.transferCancelled)
    }
    registration?.unregister()
    registration = nil
    activeGeneration = nil
    queuedEvents.removeAll(keepingCapacity: true)
  }

  private func finish(generation: UUID) {
    guard activeGeneration == generation else { return }
    timeoutTask?.cancel()
    timeoutTask = nil
    eventWaiter = nil
    eventWaiterID = nil
    registration?.unregister()
    registration = nil
    activeGeneration = nil
    queuedEvents.removeAll(keepingCapacity: true)
  }

  private func clearWaiter() {
    timeoutTask?.cancel()
    timeoutTask = nil
    eventWaiter = nil
    eventWaiterID = nil
  }
}
