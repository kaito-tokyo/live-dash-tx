// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

/// Compatibility-only aggregate retained for non-Workspace Program editor records.
@available(*, deprecated, message: "Use the V4 protobuf WorkspaceDefinitionV4.")
public struct LegacyWorkspaceDefinition: Codable, Equatable, Sendable {
  /// Groups local backup generations that belong to the same Workspace lineage.
  ///
  /// Copies may intentionally retain this value. Runtime code must not treat it
  /// as a unique document or session identifier.
  public var lineageID: UUID
  public var name: String
  public var programs: [SavedProgramDefinitionRecord]
  public var inputDevices: [WorkspaceInputDeviceRecord]
  public var audioChannels: [ProgramAudioChannel]
  public var videoComponents: [WorkspaceVideoComponentRecord]
  public var outputConfiguration: WorkspaceOutputConfiguration

  public static func == (lhs: LegacyWorkspaceDefinition, rhs: LegacyWorkspaceDefinition) -> Bool {
    lhs.lineageID == rhs.lineageID && lhs.name == rhs.name && lhs.programs == rhs.programs
      && lhs.inputDevices == rhs.inputDevices
      && lhs.audioChannels == rhs.audioChannels
      && lhs.videoComponents == rhs.videoComponents
      && lhs.outputConfiguration == rhs.outputConfiguration
  }

  enum CodingKeys: String, CodingKey {
    case lineageID
    case name
    case programs
    case inputDevices
    case audioChannels
    case videoComponents
    case outputConfiguration
  }

  public init(
    lineageID: UUID = UUID(),
    name: String = "Untitled Workspace",
    programs: [SavedProgramDefinitionRecord] = [],
    inputDevices: [WorkspaceInputDeviceRecord] = [],
    audioChannels: [ProgramAudioChannel] = [],
    videoComponents: [WorkspaceVideoComponentRecord] = [],
    outputConfiguration: WorkspaceOutputConfiguration = WorkspaceOutputConfiguration()
  ) {
    self.lineageID = lineageID
    self.name = name
    self.programs = programs
    self.inputDevices = inputDevices
    self.audioChannels = audioChannels
    self.videoComponents = videoComponents
    self.outputConfiguration = outputConfiguration
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    lineageID = try container.decodeIfPresent(UUID.self, forKey: .lineageID) ?? UUID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Workspace"
    programs =
      try container.decodeIfPresent([SavedProgramDefinitionRecord].self, forKey: .programs) ?? []
    inputDevices =
      try container.decodeIfPresent([WorkspaceInputDeviceRecord].self, forKey: .inputDevices) ?? []
    audioChannels =
      try container.decodeIfPresent([ProgramAudioChannel].self, forKey: .audioChannels) ?? []
    videoComponents =
      try container.decodeIfPresent([WorkspaceVideoComponentRecord].self, forKey: .videoComponents)
      ?? []
    outputConfiguration =
      try container.decodeIfPresent(
        WorkspaceOutputConfiguration.self,
        forKey: .outputConfiguration
      ) ?? WorkspaceOutputConfiguration()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(lineageID, forKey: .lineageID)
    try container.encode(name, forKey: .name)
    try container.encode(programs, forKey: .programs)
    try container.encode(inputDevices, forKey: .inputDevices)
    try container.encode(audioChannels, forKey: .audioChannels)
    try container.encode(videoComponents, forKey: .videoComponents)
    try container.encode(outputConfiguration, forKey: .outputConfiguration)
  }
}

public enum WorkspaceOutputProfileID: String, Codable, CaseIterable, Sendable {
  case sdrLandscape1080p60 = "sdr-landscape-1080p60"
  case sdrPortrait1080p60 = "sdr-portrait-1080p60"

  /// Source compatibility for code that still names the original landscape preset.
  public static let sdr1080p60 = Self.sdrLandscape1080p60
}

