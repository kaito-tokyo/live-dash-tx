// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspace
import SwiftProtobuf
import Testing

@Suite
struct WorkspaceV4PersistenceCodecUnitTestSuite {
  @Test("creates UUID version 7 external identifiers")
  func createsUUIDv7ExternalID() {
    let identifier = WorkspaceV4PersistenceCodec.makeExternalID(
      now: Date(timeIntervalSince1970: 1_726_000_000),
      randomBytes: { Array(repeating: 0, count: 10) }
    )

    #expect(identifier.uuidString.lowercased().split(separator: "-")[2].first == "7")
  }

  @Test func definitionRoundTripsThroughItsEnvelope() throws {
    let externalID = try #require(UUID(uuidString: "018f1f4d-80d0-7c2a-bd98-1f4adf7f8d5e"))
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.displayName = "Unite-v4"

    let document = WorkspaceV4DefinitionDocument(
      externalID: externalID,
      definition: definition
    )

    let decoded = try WorkspaceV4PersistenceCodec.decodeDefinition(
      from: WorkspaceV4PersistenceCodec.encodeDefinition(document)
    )

    #expect(decoded == document)
  }

  @Test func preferencesRoundTripThroughTheirEnvelope() throws {
    let externalID = try #require(UUID(uuidString: "018f1f4d-80d0-7c2a-bd98-1f4adf7f8d5e"))
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.monitorVolume = -12

    let document = WorkspaceV4PreferencesDocument(
      externalID: externalID,
      preferences: preferences
    )

    let decoded = try WorkspaceV4PersistenceCodec.decodePreferences(
      from: WorkspaceV4PersistenceCodec.encodePreferences(document)
    )

    #expect(decoded == document)
  }

  @Test func definitionRejectsANonV7ExternalID() throws {
    var envelope = Ldtx_Envelope_WorkspaceDefinitionEnvelope()
    envelope.externalID = "550e8400-e29b-41d4-a716-446655440000"
    envelope.workspaceDefinitionV4 = Ldtx_Workspace_V4_WorkspaceDefinitionV4()

    #expect(throws: WorkspaceV4PersistenceError.invalidExternalID(envelope.externalID)) {
      try WorkspaceV4PersistenceCodec.decodeDefinition(from: envelope.serializedData())
    }
  }

  @Test func encodingRejectsANonV7ExternalID() throws {
    let externalID = try #require(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
    #expect(throws: WorkspaceV4PersistenceError.invalidExternalID(externalID.uuidString)) {
      try WorkspaceV4PersistenceCodec.encodeDefinition(
        WorkspaceV4DefinitionDocument(
          externalID: externalID, definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4()))
    }
    #expect(throws: WorkspaceV4PersistenceError.invalidExternalID(externalID.uuidString)) {
      try WorkspaceV4PersistenceCodec.encodePreferences(
        WorkspaceV4PreferencesDocument(
          externalID: externalID, preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4()))
    }
  }

  @Test func preferencesRequireAConcreteDocument() throws {
    var envelope = Ldtx_Envelope_WorkspacePreferencesEnvelope()
    envelope.externalID = "018f1f4d-80d0-7c2a-bd98-1f4adf7f8d5e"

    #expect(throws: WorkspaceV4PersistenceError.missingPreferences) {
      try WorkspaceV4PersistenceCodec.decodePreferences(from: envelope.serializedData())
    }
  }
}
