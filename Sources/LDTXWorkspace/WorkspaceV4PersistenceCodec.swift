// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf

/// Encodes and decodes the V4 persisted Workspace documents.
public enum WorkspaceV4PersistenceCodec {
  /// Creates a UUIDv7 identifier for a newly persisted document.
  public static func makeExternalID(
    now: Date = Date(),
    randomBytes: () -> [UInt8] = { (0..<10).map { _ in UInt8.random(in: .min ... .max) } }
  ) -> UUID {
    let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
    let random = randomBytes()
    precondition(random.count >= 10)
    let bytes: [UInt8] = [
      UInt8((milliseconds >> 40) & 0xff),
      UInt8((milliseconds >> 32) & 0xff),
      UInt8((milliseconds >> 24) & 0xff),
      UInt8((milliseconds >> 16) & 0xff),
      UInt8((milliseconds >> 8) & 0xff),
      UInt8(milliseconds & 0xff),
      0x70 | (random[0] & 0x0f),
      random[1],
      0x80 | (random[2] & 0x3f),
      random[3], random[4], random[5], random[6], random[7], random[8], random[9],
    ]
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    return UUID(
      uuidString:
        "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    )!
  }

  public static func encodeDefinition(
    _ document: WorkspaceV4DefinitionDocument
  ) throws -> Data {
    try validateExternalID(document.externalID)
    var envelope = Ldtx_Envelope_WorkspaceDefinitionEnvelope()
    envelope.externalID = document.externalID.uuidString.lowercased()
    envelope.workspaceDefinitionV4 = document.definition
    return try envelope.serializedData(options: deterministicEncodingOptions)
  }

  public static func decodeDefinition(
    from data: Data
  ) throws -> WorkspaceV4DefinitionDocument {
    let envelope = try Ldtx_Envelope_WorkspaceDefinitionEnvelope(serializedBytes: data)
    guard let externalID = try uuidV7(from: envelope.externalID) else {
      throw WorkspaceV4PersistenceError.invalidExternalID(envelope.externalID)
    }
    guard case .workspaceDefinitionV4(let definition)? = envelope.definition else {
      throw WorkspaceV4PersistenceError.missingDefinition
    }
    return WorkspaceV4DefinitionDocument(externalID: externalID, definition: definition)
  }

  public static func encodePreferences(
    _ document: WorkspaceV4PreferencesDocument
  ) throws -> Data {
    try validateExternalID(document.externalID)
    var envelope = Ldtx_Envelope_WorkspacePreferencesEnvelope()
    envelope.externalID = document.externalID.uuidString.lowercased()
    envelope.workspacePreferencesV4 = document.preferences
    return try envelope.serializedData(options: deterministicEncodingOptions)
  }

  public static func decodePreferences(
    from data: Data
  ) throws -> WorkspaceV4PreferencesDocument {
    let envelope = try Ldtx_Envelope_WorkspacePreferencesEnvelope(serializedBytes: data)
    guard let externalID = try uuidV7(from: envelope.externalID) else {
      throw WorkspaceV4PersistenceError.invalidExternalID(envelope.externalID)
    }
    guard case .workspacePreferencesV4(let preferences)? = envelope.preferences else {
      throw WorkspaceV4PersistenceError.missingPreferences
    }
    return WorkspaceV4PreferencesDocument(externalID: externalID, preferences: preferences)
  }

  private static var deterministicEncodingOptions: BinaryEncodingOptions {
    var options = BinaryEncodingOptions()
    options.useDeterministicOrdering = true
    return options
  }

  private static func uuidV7(from value: String) throws -> UUID? {
    guard let uuid = UUID(uuidString: value) else { return nil }
    let components = value.split(separator: "-", omittingEmptySubsequences: false)
    guard components.count == 5, components[2].first?.lowercased() == "7" else {
      return nil
    }
    return uuid
  }

  private static func validateExternalID(_ value: UUID) throws {
    guard try uuidV7(from: value.uuidString) != nil else {
      throw WorkspaceV4PersistenceError.invalidExternalID(value.uuidString)
    }
  }
}

/// One persisted Version 4 WorkspaceDefinition document.
public struct WorkspaceV4DefinitionDocument: Equatable, Sendable {
  public var externalID: UUID
  public var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4

  public init(
    externalID: UUID,
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) {
    self.externalID = externalID
    self.definition = definition
  }
}

/// One persisted Version 4 WorkspacePreferences document.
public struct WorkspaceV4PreferencesDocument: Equatable, Sendable {
  public var externalID: UUID
  public var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4

  public init(
    externalID: UUID,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4
  ) {
    self.externalID = externalID
    self.preferences = preferences
  }
}

public enum WorkspaceV4PersistenceError: Error, Equatable {
  case invalidExternalID(String)
  case missingDefinition
  case missingPreferences
}