public struct WorkspaceOutputConfiguration: Codable, Equatable, Sendable {
  public static let sdr1080p60VideoBitRate = 6_000_000
  /// The Canvas preset that selects the output encoding contract.
  public var profileID: WorkspaceOutputProfileID?
  public var canvasWidth: Int
  public var canvasHeight: Int
  public var frameRate: Int
  public var videoBitRate: Int
  public var portraitVideoBitRate: Int
  /// The Workspace Video Input Device that supplies output PTS. `nil` uses the host clock.
  public var videoPTSMasterInputDeviceID: String?

  public init(
    profileID: WorkspaceOutputProfileID? = .sdrLandscape1080p60,
    canvasWidth: Int = 1_920,
    canvasHeight: Int = 1_080,
    frameRate: Int = 60,
    videoBitRate: Int = 6_000_000,
    portraitVideoBitRate: Int = 6_000_000,
    videoPTSMasterInputDeviceID: String? = nil
  ) {
    self.profileID = profileID
    self.canvasWidth = canvasWidth
    self.canvasHeight = canvasHeight
    self.frameRate = frameRate
    self.videoBitRate = videoBitRate
    self.portraitVideoBitRate = portraitVideoBitRate
    self.videoPTSMasterInputDeviceID = videoPTSMasterInputDeviceID
  }

  public var isSupportedOutputProfile: Bool {
    profileID == .sdrLandscape1080p60
      && canvasWidth == 1_920
      && canvasHeight == 1_080
      && frameRate == 60
      && videoBitRate > 0
      && portraitVideoBitRate > 0
  }

  private enum CodingKeys: String, CodingKey {
    case profileID, canvasWidth, canvasHeight, frameRate, videoBitRate, portraitVideoBitRate,
      videoPTSMasterInputDeviceID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    canvasWidth = try container.decodeIfPresent(Int.self, forKey: .canvasWidth) ?? 1_920
    canvasHeight = try container.decodeIfPresent(Int.self, forKey: .canvasHeight) ?? 1_080
    frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? 60
    videoBitRate = try container.decodeIfPresent(Int.self, forKey: .videoBitRate) ?? 6_000_000
    portraitVideoBitRate =
      try container.decodeIfPresent(Int.self, forKey: .portraitVideoBitRate) ?? 6_000_000
    videoPTSMasterInputDeviceID = try container.decodeIfPresent(
      String.self, forKey: .videoPTSMasterInputDeviceID
    )
    profileID = try container.decodeIfPresent(WorkspaceOutputProfileID.self, forKey: .profileID)
  }

  public func normalizedForOutputPreset() -> WorkspaceOutputConfiguration? {
    guard isSupportedOutputProfile else { return nil }
    return self
  }

  public static let sdr1080p60 = WorkspaceOutputConfiguration(
    profileID: .sdr1080p60,
    canvasWidth: 1_920,
    canvasHeight: 1_080,
    frameRate: 60, videoBitRate: sdr1080p60VideoBitRate
  )
}

public struct WorkspaceVideoComponentRecord: Codable, Equatable, Sendable, Identifiable {
  public var name: String
  public var component: ProgramComponent

  public var id: String { name }

  public init(
    name: String,
    inputDeviceID: String? = nil,
    sourceCropTop: Float = 0,
    sourceCropRight: Float = 0,
    sourceCropBottom: Float = 0,
    sourceCropLeft: Float = 0,
    removesBackground: Bool = false
  ) {
    self.name = name
    self.component = .inputCameraDevice(
      InputDeviceComponent(
        inputDeviceID: inputDeviceID,
        sourceCropTop: sourceCropTop,
        sourceCropRight: sourceCropRight,
        sourceCropBottom: sourceCropBottom,
        sourceCropLeft: sourceCropLeft,
        removesBackground: removesBackground
      ))
  }

  public init(name: String, component: ProgramComponent) {
    self.name = name
    self.component = component
  }

