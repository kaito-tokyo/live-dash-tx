// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Testing

@testable import LDTXWorkspace

@MainActor
@Suite("Version 4 Workspace store")
struct WorkspaceV4StoreUnitTestSuite {
  @Test("tracks direct protobuf definition edits")
  func tracksDefinitionEdits() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Initial")

    #expect(!store.isDirty)
    store.editDefinition { $0.displayName = "Changed" }

    #expect(store.isDirty)
    try store.markSaved()
    #expect(!store.isDirty)
  }

  @Test("uses explicit supported profiles for a new Workspace")
  func createsWithExplicitCanvasProfiles() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Initial")
    let canvas = store.workspace.definition.definition.canvasConfiguration

    #expect(canvas.landscapeProfileID == "sdr-landscape-1080p60")
    #expect(canvas.portraitProfileID == "sdr-portrait-1080p60")
    #expect(canvas.frameRate == 60)
    #expect(
      store.workspace.definition.definition.outputConfiguration.youtubeIngestMode == .landscapeRtmps
    )
  }

  @Test("generates IDs with the documented Version 4 bit layout")
  func generatesInternalIDs() {
    let id = WorkspaceInternalIDGenerator().next(
      now: Date(timeIntervalSince1970: 1_726_000_000)
    )

    #expect(id >> 63 == 0)
    #expect(id >> 15 == 1_726_000_000_000)
  }

  @Test("adds concrete V4 input devices and Programs with internal IDs")
  func addsResources() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")

    let videoID = try store.addVideoInputDevice(displayName: "Capture Video")
    let audioID = try store.addAudioInputDevice(displayName: "Capture Audio")
    let programID = try store.addProgram(displayName: "Main")

    #expect(videoID >> 63 == 0)
    #expect(audioID >> 63 == 0)
    #expect(store.workspace.definition.definition.programs.map(\.internalID) == [programID])
    #expect(store.workspace.definition.definition.inputDevices.count == 2)
    #expect(store.isDirty)
  }

  @Test("adds and removes V4 video layers without name-based identity")
  func managesVideoLayersByInternalID() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let inputID = try store.addVideoInputDevice(displayName: "Camera")
    let vfxID = try store.addVFXSource(
      displayName: "VFX Source", inputDeviceInternalID: inputID)
    let fillID = try store.addSolidColorFill(displayName: "Background")
    let programID = try store.addProgram(displayName: "Main")
    store.editDefinition { definition in
      definition.programs[0].landscapeVideoLayerInternalIds = [inputID, vfxID, fillID]
      definition.programs[0].portraitVideoLayerInternalIds = [vfxID]
    }

    try store.removeVideoLayer(internalID: vfxID)

    let program = try #require(
      store.workspace.definition.definition.programs.first { $0.internalID == programID })
    #expect(program.landscapeVideoLayerInternalIds == [inputID, fillID])
    #expect(program.portraitVideoLayerInternalIds.isEmpty)
    #expect(store.workspace.definition.definition.videoComponents.count == 1)
    #expect(throws: WorkspaceV4StoreError.missingVideoLayer(vfxID)) {
      try store.removeVideoLayer(internalID: vfxID)
    }
  }

  @Test("adds an OCR Vision with a concrete video input and trigger")
  func addsOcrVision() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let inputID = try store.addVideoInputDevice(displayName: "Camera")
    let visionID = try store.addOcrVision(displayName: "OCR", inputDeviceInternalID: inputID)

    let vision = try #require(store.workspace.definition.definition.visions.first?.ocrVision)
    #expect(vision.internalID == visionID)
    #expect(vision.inputDeviceInternalID == inputID)
    #expect(vision.triggers.first?.intervalTrigger.intervalSeconds == 5)
  }

  @Test("does not retain invalid V4 dependent resources")
  func rejectsInvalidDependentResourcesAtomically() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")

    #expect(throws: WorkspaceV4IntegrityError.missingVideoInputDevice(99)) {
      try store.addVFXSource(displayName: "VFX", inputDeviceInternalID: 99)
    }
    #expect(throws: WorkspaceV4IntegrityError.missingInputDevice(99)) {
      try store.addOcrVision(displayName: "OCR", inputDeviceInternalID: 99)
    }

    #expect(store.workspace.definition.definition.videoComponents.isEmpty)
    #expect(store.workspace.definition.definition.visions.isEmpty)
  }

  @Test("stores per-Program V4 layer order and transforms by internal ID")
  func storesProgramLayerPreferences() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let inputID = try store.addVideoInputDevice(displayName: "Camera")
    let programID = try store.addProgram(displayName: "Main")
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationX = 0.25
    transform.scaleX = 0.5

    try store.setVideoLayerOrder([inputID], forProgramInternalID: programID, role: .landscape)
    try store.setBasicTransform(
      transform,
      forVideoLayerInternalID: inputID,
      programInternalID: programID,
      role: .landscape)

    #expect(
      store.workspace.definition.definition.programs[0].landscapeVideoLayerInternalIds == [inputID])
    #expect(
      store.workspace.preferences.preferences.programPreferences[programID]?
        .landscapeVideoLayerTransforms[inputID] == transform)
    #expect(throws: WorkspaceV4StoreError.missingProgram(99)) {
      try store.setVideoLayerOrder([], forProgramInternalID: 99, role: .landscape)
    }
  }

  @Test("rejects invalid layer changes without mutating the Workspace")
  func rejectsInvalidLayerChangesAtomically() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let inputID = try store.addVideoInputDevice(displayName: "Camera")
    let programID = try store.addProgram(displayName: "Main")
    try store.setVideoLayerOrder([inputID], forProgramInternalID: programID, role: .landscape)
    let before = store.workspace

    #expect(throws: WorkspaceV4IntegrityError.missingVideoLayer(999)) {
      try store.setVideoLayerOrder([999], forProgramInternalID: programID, role: .landscape)
    }
    #expect(store.workspace == before)
  }

  @Test("removes Vision dependencies with a referenced video input")
  func removesReferencedInputDependenciesAtomically() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let inputID = try store.addVideoInputDevice(displayName: "Camera")
    _ = try store.addOcrVision(displayName: "OCR", inputDeviceInternalID: inputID)
    try store.removeVideoLayer(internalID: inputID)
    #expect(store.workspace.definition.definition.visions.isEmpty)
  }

  @Test("rejects invalid transform preferences without mutation")
  func rejectsInvalidTransformPreferencesAtomically() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let programID = try store.addProgram(displayName: "Main")
    let before = store.workspace

    #expect(throws: WorkspaceV4IntegrityError.missingVideoLayer(999)) {
      try store.setBasicTransform(
        .init(), forVideoLayerInternalID: 999,
        programInternalID: programID, role: .landscape)
    }
    #expect(store.workspace == before)
  }

  @Test("stores independent Program audio mix preferences per Canvas")
  func storesProgramAudioMixPreferences() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let audioID = try store.addAudioInputDevice(displayName: "Mic")
    let programID = try store.addProgram(displayName: "Main")

    try store.setMasterVolume(-3, programInternalID: programID, role: .landscape)
    try store.setAudioChannelGain(
      -12, forAudioInputDeviceInternalID: audioID,
      programInternalID: programID, role: .landscape)
    try store.setAudioChannelMuted(
      true, forAudioInputDeviceInternalID: audioID,
      programInternalID: programID, role: .portrait)

    let preference = try #require(
      store.workspace.preferences.preferences.programPreferences[programID])
    #expect(preference.landscapeMasterVolume == -3)
    #expect(preference.landscapeAudioChannelGains[audioID] == -12)
    #expect(preference.portraitAudioChannelMuted[audioID] == true)
  }

  @Test("stores the Workspace-wide monitor volume")
  func storesMonitorVolume() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    try store.setMonitorVolume(-18)

    #expect(store.workspace.preferences.preferences.monitorVolume == -18)
  }

  @Test("removes dependent V4 preferences with a deleted resource")
  func removesDependentPreferencesWithResource() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let inputID = try store.addVideoInputDevice(displayName: "Camera")
    let componentID = try store.addVFXSource(displayName: "VFX", inputDeviceInternalID: inputID)
    let programID = try store.addProgram(displayName: "Main")
    try store.setVideoLayerOrder([componentID], forProgramInternalID: programID, role: .landscape)
    try store.setBasicTransform(
      .init(), forVideoLayerInternalID: componentID,
      programInternalID: programID, role: .landscape)

    try store.removeVideoComponent(internalID: componentID)

    #expect(store.workspace.definition.definition.videoComponents.isEmpty)
    #expect(
      store.workspace.definition.definition.programs[0].landscapeVideoLayerInternalIds.isEmpty)
    #expect(
      store.workspace.preferences.preferences.programPreferences[programID]?
        .landscapeVideoLayerTransforms[componentID] == nil)
  }

  @Test("removes a Vision by its concrete internal ID")
  func removesVision() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let inputID = try store.addVideoInputDevice(displayName: "Camera")
    let visionID = try store.addOcrVision(displayName: "OCR", inputDeviceInternalID: inputID)

    try store.removeVision(internalID: visionID)

    #expect(store.workspace.definition.definition.visions.isEmpty)
  }

  @Test("removes a Program and its preferences atomically")
  func removesProgram() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let programID = try store.addProgram(displayName: "Main")
    try store.setMasterVolume(-6, programInternalID: programID, role: .landscape)

    try store.removeProgram(internalID: programID)

    #expect(store.workspace.definition.definition.programs.isEmpty)
    #expect(store.workspace.preferences.preferences.programPreferences[programID] == nil)
    #expect(throws: WorkspaceV4StoreError.missingProgram(programID)) {
      try store.removeProgram(internalID: programID)
    }
  }

  @Test("adds Clock and Test Pattern Video Components")
  func addsClockAndTestPattern() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let clockID = try store.addClock(displayName: "Clock")
    let patternID = try store.addTestPattern(displayName: "Test Pattern")

    #expect(
      store.workspace.definition.definition.videoComponents.map {
        try? WorkspaceV4IntegrityValidator.videoComponentID($0)
      } == [clockID, patternID])
  }

  @Test("adds all V4 gradient Video Components")
  func addsGradientVideoComponents() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let linearID = try store.addLinearGradientFill(displayName: "Linear")
    let radialID = try store.addRadialGradientFill(displayName: "Radial")
    let conicID = try store.addConicGradientFill(displayName: "Conic")

    #expect(
      store.workspace.definition.definition.videoComponents.compactMap { component in
        switch component.definition {
        case .linearGradientFill(let value): value.internalID
        case .radialGradientFill(let value): value.internalID
        case .conicGradientFill(let value): value.internalID
        default: nil
        }
      } == [linearID, radialID, conicID])
  }
}
