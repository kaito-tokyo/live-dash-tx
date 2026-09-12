// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import Testing

@testable import LDTXAppCore

@MainActor
@Suite("Version 4 Workspace persistence coordinator")
struct WorkspaceV4PersistenceCoordinatorIntegrationTestSuite {
  @Test("saves and reloads a V4 store without a V3 projection")
  func savesAndReloadsV4Store() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace")
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let coordinator = WorkspaceV4PersistenceCoordinator(store: store)

    try coordinator.save(store, to: packageURL)
    let reloaded = try coordinator.load(at: packageURL)

    #expect(reloaded.workspace.definition.definition.displayName == "Unite")
    #expect(!reloaded.isDirty)
  }

  @Test("keeps local state at the package path and starts Save As fresh")
  func keysLocalStateByPackagePath() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = WorkspaceLocalStateStorage(userDefaults: defaults)
    let original = URL(fileURLWithPath: "/tmp/Original.ldtxworkspace")
    let savedAs = URL(fileURLWithPath: "/tmp/SavedAs.ldtxworkspace")

    try storage.setState(
      WorkspaceLocalState(selectedProgramInternalID: 7), for: original)

    #expect(storage.state(for: original).selectedProgramInternalID == 7)
    #expect(storage.state(for: savedAs).selectedProgramInternalID == nil)
  }

  @Test("keeps selection and physical video IDs outside the V4 package")
  func keepsRuntimeLocalStateOutsidePackage() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = WorkspaceLocalStateStorage(userDefaults: defaults)
    let packageURL = URL(fileURLWithPath: "/tmp/Workspace.ldtxworkspace")
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 9
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    let store = try WorkspaceV4Store(
      workspace: WorkspaceV4Package(
        definition: WorkspaceV4DefinitionDocument(
          externalID: UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000001")!,
          definition: definition),
        preferences: WorkspaceV4PreferencesDocument(
          externalID: UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000002")!,
          preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4())
      ))
    let coordinator = WorkspaceV4PersistenceCoordinator(
      store: store, url: packageURL, localStateStorage: storage)

    #expect(coordinator.selectedProgramInternalID == 9)
    coordinator.selectedProgramInternalID = 12
    coordinator.setPhysicalVideoDeviceID("camera", for: 2)
    coordinator.setPhysicalAudioDeviceID("microphone", for: 3)

    #expect(coordinator.selectedProgramInternalID == 9)
    #expect(coordinator.physicalVideoDeviceID(for: 2) == "camera")
    #expect(coordinator.physicalAudioDeviceID(for: 3) == "microphone")
    coordinator.setSynchronizesLandscapeMixToPortrait(true, for: 12)
    #expect(coordinator.synchronizesLandscapeMixToPortrait(for: 12))
    coordinator.setMonitorsAudioInputDevice(true, for: 3)
    #expect(coordinator.monitorsAudioInputDevice(3))
  }

  @Test("resolves only physical devices assigned to concrete V4 inputs")
  func resolvesPhysicalCaptureAssignments() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = WorkspaceLocalStateStorage(userDefaults: defaults)
    let packageURL = URL(fileURLWithPath: "/tmp/Workspace.ldtxworkspace")
    var video = Ldtx_Workspace_V4_VideoInputDevice()
    video.internalID = 2
    var videoInput = Ldtx_Workspace_V4_InputDeviceWrapper()
    videoInput.videoDevice = video
    var audio = Ldtx_Workspace_V4_AudioInputDevice()
    audio.internalID = 3
    var audioInput = Ldtx_Workspace_V4_InputDeviceWrapper()
    audioInput.audioDevice = audio
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.inputDevices = [videoInput, audioInput]
    let store = try WorkspaceV4Store(
      workspace: WorkspaceV4Package(
        definition: WorkspaceV4DefinitionDocument(
          externalID: WorkspaceV4PersistenceCodec.makeExternalID(), definition: definition),
        preferences: WorkspaceV4PreferencesDocument(
          externalID: WorkspaceV4PersistenceCodec.makeExternalID(),
          preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4())
      ))
    let coordinator = WorkspaceV4PersistenceCoordinator(
      store: store, url: packageURL, localStateStorage: storage)
    coordinator.setPhysicalVideoDeviceID("camera", for: 2)
    coordinator.setPhysicalVideoDeviceID("ignored-camera", for: 3)
    coordinator.setPhysicalAudioDeviceID("microphone", for: 3)

    let assignments = coordinator.physicalCaptureAssignments()
    #expect(assignments.videoCameraIDs == ["camera"])
    #expect(assignments.audioDeviceIDs == ["microphone"])
  }

  @Test("acquires and releases the package lock used by V4 persistence")
  func managesPackageLock() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace")
    let coordinator = try WorkspaceV4PersistenceCoordinator(
      store: WorkspaceV4Store(cleanNamed: "Unite"))

    let lock = try coordinator.acquireLock(at: packageURL, createsPackageDirectory: true)
    coordinator.activateLock(lock)

    #expect(coordinator.workspaceLock == lock)
    coordinator.releaseActiveLock()
    #expect(coordinator.workspaceLock == nil)
  }

  @Test("keeps the active lock effective across a V4 save")
  func keepsActiveLockAcrossSave() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace")
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let coordinator = WorkspaceV4PersistenceCoordinator(store: store)
    try coordinator.save(store, to: packageURL)

    let lock = try coordinator.acquireLock(at: packageURL)
    coordinator.activateLock(lock)
    defer { coordinator.releaseActiveLock() }
    try coordinator.save(store, to: packageURL)

    #expect(throws: WorkspaceLockError.self) {
      _ = try WorkspaceLockService().acquire(at: packageURL)
    }
  }

  @Test("projects V4 layer IDs and transforms directly for rendering")
  func projectsV4RenderGraph() throws {
    var video = Ldtx_Workspace_V4_VideoInputDevice()
    video.internalID = 11
    var input = Ldtx_Workspace_V4_InputDeviceWrapper()
    input.videoDevice = video
    var audio = Ldtx_Workspace_V4_AudioInputDevice()
    audio.internalID = 12
    var audioInput = Ldtx_Workspace_V4_InputDeviceWrapper()
    audioInput.audioDevice = audio
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    program.landscapeVideoLayerInternalIds = [11]
    program.portraitVideoLayerInternalIds = [11]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    definition.inputDevices = [input, audioInput]
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationX = 0.25
    transform.translationY = 0.5
    transform.scaleX = 0.75
    transform.scaleY = 0.6
    var preference = Ldtx_Workspace_V4_ProgramPreference()
    preference.landscapeVideoLayerTransforms = [11: transform]
    preference.landscapeMasterVolume = -3
    preference.landscapeAudioChannelGains = [12: -12]
    preference.landscapeAudioChannelMuted = [12: true]
    preference.portraitMasterVolume = -9
    preference.portraitAudioChannelGains = [12: -30]
    preference.portraitAudioChannelMuted = [12: false]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.programPreferences = [7: preference]

    let graph = try WorkspaceV4RenderGraph(
      definition: definition, preferences: preferences, programInternalID: 7, role: .landscape)

    #expect(graph.composite.steps.map(\.name) == ["v4-11"])
    #expect(graph.layerPreferences.first?.destinationX == 0.25)
    #expect(graph.layerPreferences.first?.destinationScaleY == 0.6)
    #expect(graph.composite.audioChannels.map(\.name) == ["v4-12"])
    #expect(
      graph.audioPreferences.masterVolume
        == ProgramPreferences.linearAudioChannelGain(fromDecibels: -3))
    #expect(
      graph.audioPreferences.audioChannelGainsByName["v4-12"]
        == ProgramPreferences.linearAudioChannelGain(fromDecibels: -12))
    #expect(graph.audioPreferences.audioMutedByInputDeviceName["v4-12"] == true)

    let portraitGraph = try WorkspaceV4RenderGraph(
      definition: definition, preferences: preferences, programInternalID: 7, role: .portrait,
      localState: WorkspaceLocalState(
        synchronizesLandscapeMixToPortraitByProgramInternalID: [7: true]))
    #expect(
      portraitGraph.audioPreferences.masterVolume
        == ProgramPreferences.linearAudioChannelGain(fromDecibels: -3))
    #expect(
      portraitGraph.audioPreferences.audioChannelGainsByName["v4-12"]
        == ProgramPreferences.linearAudioChannelGain(fromDecibels: -12))
    #expect(portraitGraph.audioPreferences.audioMutedByInputDeviceName["v4-12"] == true)

    let configuration = try WorkspaceV4RenderGraph.runtimeConfiguration(
      definition: definition,
      preferences: preferences,
      localState: WorkspaceLocalState(videoInputDevicePhysicalIDs: [11: "camera-id"]),
      programInternalID: 7,
      role: .landscape,
      timeSeconds: 1
    )
    #expect(configuration.cameraIDsByInputKey == ["v4-11": "camera-id"])
    #expect(configuration.composite.steps.map(\.name) == ["v4-11"])
    #expect(configuration.frameRate == ProgramOutputProfile.sdr1080p60.frameRate)
  }

  @Test("projects a V4 background-removal VFX effect into the runtime")
  func projectsBackgroundRemovalEffect() throws {
    var video = Ldtx_Workspace_V4_VideoInputDevice()
    video.internalID = 11
    var input = Ldtx_Workspace_V4_InputDeviceWrapper()
    input.videoDevice = video
    var removal = Ldtx_Workspace_V4_BackgroundRemovalVfxEffect()
    removal.model = .mediapipeLandscape
    var effect = Ldtx_Workspace_V4_VideoEffectWrapper()
    effect.backgroundRemoval = removal
    var source = Ldtx_Workspace_V4_VfxSourceComponent()
    source.internalID = 12
    source.inputDeviceInternalID = 11
    source.effects = [effect]
    var component = Ldtx_Workspace_V4_VideoComponentWrapper()
    component.vfxSource = source
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    program.landscapeVideoLayerInternalIds = [12]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.inputDevices = [input]
    definition.videoComponents = [component]
    definition.programs = [program]

    let configuration = try WorkspaceV4RenderGraph.runtimeConfiguration(
      definition: definition,
      preferences: .init(),
      localState: .init(),
      programInternalID: 7,
      role: .landscape,
      timeSeconds: 1
    )
    #expect(configuration.backgroundRemovalInputKeys == ["v4-vfx-12"])
  }

  @Test("projects every V4 fill component into the rendering graph")
  func projectsFillComponents() throws {
    var solid = Ldtx_Workspace_V4_FillSolidColorComponent()
    solid.internalID = 20
    var solidWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    solidWrapper.solidColorFill = solid

    var linear = Ldtx_Workspace_V4_FillLinearGradientComponent()
    linear.internalID = 21
    var linearWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    linearWrapper.linearGradientFill = linear

    var radial = Ldtx_Workspace_V4_FillRadialGradientComponent()
    radial.internalID = 22
    var radialWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    radialWrapper.radialGradientFill = radial

    var conic = Ldtx_Workspace_V4_FillConicGradientComponent()
    conic.internalID = 23
    var conicWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    conicWrapper.conicGradientFill = conic

    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    program.landscapeVideoLayerInternalIds = [20, 21, 22, 23]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    definition.videoComponents = [solidWrapper, linearWrapper, radialWrapper, conicWrapper]

    let graph = try WorkspaceV4RenderGraph(
      definition: definition, preferences: .init(), programInternalID: 7, role: .landscape)

    #expect(graph.composite.steps.map(\.name) == ["v4-20", "v4-21", "v4-22", "v4-23"])
    #expect(
      graph.composite.steps.map { step in
        switch step.component {
        case .fillSolidColor: "solid"
        case .fillLinearGradient: "linear"
        case .fillRadialGradient: "radial"
        case .fillConicGradient: "conic"
        default: "other"
        }
      } == ["solid", "linear", "radial", "conic"])
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