  public var inputDeviceID: String? {
    get { inputDeviceComponent?.inputDeviceID }
    set { updateInputDeviceComponent { $0.inputDeviceID = newValue } }
  }
  public var sourceCropTop: Float {
    get { inputDeviceComponent?.sourceCropTop ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropTop = newValue } }
  }
  public var sourceCropRight: Float {
    get { inputDeviceComponent?.sourceCropRight ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropRight = newValue } }
  }
  public var sourceCropBottom: Float {
    get { inputDeviceComponent?.sourceCropBottom ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropBottom = newValue } }
  }
  public var sourceCropLeft: Float {
    get { inputDeviceComponent?.sourceCropLeft ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropLeft = newValue } }
  }
  public var removesBackground: Bool {
    get { inputDeviceComponent?.removesBackground ?? false }
    set { updateInputDeviceComponent { $0.removesBackground = newValue } }
  }

  private var inputDeviceComponent: InputDeviceComponent? {
    guard case .inputCameraDevice(let payload) = component else { return nil }
    return payload
  }

  private mutating func updateInputDeviceComponent(_ update: (inout InputDeviceComponent) -> Void) {
    guard case .inputCameraDevice(var payload) = component else { return }
    update(&payload)
    component = .inputCameraDevice(payload)
  }
}

public enum WorkspaceVideoComponentResolver {
  public static let coordinateWidth: Float = 1_920
  public static let coordinateHeight: Float = 1_080

  public static func applying(
    _ videoComponents: [WorkspaceVideoComponentRecord],
    layers: [VideoLayerPreference],
    to composite: CompositeProgramDefinition,
    coordinateWidth: Float = coordinateWidth,
    coordinateHeight: Float = coordinateHeight
  ) -> CompositeProgramDefinition {
    let existingByName = firstProgramStepsByName(composite.steps)
    let componentsByName = firstVideoComponentsByName(videoComponents)
    var resolved = composite
    resolved.steps = layers.compactMap { layer in
      guard
        var step = existingByName[layer.componentName]
          ?? componentsByName[layer.componentName].map({
            CompositeProgramStep(displayName: layer.componentName, component: $0)
          })
      else { return nil }

      if let definitionComponent = componentsByName[layer.componentName] {
        step.component = definitionComponent
      }
      switch step.component {
      case .inputCameraDevice(var payload):
        payload.destinationX = layer.destinationX
        payload.destinationY = layer.destinationY
        payload.destinationScaleX = layer.destinationScaleX
        payload.destinationScaleY = layer.destinationScaleY
        step.component = .inputCameraDevice(payload)
      case .clock(var payload):
        payload.destinationX = layer.destinationX / coordinateWidth
        payload.destinationY = layer.destinationY / coordinateHeight
        payload.destinationWidth = layer.destinationScaleX
        payload.destinationHeight = layer.destinationScaleY
        step.component = .clock(payload)
      default:
        break
      }
      return step
    }
    return resolved
  }

  public static func applying(
    _ videoComponents: [WorkspaceVideoComponentRecord],
    to composite: CompositeProgramDefinition
  ) -> CompositeProgramDefinition {
    let componentsByName = firstVideoComponentsByName(videoComponents)
    var resolved = composite
    for index in resolved.steps.indices {
      let programComponent = resolved.steps[index].component
      guard var component = componentsByName[resolved.steps[index].name] else { continue }
      if case .inputCameraDevice(var resourcePayload) = component,
        case .inputCameraDevice(let programPayload) = programComponent
      {
        resourcePayload.destinationX = programPayload.destinationX
        resourcePayload.destinationY = programPayload.destinationY
        resourcePayload.destinationScaleX = programPayload.destinationScaleX
        resourcePayload.destinationScaleY = programPayload.destinationScaleY
        component = .inputCameraDevice(resourcePayload)
      } else if case .clock(var resourcePayload) = component,
        case .clock(let programPayload) = programComponent
      {
        // Clock placement is resolved from Program Preferences into the
        // working composite. Keep it while refreshing Definition style.
        resourcePayload.destinationX = programPayload.destinationX
        resourcePayload.destinationY = programPayload.destinationY
        resourcePayload.destinationWidth = programPayload.destinationWidth
        resourcePayload.destinationHeight = programPayload.destinationHeight
        component = .clock(resourcePayload)
      }
      resolved.steps[index].component = component
    }
    return resolved
  }
}

