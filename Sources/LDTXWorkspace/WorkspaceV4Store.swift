// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Observation

/// Generates Workspace-local IDs using the Version 4 bit allocation.
@MainActor
public final class WorkspaceInternalIDGenerator {
  private var randomNumberGenerator = SystemRandomNumberGenerator()

  public init() {}

  /// Returns an ID with a zero sign bit, Unix milliseconds in bits 62...15,
  /// and uniformly random data in bits 14...0.
  public func next(now: Date = Date()) -> UInt64 {
    let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
    let timestamp = (milliseconds & 0x0000_FFFF_FFFF_FFFF) << 15
    let random = UInt64.random(in: 0...0x7fff, using: &randomNumberGenerator)
    return timestamp | random
  }
}

/// The Version 4 Workspace state that is authoritative while an app session is
/// open. It stores generated protobuf messages directly and never converts to
/// Version 3 models.
@MainActor
@Observable
public final class WorkspaceV4Store {
  public static let defaultOpaqueColor = Ldtx_Workspace_V4_ExtendedSrgbColor.with {
    $0.red = 1
    $0.green = 1
    $0.blue = 1
    $0.alpha = 1
  }
  public private(set) var workspace: WorkspaceV4Package
  private var lastSavedDefinitionData: Data
  private var lastSavedPreferencesData: Data
  private let internalIDGenerator: WorkspaceInternalIDGenerator

  public init(
    workspace: WorkspaceV4Package,
    internalIDGenerator: WorkspaceInternalIDGenerator = WorkspaceInternalIDGenerator()
  ) throws {
    self.workspace = workspace
    self.internalIDGenerator = internalIDGenerator
    lastSavedDefinitionData = try WorkspaceV4PersistenceCodec.encodeDefinition(workspace.definition)
    lastSavedPreferencesData = try WorkspaceV4PersistenceCodec.encodePreferences(
      workspace.preferences)
  }

