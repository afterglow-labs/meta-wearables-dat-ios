import Foundation

struct DwaVideoStreamAck: Equatable, Sendable {
  enum Status: Int, Equatable, Sendable {
    case unknown = 0
    case ready = 1
    case bufferFull = 2
    case error = 3
  }

  let status: Status
  let bytesReceived: Int64
  let errorMessage: String
}

enum DwaDisplayWire {
  private static let displayCapability: UInt64 = 1

  static func encodeStart(codecRawValue: UInt64) -> Data {
    var request = ProtoWriter()
    request.appendVarintField(1, codecRawValue)

    var envelope = ProtoWriter()
    envelope.appendDataField(5, request.data)
    return envelope.data
  }

  static func encodeChunk(
    offset: Int64,
    data: Data,
    isLast: Bool,
    sequenceNumber: Int32
  ) -> Data {
    precondition(offset >= 0)
    precondition(sequenceNumber >= 0)

    var chunk = ProtoWriter()
    chunk.appendVarintField(1, UInt64(offset))
    chunk.appendDataField(2, data)
    if isLast {
      chunk.appendVarintField(3, 1)
    }
    chunk.appendVarintField(4, UInt64(sequenceNumber))

    var envelope = ProtoWriter()
    envelope.appendDataField(6, chunk.data)
    return envelope.data
  }

  static func encodeStop() -> Data {
    var envelope = ProtoWriter()
    envelope.appendDataField(7, Data())
    return envelope.data
  }

  static func decodeAck(fromDwaEvent data: Data) -> DwaVideoStreamAck? {
    guard
      let event = try? ProtoMessage(data),
      event.varint(for: 2) == displayCapability,
      let displayPayload = event.data(for: 6),
      let displayEvent = try? ProtoMessage(displayPayload),
      let ackPayload = displayEvent.data(for: 3),
      let ack = try? ProtoMessage(ackPayload)
    else {
      return nil
    }

    let rawStatus = Int(ack.varint(for: 1) ?? 0)
    guard let status = DwaVideoStreamAck.Status(rawValue: rawStatus) else {
      return nil
    }

    let rawBytesReceived = ack.varint(for: 2) ?? 0
    guard rawBytesReceived <= UInt64(Int64.max) else {
      return nil
    }

    let errorMessage: String
    if let encodedMessage = ack.data(for: 3) {
      guard let decodedMessage = String(data: encodedMessage, encoding: .utf8) else {
        return nil
      }
      errorMessage = decodedMessage
    } else {
      errorMessage = ""
    }

    return DwaVideoStreamAck(
      status: status,
      bytesReceived: Int64(rawBytesReceived),
      errorMessage: errorMessage)
  }
}

private struct ProtoWriter {
  private(set) var data = Data()

  mutating func appendVarintField(_ fieldNumber: UInt64, _ value: UInt64) {
    appendVarint((fieldNumber << 3) | 0)
    appendVarint(value)
  }

  mutating func appendDataField(_ fieldNumber: UInt64, _ value: Data) {
    appendVarint((fieldNumber << 3) | 2)
    appendVarint(UInt64(value.count))
    data.append(value)
  }

  private mutating func appendVarint(_ value: UInt64) {
    var remainder = value
    while remainder >= 0x80 {
      data.append(UInt8(remainder & 0x7F) | 0x80)
      remainder >>= 7
    }
    data.append(UInt8(remainder))
  }
}

private struct ProtoMessage {
  private var varints: [UInt64: UInt64] = [:]
  private var byteStrings: [UInt64: Data] = [:]

  init(_ data: Data) throws {
    var cursor = ProtoCursor(data)
    while !cursor.isAtEnd {
      let tag = try cursor.readVarint()
      let fieldNumber = tag >> 3
      guard fieldNumber != 0 else {
        throw ProtoError.invalidField
      }

      switch tag & 0x07 {
      case 0:
        varints[fieldNumber] = try cursor.readVarint()
      case 1:
        try cursor.skip(8)
      case 2:
        let length = try cursor.readVarint()
        guard length <= UInt64(Int.max) else {
          throw ProtoError.invalidLength
        }
        byteStrings[fieldNumber] = try cursor.readData(count: Int(length))
      case 5:
        try cursor.skip(4)
      default:
        throw ProtoError.unsupportedWireType
      }
    }
  }

  func varint(for fieldNumber: UInt64) -> UInt64? {
    varints[fieldNumber]
  }

  func data(for fieldNumber: UInt64) -> Data? {
    byteStrings[fieldNumber]
  }
}

private struct ProtoCursor {
  private let data: Data
  private var index: Data.Index

  init(_ data: Data) {
    self.data = data
    index = data.startIndex
  }

  var isAtEnd: Bool {
    index == data.endIndex
  }

  mutating func readVarint() throws -> UInt64 {
    var value: UInt64 = 0
    for byteIndex in 0..<10 {
      guard index < data.endIndex else {
        throw ProtoError.truncated
      }

      let byte = data[index]
      data.formIndex(after: &index)
      if byteIndex == 9 && byte > 1 {
        throw ProtoError.varintOverflow
      }

      value |= UInt64(byte & 0x7F) << UInt64(byteIndex * 7)
      if byte & 0x80 == 0 {
        return value
      }
    }
    throw ProtoError.varintOverflow
  }

  mutating func readData(count: Int) throws -> Data {
    guard count >= 0, data.distance(from: index, to: data.endIndex) >= count else {
      throw ProtoError.truncated
    }
    let end = data.index(index, offsetBy: count)
    let result = data[index..<end]
    index = end
    return Data(result)
  }

  mutating func skip(_ count: Int) throws {
    _ = try readData(count: count)
  }
}

private enum ProtoError: Error {
  case invalidField
  case invalidLength
  case truncated
  case unsupportedWireType
  case varintOverflow
}