private func firstProgramStepsByName(
  _ steps: [CompositeProgramStep]
) -> [String: CompositeProgramStep] {
  var stepsByName: [String: CompositeProgramStep] = [:]
  for step in steps where stepsByName[step.name] == nil {
    stepsByName[step.name] = step
  }
  return stepsByName
}

private func firstVideoComponentsByName(
  _ videoComponents: [WorkspaceVideoComponentRecord]
) -> [String: ProgramComponent] {
  var componentsByName: [String: ProgramComponent] = [:]
  for component in videoComponents where componentsByName[component.name] == nil {
    componentsByName[component.name] = component.component
  }
  return componentsByName
}

extension LegacyWorkspaceDefinition {
  @discardableResult
  public mutating func removeInputDevice(named name: String) -> Bool {
    guard inputDevices.contains(where: { $0.id == name }) else { return false }

    inputDevices.removeAll { $0.id == name }
    for programIndex in programs.indices {
      programs[programIndex].inputDevices.removeAll { $0.id == name }
      programs[programIndex].landscape.composite = programs[programIndex].landscape.composite
        .clearingInputDeviceReference(named: name)
      programs[programIndex].portrait.composite = programs[programIndex].portrait.composite
        .clearingInputDeviceReference(named: name)
    }
    audioChannels = audioChannels.map { $0.clearingInputDeviceReference(named: name) }
    videoComponents = videoComponents.map { $0.clearingInputDeviceReference(named: name) }
    if outputConfiguration.videoPTSMasterInputDeviceID == name {
      outputConfiguration.videoPTSMasterInputDeviceID = nil
    }
    return true
  }

  public mutating func renameInputDevice(
    from oldName: String,
    to newName: String,
    preferences: inout WorkspacePreferences
  ) throws {
    guard let index = inputDevices.firstIndex(where: { $0.name == oldName }) else {
      throw WorkspaceRenameError.resourceNotFound(oldName)
    }
    try validateRename(newName, excluding: oldName)

    var next = self
    var nextPreferences = preferences
    next.inputDevices[index].name = newName
    next.renameInputDeviceReferences(from: oldName, to: newName)
    if next.outputConfiguration.videoPTSMasterInputDeviceID == oldName {
      next.outputConfiguration.videoPTSMasterInputDeviceID = newName
    }
    nextPreferences.programPreferences.renameInputDevice(from: oldName, to: newName)
    nextPreferences.portraitProgramPreferences.renameInputDevice(from: oldName, to: newName)
    if let physicalDeviceID = nextPreferences.physicalDeviceIDsByInputDeviceID.removeValue(
      forKey: oldName)
    {
      nextPreferences.physicalDeviceIDsByInputDeviceID[newName] = physicalDeviceID
    }
    self = next
    preferences = nextPreferences
  }

  public mutating func renameVideoComponent(
    from oldName: String,
    to newName: String,
    preferences: inout WorkspacePreferences
  ) throws {
    guard let index = videoComponents.firstIndex(where: { $0.name == oldName }) else {
      throw WorkspaceRenameError.resourceNotFound(oldName)
    }
    try validateRename(newName, excluding: oldName)

    videoComponents[index].name = newName
    for programIndex in programs.indices {
      for role in ProgramCanvasRole.allCases {
        for stepIndex in programs[programIndex][role].composite.steps.indices
        where programs[programIndex][role].composite.steps[stepIndex].name == oldName {
          programs[programIndex][role].composite.steps[stepIndex].name = newName
        }
      }
    }
    preferences.programPreferences.renameVideoComponentReference(from: oldName, to: newName)
    preferences.portraitProgramPreferences.renameVideoComponentReference(from: oldName, to: newName)
  }

