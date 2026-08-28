import Foundation
import MWDATCore

public struct LiveDisplayFeedConfiguration: Sendable {
  public var width: Int
  public var height: Int
  public var frameRate: Int
  public var averageBitRate: Int
  public var fragmentDuration: TimeInterval
  public var chunkSize: Int
  public var maximumBufferedBytes: Int

  public init(
    width: Int = 198,
    height: Int = 352,
    frameRate: Int = 24,
    averageBitRate: Int = 750_000,
    fragmentDuration: TimeInterval = 0.25,
    chunkSize: Int = 14 * 1024,
    maximumBufferedBytes: Int = 256 * 1024
  ) {
    precondition(width > 0 && height > 0)
    precondition(width.isMultiple(of: 2) && height.isMultiple(of: 2))
    precondition(width <= 400 && height <= 400 && width * height <= 70_000)
    precondition(frameRate > 0)
    precondition(averageBitRate > 0)
    precondition(fragmentDuration > 0)
    precondition(chunkSize > 0)
    precondition(maximumBufferedBytes >= chunkSize)

    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.averageBitRate = averageBitRate
    self.fragmentDuration = fragmentDuration
    self.chunkSize = chunkSize
    self.maximumBufferedBytes = maximumBufferedBytes
  }
}

public enum LiveDisplayFeedError: LocalizedError, Sendable, Equatable {
  case displayChannelUnavailable
  case invalidChunkSize
  case emptyVideo
  case transferAlreadyInProgress
  case requestRejected
  case displayRejected(String)
  case transportClosed
  case transportError(UInt16)
  case handshakeTimedOut
  case flowControlTimedOut
  case transferCancelled
  case bufferLimitExceeded
  case encoderFailure(String)

  public var errorDescription: String? {
    switch self {
    case .displayChannelUnavailable:
      return "The Meta display transport is unavailable."
    case .invalidChunkSize:
      return "MP4 chunks must be between 1 and 15,000 bytes."
    case .emptyVideo:
      return "The MP4 payload is empty."
    case .transferAlreadyInProgress:
      return "An MP4 transfer is already in progress."
    case .requestRejected:
      return "The Meta display rejected the live feed request."
    case let .displayRejected(message):
      return message.isEmpty ? "The Meta display rejected the live feed." : message
    case .transportClosed:
      return "The Meta display transport closed unexpectedly."
    case let .transportError(code):
      return "The Meta display transport failed with code \(code)."
    case .handshakeTimedOut:
      return "The Meta display did not become ready for MP4 transfer."
    case .flowControlTimedOut:
      return "The Meta display stopped accepting MP4 chunks."
    case .transferCancelled:
      return "The MP4 transfer was cancelled."
    case .bufferLimitExceeded:
      return "The Meta display could not consume frames quickly enough."
    case let .encoderFailure(message):
      return "The live display encoder failed: \(message)"
    }
  }
}