  public convenience init(cleanNamed displayName: String) throws {
    let definition = WorkspaceV4DefinitionDocument(
      externalID: WorkspaceV4PersistenceCodec.makeExternalID(),
      definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
        $0.displayName = displayName
        $0.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
        $0.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
        $0.canvasConfiguration.frameRate = 60
        $0.canvasConfiguration.landscapeVideoBitRate = 6_000_000
        $0.canvasConfiguration.portraitVideoBitRate = 6_000_000
        $0.outputConfiguration.youtubeIngestMode = .landscapeRtmps
      }
    )
    let preferences = WorkspaceV4PreferencesDocument(
      externalID: WorkspaceV4PersistenceCodec.makeExternalID(),
      preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4()
    )
    try self.init(workspace: WorkspaceV4Package(definition: definition, preferences: preferences))
  }

  public var isDirty: Bool {
    guard
      let definitionData = try? WorkspaceV4PersistenceCodec.encodeDefinition(workspace.definition),
      let preferencesData = try? WorkspaceV4PersistenceCodec.encodePreferences(
        workspace.preferences)
    else { return true }
    return definitionData != lastSavedDefinitionData || preferencesData != lastSavedPreferencesData
  }

  public func editDefinition(
    _ mutation: (inout Ldtx_Workspace_V4_WorkspaceDefinitionV4) -> Void
  ) {
    mutation(&workspace.definition.definition)
  }

  public func editPreferences(
    _ mutation: (inout Ldtx_Workspace_V4_WorkspacePreferencesV4) -> Void
  ) {
    mutation(&workspace.preferences.preferences)
  }

  @discardableResult
  public func addVideoInputDevice(displayName: String) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var device = Ldtx_Workspace_V4_VideoInputDevice()
    device.internalID = internalID
    device.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
    wrapper.videoDevice = device
    var definition = workspace.definition.definition
    definition.inputDevices.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addAudioInputDevice(displayName: String) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var device = Ldtx_Workspace_V4_AudioInputDevice()
    device.internalID = internalID
    device.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
    wrapper.audioDevice = device
    var definition = workspace.definition.definition
    definition.inputDevices.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addProgram(displayName: String) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = internalID
    program.displayName = displayName
    var definition = workspace.definition.definition
    definition.programs.append(program)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addVFXSource(
    displayName: String,
    inputDeviceInternalID: UInt64
  ) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_VfxSourceComponent()
    component.internalID = internalID
    component.displayName = displayName
    component.inputDeviceInternalID = inputDeviceInternalID
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.vfxSource = component
    var definition = workspace.definition.definition
    definition.videoComponents.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addSolidColorFill(
    displayName: String,
    color: Ldtx_Workspace_V4_ExtendedSrgbColor = .init()
  ) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_FillSolidColorComponent()
    component.internalID = internalID
    component.displayName = displayName
    component.color = color
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.solidColorFill = component
    var definition = workspace.definition.definition
    definition.videoComponents.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addLinearGradientFill(
    displayName: String,
    startColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceV4Store.defaultOpaqueColor,
    endColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceV4Store.defaultOpaqueColor
  ) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_FillLinearGradientComponent()
    component.internalID = internalID
    component.displayName = displayName
    component.startX = 0
    component.startY = 0
    component.startColor = startColor
    component.endX = 1
    component.endY = 1
    component.endColor = endColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.linearGradientFill = component
    var definition = workspace.definition.definition
    definition.videoComponents.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addRadialGradientFill(
    displayName: String,
    innerColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceV4Store.defaultOpaqueColor,
    outerColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceV4Store.defaultOpaqueColor
  ) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_FillRadialGradientComponent()
    component.internalID = internalID
    component.displayName = displayName
    component.centerX = 0.5
    component.centerY = 0.5
    component.innerRadius = 0
    component.outerRadius = 0.5
    component.innerColor = innerColor
    component.outerColor = outerColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.radialGradientFill = component
    var definition = workspace.definition.definition
    definition.videoComponents.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addConicGradientFill(
    displayName: String,
    startColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceV4Store.defaultOpaqueColor,
    endColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceV4Store.defaultOpaqueColor
  ) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_FillConicGradientComponent()
    component.internalID = internalID
    component.displayName = displayName
    component.centerX = 0.5
    component.centerY = 0.5
    component.startColor = startColor
    component.endColor = endColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.conicGradientFill = component
    var definition = workspace.definition.definition
    definition.videoComponents.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addClock(displayName: String) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_ClockComponent()
    component.internalID = internalID
    component.displayName = displayName
    component.width = 320 / 1_920
    component.height = 80 / 1_080
    component.foregroundColor = WorkspaceV4Store.defaultOpaqueColor
    component.backgroundColor = Ldtx_Workspace_V4_ExtendedSrgbColor.with {
      $0.alpha = 0.65
    }
    component.showsSeconds = true
    component.uses24HourTime = true
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.clock = component
    var definition = workspace.definition.definition
    definition.videoComponents.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addTestPattern(displayName: String) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_TestPatternComponent()
    component.internalID = internalID
    component.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.testPattern = component
    var definition = workspace.definition.definition
    definition.videoComponents.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addOcrVision(
    displayName: String,
    inputDeviceInternalID: UInt64,
    intervalSeconds: Double = 5
  ) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
    trigger.intervalSeconds = intervalSeconds
    var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
    triggerWrapper.intervalTrigger = trigger
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = internalID
    vision.displayName = displayName
    vision.inputDeviceInternalID = inputDeviceInternalID
    vision.triggers = [triggerWrapper]
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
    var definition = workspace.definition.definition
    definition.visions.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  public func removeVideoLayer(internalID: UInt64) throws {
    if workspace.definition.definition.inputDevices.contains(where: {
      (try? WorkspaceV4IntegrityValidator.inputDeviceID($0)) == internalID
    }) {
      try removeInputDevice(internalID: internalID)
      return
    }
    if workspace.definition.definition.videoComponents.contains(where: {
      (try? WorkspaceV4IntegrityValidator.videoComponentID($0)) == internalID
    }) {
      try removeVideoComponent(internalID: internalID)
      return
    }
    throw WorkspaceV4StoreError.missingVideoLayer(internalID)
  }

  public func removeInputDevice(internalID: UInt64) throws {
    var definition = workspace.definition.definition
    definition.inputDevices.removeAll {
      (try? WorkspaceV4IntegrityValidator.inputDeviceID($0)) == internalID
    }
    guard definition.inputDevices.count != workspace.definition.definition.inputDevices.count
    else { throw WorkspaceV4StoreError.missingVideoLayer(internalID) }
    try removeReferences(to: internalID, from: &definition)
    let removedVFXIDs = Set(
      definition.videoComponents.compactMap { wrapper -> UInt64? in
        guard case .vfxSource(let source)? = wrapper.definition,
          source.inputDeviceInternalID == internalID
        else { return nil }
        return source.internalID
      })
    definition.videoComponents.removeAll { wrapper in
      guard case .vfxSource(let source)? = wrapper.definition else { return false }
      return source.inputDeviceInternalID == internalID
    }
    for vfxID in removedVFXIDs { try removeReferences(to: vfxID, from: &definition) }
    definition.visions.removeAll { wrapper in
      guard case .ocrVision(let vision)? = wrapper.definition,
        case .inputDeviceInternalID(let sourceID)? = vision.source
      else { return false }
      return sourceID == internalID
    }
    if definition.canvasConfiguration.ptsMasterVideoInputDeviceInternalID == internalID {
      definition.canvasConfiguration.clearPtsMasterVideoInputDeviceInternalID()
    }
    var candidate = workspace
    candidate.definition.definition = definition
    removePreferences(for: internalID, from: &candidate.preferences.preferences)
    for vfxID in removedVFXIDs {
      removePreferences(for: vfxID, from: &candidate.preferences.preferences)
    }
    try WorkspaceV4IntegrityValidator.validate(candidate)
    workspace = candidate
  }

  public func removeVideoComponent(internalID: UInt64) throws {
    var definition = workspace.definition.definition
    definition.videoComponents.removeAll {
      (try? WorkspaceV4IntegrityValidator.videoComponentID($0)) == internalID
    }
    guard definition.videoComponents.count != workspace.definition.definition.videoComponents.count
    else { throw WorkspaceV4StoreError.missingVideoLayer(internalID) }
    try removeReferences(to: internalID, from: &definition)
    var candidate = workspace
    candidate.definition.definition = definition
    removePreferences(for: internalID, from: &candidate.preferences.preferences)
    try WorkspaceV4IntegrityValidator.validate(candidate)
    workspace = candidate
  }

  public func removeVision(internalID: UInt64) throws {
    var candidate = workspace
    candidate.definition.definition.visions.removeAll {
      (try? WorkspaceV4IntegrityValidator.visionID($0)) == internalID
    }
    guard
      candidate.definition.definition.visions.count != workspace.definition.definition.visions.count
    else { throw WorkspaceV4StoreError.missingVision(internalID) }
    try WorkspaceV4IntegrityValidator.validate(candidate)
    workspace = candidate
  }

  public func removeProgram(internalID: UInt64) throws {
    var candidate = workspace
    candidate.definition.definition.programs.removeAll { $0.internalID == internalID }
    guard
      candidate.definition.definition.programs.count
        != workspace.definition.definition.programs.count
    else { throw WorkspaceV4StoreError.missingProgram(internalID) }
    candidate.preferences.preferences.programPreferences.removeValue(forKey: internalID)
    try WorkspaceV4IntegrityValidator.validate(candidate)
    workspace = candidate
  }

  private func removeReferences(
    to internalID: UInt64,
    from definition: inout Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) throws {
    for index in definition.programs.indices {
      definition.programs[index].landscapeVideoLayerInternalIds.removeAll { $0 == internalID }
      definition.programs[index].portraitVideoLayerInternalIds.removeAll { $0 == internalID }
    }
  }

  private func removePreferences(
    for internalID: UInt64,
    from preferences: inout Ldtx_Workspace_V4_WorkspacePreferencesV4
  ) {
    for programID in preferences.programPreferences.keys {
      guard var preference = preferences.programPreferences[programID] else { continue }
      preference.landscapeAudioChannelGains.removeValue(forKey: internalID)
      preference.landscapeAudioChannelMuted.removeValue(forKey: internalID)
      preference.portraitAudioChannelGains.removeValue(forKey: internalID)
      preference.portraitAudioChannelMuted.removeValue(forKey: internalID)
      preference.landscapeVideoLayerTransforms.removeValue(forKey: internalID)
      preference.landscapeVideoLayerMuted.removeValue(forKey: internalID)
      preference.portraitVideoLayerTransforms.removeValue(forKey: internalID)
      preference.portraitVideoLayerMuted.removeValue(forKey: internalID)
      preferences.programPreferences[programID] = preference
    }
  }

  public func setVideoLayerOrder(
    _ layerInternalIDs: [UInt64],
    forProgramInternalID programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    var definition = workspace.definition.definition
    guard
      let index = definition.programs.firstIndex(
        where: { $0.internalID == programInternalID })
    else { throw WorkspaceV4StoreError.missingProgram(programInternalID) }
    switch role {
    case .landscape:
      definition.programs[index].landscapeVideoLayerInternalIds = layerInternalIDs
    case .portrait:
      definition.programs[index].portraitVideoLayerInternalIds = layerInternalIDs
    }
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
  }

  public func setBasicTransform(
    _ transform: Ldtx_Workspace_V4_BasicTransform,
    forVideoLayerInternalID layerInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    guard
      workspace.definition.definition.programs.contains(where: {
        $0.internalID == programInternalID
      })
    else { throw WorkspaceV4StoreError.missingProgram(programInternalID) }
    var candidate = workspace
    var preference =
      candidate.preferences.preferences.programPreferences[programInternalID] ?? .init()
    switch role {
    case .landscape: preference.landscapeVideoLayerTransforms[layerInternalID] = transform
    case .portrait: preference.portraitVideoLayerTransforms[layerInternalID] = transform
    }
    candidate.preferences.preferences.programPreferences[programInternalID] = preference
    try WorkspaceV4IntegrityValidator.validate(candidate)
    workspace = candidate
  }

  public func setAudioChannelGain(
    _ gain: Double,
    forAudioInputDeviceInternalID inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try editProgramPreference(programInternalID) { preference in
      switch role {
      case .landscape: preference.landscapeAudioChannelGains[inputDeviceInternalID] = gain
      case .portrait: preference.portraitAudioChannelGains[inputDeviceInternalID] = gain
      }
    }
  }

  public func setAudioChannelMuted(
    _ muted: Bool,
    forAudioInputDeviceInternalID inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try editProgramPreference(programInternalID) { preference in
      switch role {
      case .landscape: preference.landscapeAudioChannelMuted[inputDeviceInternalID] = muted
      case .portrait: preference.portraitAudioChannelMuted[inputDeviceInternalID] = muted
      }
    }
  }

  public func setMasterVolume(
    _ volume: Double,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try editProgramPreference(programInternalID) { preference in
      switch role {
      case .landscape: preference.landscapeMasterVolume = volume
      case .portrait: preference.portraitMasterVolume = volume
      }
    }
  }

  public func setMonitorVolume(_ volume: Double) throws {
    var candidate = workspace
    candidate.preferences.preferences.monitorVolume = volume
    try WorkspaceV4IntegrityValidator.validate(candidate)
    workspace = candidate
  }

  private func editProgramPreference(
    _ programInternalID: UInt64,
    _ mutation: (inout Ldtx_Workspace_V4_ProgramPreference) -> Void
  ) throws {
    guard
      workspace.definition.definition.programs.contains(where: {
        $0.internalID == programInternalID
      })
    else { throw WorkspaceV4StoreError.missingProgram(programInternalID) }
    var candidate = workspace
    var preference =
      candidate.preferences.preferences.programPreferences[programInternalID] ?? .init()
    mutation(&preference)
    candidate.preferences.preferences.programPreferences[programInternalID] = preference
    try WorkspaceV4IntegrityValidator.validate(candidate)
    workspace = candidate
  }

  /// Replaces both persisted V4 documents as one coherent runtime state.
  public func replace(with workspace: WorkspaceV4Package) {
    self.workspace = workspace
  }

  public func markSaved() throws {
    lastSavedDefinitionData = try WorkspaceV4PersistenceCodec.encodeDefinition(workspace.definition)
    lastSavedPreferencesData = try WorkspaceV4PersistenceCodec.encodePreferences(
      workspace.preferences)
  }
}

public enum WorkspaceV4StoreError: Error, Equatable, Sendable {
  case missingVideoLayer(UInt64)
  case missingProgram(UInt64)
  case missingVision(UInt64)
}