  public mutating func renameProgram(
    from oldName: String,
    to newName: String,
    preferences: inout WorkspacePreferences
  ) throws {
    guard let index = programs.firstIndex(where: { $0.name == oldName }) else {
      throw WorkspaceRenameError.resourceNotFound(oldName)
    }
    guard !newName.isEmpty else { throw WorkspaceRenameError.emptyName }
    guard oldName == newName || !programs.contains(where: { $0.name == newName }) else {
      throw WorkspaceRenameError.duplicateName(newName)
    }

    programs[index].name = newName
    preferences.programPreferences.renameProgramReference(from: oldName, to: newName)
    preferences.portraitProgramPreferences.renameProgramReference(from: oldName, to: newName)
    if preferences.selectedProgramName == oldName {
      preferences.selectedProgramName = newName
    }
  }

  private mutating func renameInputDeviceReferences(from oldName: String, to newName: String) {
    for programIndex in programs.indices {
      for inputIndex in programs[programIndex].inputDevices.indices
      where programs[programIndex].inputDevices[inputIndex].name == oldName {
        programs[programIndex].inputDevices[inputIndex].name = newName
      }
      programs[programIndex].landscape.composite.renameInputDevice(from: oldName, to: newName)
      programs[programIndex].portrait.composite.renameInputDevice(from: oldName, to: newName)
    }
    for channelIndex in audioChannels.indices {
      if case .inputAudioDevice(var component) = audioChannels[channelIndex].component,
        component.inputDeviceID == oldName
      {
        component.inputDeviceID = newName
        audioChannels[channelIndex].component = .inputAudioDevice(component)
      }
    }
    for componentIndex in videoComponents.indices {
      guard case .inputCameraDevice(var component) = videoComponents[componentIndex].component,
        component.inputDeviceID == oldName
      else { continue }
      component.inputDeviceID = newName
      videoComponents[componentIndex].component = .inputCameraDevice(component)
    }
  }

  private func validateRename(_ newName: String, excluding oldName: String) throws {
    guard !newName.isEmpty else { throw WorkspaceRenameError.emptyName }
    let existingNames = Set(
      inputDevices.filter { $0.id != oldName }.map(\.name)
        + videoComponents.filter { $0.id != oldName }.map(\.name)
        + []
    )
    guard !existingNames.contains(newName) else {
      throw WorkspaceRenameError.duplicateName(newName)
    }
  }
}

extension CompositeProgramDefinition {
  fileprivate func clearingInputDeviceReference(named name: String) -> Self {
    var updated = self
    updated.audioChannels.removeAll { channel in
      guard case .inputAudioDevice(let payload) = channel.component else { return false }
      return payload.inputDeviceID == name
    }
    updated.steps.removeAll { step in
      guard case .inputCameraDevice(let payload) = step.component else { return false }
      return payload.inputDeviceID == name
    }
    return updated
  }
}

extension ProgramAudioChannel {
  fileprivate func clearingInputDeviceReference(named name: String) -> Self {
    guard case .inputAudioDevice(var payload) = component,
      payload.inputDeviceID == name
    else { return self }
    payload.inputDeviceID = nil
    return ProgramAudioChannel(id: id, component: .inputAudioDevice(payload))
  }
}

extension WorkspaceVideoComponentRecord {
  fileprivate func clearingInputDeviceReference(named name: String) -> Self {
    var updated = self
    guard updated.inputDeviceID == name else { return updated }
    updated.inputDeviceID = nil
    return updated
  }
}

public enum WorkspaceRenameError: Error, Equatable, LocalizedError {
  case emptyName
  case duplicateName(String)
  case resourceNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .emptyName:
      "Name cannot be empty."
    case .duplicateName(let name):
      "A Workspace resource named '\(name)' already exists."
    case .resourceNotFound(let name):
      "Workspace resource '\(name)' was not found."
    }
  }
}

public typealias WorkspaceInputDeviceRecord = ProgramInputDeviceRecord
public typealias WorkspaceInputDeviceKind = ProgramInputDeviceKind
public typealias WorkspaceInputDeviceBackgroundRemovalPolicy =
  ProgramInputDeviceBackgroundRemovalPolicy
public typealias WorkspaceInputDeviceColorRangePolicy = ProgramInputDeviceColorRangePolicy
