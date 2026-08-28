import Foundation
import MWDATCore

/// Transfers a complete MP4 file to an already-started Meta display capability.
/// No callbacks or transport resources are allocated until `play(_:)` is called.
public final class DisplayMP4Transfer: @unchecked Sendable {
  private let transport: DisplayFeedTransport

  public init(session: DeviceSession, chunkSize: Int = 14 * 1024) throws {
    guard (1...15_000).contains(chunkSize) else {
      throw LiveDisplayFeedError.invalidChunkSize
    }
    guard let channel = session.getOrCreateDwaCapabilityChannel() else {
      throw LiveDisplayFeedError.displayChannelUnavailable
    }

    transport = DisplayFeedTransport(
      channel: DwaDisplayFeedChannel(channel: channel),
      chunkSize: chunkSize)
  }

  public func play(_ mp4Data: Data) async throws {
    try await transport.send(mp4Data)
  }

  public func stop() async {
    await transport.stop()
  }
}
