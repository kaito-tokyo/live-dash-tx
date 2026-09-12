// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXWorkspace

@Suite("Version 4 Workspace packages")
struct WorkspaceV4PackageServiceIntegrationTestSuite {
  @Test("writes only protobuf documents and preserves package resources")
  func writesProtobufOnlyPackage() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    let assetsURL = packageURL.appendingPathComponent("Assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    let assetURL = assetsURL.appendingPathComponent("kept.txt")
    try Data("kept".utf8).write(to: assetURL)
    try Data("legacy".utf8).write(
      to: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName)
    )

    let workspace = makeWorkspace()
    let service = WorkspaceV4PackageService()
    try service.save(workspace, to: packageURL)

    #expect(try service.load(at: packageURL) == workspace)
    #expect(service.isV4Package(at: packageURL))
    #expect(service.isV4PackageCandidate(at: packageURL))
    #expect(FileManager.default.fileExists(atPath: assetURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName).path
      ))
    #expect(
      FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName).path
      ))
    #expect(
      FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent(
          WorkspacePackageLayout.preferencesProtobufFileName
        ).path
      ))
  }

  @Test("refuses to open a Version 3 package")
  func rejectsV3Package() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try Data("{}".utf8).write(
      to: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName)
    )

    #expect(throws: WorkspaceV4PackageServiceError.unsupportedWorkspaceV3Package(packageURL)) {
      try WorkspaceV4PackageService().load(at: packageURL)
    }
    let service = WorkspaceV4PackageService()
    #expect(!service.isV4Package(at: packageURL))
    #expect(!service.isV4PackageCandidate(at: packageURL))

    try Data("{}".utf8).write(
      to: packageURL.appendingPathComponent(WorkspacePackageLayout.preferencesJSONFileName))
    #expect(!service.isV4PackageCandidate(at: packageURL))
  }

  @Test("rejects a protobuf package containing a legacy preferences mirror")
  func rejectsMixedPackage() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    let service = WorkspaceV4PackageService()
    try service.save(makeWorkspace(), to: packageURL)
    try Data("{}".utf8).write(
      to: packageURL.appendingPathComponent(WorkspacePackageLayout.preferencesJSONFileName))

    #expect(throws: WorkspaceV4PackageServiceError.unsupportedWorkspaceV3Package(packageURL)) {
      try service.load(at: packageURL)
    }
  }

  @Test("recognizes a malformed protobuf-only package as a V4 candidate")
  func recognizesMalformedV4Candidate() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try Data().write(to: packageURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName))
    try Data().write(
      to: packageURL.appendingPathComponent(WorkspacePackageLayout.preferencesProtobufFileName))

    let service = WorkspaceV4PackageService()
    #expect(service.isV4PackageCandidate(at: packageURL))
    #expect(!service.isV4Package(at: packageURL))
  }

  @Test("rejects a Program that references no V4 video layer")
  func rejectsMissingVideoLayer() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    program.landscapeVideoLayerInternalIds = [99]
    definition.programs = [program]

    #expect(throws: WorkspaceV4IntegrityError.missingVideoLayer(99)) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects a VFX Source that references an audio input device")
  func rejectsAudioInputDeviceForVFXSource() throws {
    var audioDevice = Ldtx_Workspace_V4_AudioInputDevice()
    audioDevice.internalID = 1
    var input = Ldtx_Workspace_V4_InputDeviceWrapper()
    input.definition = .audioDevice(audioDevice)

    var source = Ldtx_Workspace_V4_VfxSourceComponent()
    source.internalID = 2
    source.inputDeviceInternalID = 1
    var component = Ldtx_Workspace_V4_VideoComponentWrapper()
    component.definition = .vfxSource(source)

    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.inputDevices = [input]
    definition.videoComponents = [component]

    #expect(throws: WorkspaceV4IntegrityError.missingVideoInputDevice(1)) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects entity IDs reused across V4 resource kinds")
  func rejectsCrossKindDuplicateInternalID() throws {
    var input = Ldtx_Workspace_V4_InputDeviceWrapper()
    input.videoDevice = .with { $0.internalID = 1 }
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.inputDevices = [input]
    definition.programs = [program]

    #expect(throws: WorkspaceV4IntegrityError.duplicateInternalID) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects an OCR Vision without a video input device")
  func rejectsVisionWithMissingVideoInput() throws {
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = 2
    vision.inputDeviceInternalID = 1
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.visions = [wrapper]

    #expect(throws: WorkspaceV4IntegrityError.missingInputDevice(1)) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects Program preferences that reference removed resources")
  func rejectsDanglingProgramPreferences() throws {
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.programPreferences[99] = .init()
    let workspace = WorkspaceV4Package(
      definition: WorkspaceV4DefinitionDocument(
        externalID: UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000001")!,
        definition: definition
      ),
      preferences: WorkspaceV4PreferencesDocument(
        externalID: UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000002")!,
        preferences: preferences
      )
    )

    #expect(throws: WorkspaceV4IntegrityError.missingProgram(99)) {
      try WorkspaceV4IntegrityValidator.validate(workspace)
    }
  }

  @Test("rejects an output profile not supported by the V4 runtime")
  func rejectsUnsupportedOutputProfile() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.canvasConfiguration.landscapeProfileID = "custom-4k"

    #expect(throws: WorkspaceV4IntegrityError.unsupportedOutputProfile("custom-4k")) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects an internal ID with the sign bit set")
  func rejectsInternalIDWithSignBit() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = UInt64(1) << 63
    definition.programs = [program]

    #expect(throws: WorkspaceV4IntegrityError.invalidInternalID) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects duplicate Video Layers in one Program")
  func rejectsDuplicateVideoLayers() throws {
    var video = Ldtx_Workspace_V4_VideoInputDevice()
    video.internalID = 1
    var input = Ldtx_Workspace_V4_InputDeviceWrapper()
    input.videoDevice = video
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 2
    program.landscapeVideoLayerInternalIds = [1, 1]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.inputDevices = [input]
    definition.programs = [program]

    #expect(throws: WorkspaceV4IntegrityError.duplicateVideoLayer(2)) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  private func makeWorkspace() -> WorkspaceV4Package {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.displayName = "Unite"
    return WorkspaceV4Package(
      definition: WorkspaceV4DefinitionDocument(
        externalID: UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000001")!,
        definition: definition
      ),
      preferences: WorkspaceV4PreferencesDocument(
        externalID: UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000002")!,
        preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4()
      )
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
