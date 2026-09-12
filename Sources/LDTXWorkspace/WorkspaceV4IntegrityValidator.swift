// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Validates the internal-ID references in one V4 Workspace definition.
public enum WorkspaceV4IntegrityValidator {
  public static let minimumVisionIntervalSeconds = 0.1

  public static func validate(_ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4) throws {
    try validateCanvasConfiguration(definition.canvasConfiguration)
    let inputIDs = try definition.inputDevices.map { try inputDeviceID($0) }
    let videoInputIDs = try definition.inputDevices.compactMap { try videoInputDeviceID($0) }
    let componentIDs = try definition.videoComponents.map { try videoComponentID($0) }
    let programIDs = definition.programs.map(\.internalID)
    let visionIDs = try definition.visions.map { try visionID($0) }
    let allIDs = inputIDs + componentIDs + programIDs + visionIDs
    guard allIDs.allSatisfy(isValidInternalID) else {
      throw WorkspaceV4IntegrityError.invalidInternalID
    }
    guard Set(allIDs).count == allIDs.count else {
      throw WorkspaceV4IntegrityError.duplicateInternalID
    }

    let inputIDSet = Set(inputIDs)
    let videoInputIDSet = Set(videoInputIDs)
    let videoLayerIDs = videoInputIDSet.union(componentIDs)
    if definition.canvasConfiguration.hasPtsMasterVideoInputDeviceInternalID {
      let masterID = definition.canvasConfiguration.ptsMasterVideoInputDeviceInternalID
      guard videoInputIDSet.contains(masterID) else {
        throw WorkspaceV4IntegrityError.missingVideoInputDevice(masterID)
      }
    }
    for program in definition.programs {
      let landscapeLayerIDs = program.landscapeVideoLayerInternalIds
      let portraitLayerIDs = program.portraitVideoLayerInternalIds
      guard Set(landscapeLayerIDs).count == landscapeLayerIDs.count,
        Set(portraitLayerIDs).count == portraitLayerIDs.count
      else { throw WorkspaceV4IntegrityError.duplicateVideoLayer(program.internalID) }
      for id in landscapeLayerIDs + portraitLayerIDs {
        guard videoLayerIDs.contains(id) else {
          throw WorkspaceV4IntegrityError.missingVideoLayer(id)
        }
      }
    }
    for component in definition.videoComponents {
      switch component.definition {
      case .vfxSource(let source):
        guard videoInputIDSet.contains(source.inputDeviceInternalID) else {
          throw WorkspaceV4IntegrityError.missingVideoInputDevice(source.inputDeviceInternalID)
        }
        guard source.effects.allSatisfy({ $0.definition != nil }) else {
          throw WorkspaceV4IntegrityError.missingConcreteDefinition
        }
      case .radialGradientFill(let fill):
        guard fill.centerX.isFinite, fill.centerX >= 0, fill.centerX <= 1,
          fill.centerY.isFinite, fill.centerY >= 0, fill.centerY <= 1,
          fill.innerRadius.isFinite, fill.innerRadius >= 0, fill.innerRadius <= 1,
          fill.outerRadius.isFinite, fill.outerRadius <= 1,
          fill.innerRadius < fill.outerRadius
        else { throw WorkspaceV4IntegrityError.invalidRadialGradient }
        try validateColor(fill.innerColor)
        try validateColor(fill.outerColor)
      case .linearGradientFill(let fill):
        guard fill.startX.isFinite, fill.startX >= 0, fill.startX <= 1,
          fill.startY.isFinite, fill.startY >= 0, fill.startY <= 1,
          fill.endX.isFinite, fill.endX >= 0, fill.endX <= 1,
          fill.endY.isFinite, fill.endY >= 0, fill.endY <= 1,
          fill.startX != fill.endX || fill.startY != fill.endY
        else { throw WorkspaceV4IntegrityError.invalidLinearGradient }
        try validateColor(fill.startColor)
        try validateColor(fill.endColor)
      case .conicGradientFill(let fill):
        guard fill.centerX.isFinite, fill.centerX >= 0, fill.centerX <= 1,
          fill.centerY.isFinite, fill.centerY >= 0, fill.centerY <= 1,
          fill.startAngleRadians.isFinite
        else { throw WorkspaceV4IntegrityError.invalidConicGradient }
        try validateColor(fill.startColor)
        try validateColor(fill.endColor)
      case .solidColorFill(let fill):
        let color = fill.color
        guard color.red.isFinite, color.green.isFinite, color.blue.isFinite,
          color.alpha.isFinite,
          (0...1).contains(color.red), (0...1).contains(color.green),
          (0...1).contains(color.blue), (0...1).contains(color.alpha)
        else { throw WorkspaceV4IntegrityError.invalidColor }
      case .clock(let clock):
        guard clock.width.isFinite, clock.width > 0, clock.width <= 1,
          clock.height.isFinite, clock.height > 0, clock.height <= 1
        else { throw WorkspaceV4IntegrityError.invalidClockGeometry }
      default:
        break
      }
    }
    for vision in definition.visions {
      try validate(vision, inputIDs: inputIDSet, videoInputIDs: videoInputIDSet)
    }
    try validateDisplayNames(definition)
  }

  private static func validateColor(_ color: Ldtx_Workspace_V4_ExtendedSrgbColor) throws {
    guard color.red.isFinite, color.green.isFinite, color.blue.isFinite,
      color.alpha.isFinite,
      (0...1).contains(color.red), (0...1).contains(color.green),
      (0...1).contains(color.blue), (0...1).contains(color.alpha)
    else { throw WorkspaceV4IntegrityError.invalidColor }
  }

  /// Resource names are unique across the Workspace sidebar.
  private static func validateDisplayNames(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) throws {
    var names = Set<String>()
    let values =
      definition.inputDevices.map { inputDeviceName($0) }
      + definition.videoComponents.map { videoComponentName($0) }
      + definition.visions.map { visionName($0) }
      + definition.programs.map(\.displayName)
    for name in values {
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw WorkspaceV4IntegrityError.emptyDisplayName
      }
      guard names.insert(name).inserted else {
        throw WorkspaceV4IntegrityError.duplicateDisplayName(name)
      }
    }
  }

  private static func inputDeviceName(_ wrapper: Ldtx_Workspace_V4_InputDeviceWrapper) -> String {
    switch wrapper.definition {
    case .videoDevice(let device): device.displayName
    case .audioDevice(let device): device.displayName
    case nil: ""
    }
  }

  private static func videoComponentName(
    _ wrapper: Ldtx_Workspace_V4_VideoComponentWrapper
  ) -> String {
    switch wrapper.definition {
    case .solidColorFill(let component): component.displayName
    case .linearGradientFill(let component): component.displayName
    case .radialGradientFill(let component): component.displayName
    case .conicGradientFill(let component): component.displayName
    case .vfxSource(let component): component.displayName
    case .clock(let component): component.displayName
    case .testPattern(let component): component.displayName
    case nil: ""
    }
  }

  private static func visionName(_ wrapper: Ldtx_Workspace_V4_VisionWrapper) -> String {
    switch wrapper.definition {
    case .ocrVision(let vision): vision.displayName
    case nil: ""
    }
  }

  /// Validates both documents before they are persisted or used by a runtime.
  public static func validate(_ workspace: WorkspaceV4Package) throws {
    let definition = workspace.definition.definition
    try validate(definition)

    let programIDs = Set(definition.programs.map(\.internalID))
    let audioInputIDs = Set(
      definition.inputDevices.compactMap { wrapper -> UInt64? in
        guard case .audioDevice(let device)? = wrapper.definition else { return nil }
        return device.internalID
      })
    for (programID, preference) in workspace.preferences.preferences.programPreferences {
      guard programIDs.contains(programID) else {
        throw WorkspaceV4IntegrityError.missingProgram(programID)
      }
      guard let program = definition.programs.first(where: { $0.internalID == programID }) else {
        throw WorkspaceV4IntegrityError.missingProgram(programID)
      }
      try validate(
        preference,
        audioInputIDs: audioInputIDs,
        landscapeVideoLayerIDs: Set(program.landscapeVideoLayerInternalIds),
        portraitVideoLayerIDs: Set(program.portraitVideoLayerInternalIds)
      )
    }
  }

  public static func inputDeviceID(_ wrapper: Ldtx_Workspace_V4_InputDeviceWrapper) throws -> UInt64
  {
    switch wrapper.definition {
    case .videoDevice(let device): device.internalID
    case .audioDevice(let device): device.internalID
    case nil: throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
  }

  public static func videoInputDeviceID(
    _ wrapper: Ldtx_Workspace_V4_InputDeviceWrapper
  ) throws -> UInt64? {
    switch wrapper.definition {
    case .videoDevice(let device): device.internalID
    case .audioDevice: nil
    case nil: throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
  }

  public static func videoComponentID(_ wrapper: Ldtx_Workspace_V4_VideoComponentWrapper) throws
    -> UInt64
  {
    switch wrapper.definition {
    case .solidColorFill(let component): component.internalID
    case .linearGradientFill(let component): component.internalID
    case .radialGradientFill(let component): component.internalID
    case .conicGradientFill(let component): component.internalID
    case .vfxSource(let component): component.internalID
    case .clock(let component): component.internalID
    case .testPattern(let component): component.internalID
    case nil: throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
  }

  public static func visionID(_ wrapper: Ldtx_Workspace_V4_VisionWrapper) throws -> UInt64 {
    switch wrapper.definition {
    case .ocrVision(let vision): vision.internalID
    case nil: throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
  }

  private static func isValidInternalID(_ value: UInt64) -> Bool {
    value != 0 && value & (UInt64(1) << 63) == 0
  }

  private static func validate(
    _ wrapper: Ldtx_Workspace_V4_VisionWrapper,
    inputIDs: Set<UInt64>,
    videoInputIDs: Set<UInt64>
  ) throws {
    guard case .ocrVision(let vision)? = wrapper.definition else {
      throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
    guard case .inputDeviceInternalID(let inputID)? = vision.source else {
      throw WorkspaceV4IntegrityError.missingVisionInputDevice
    }
    guard inputIDs.contains(inputID) else {
      throw WorkspaceV4IntegrityError.missingInputDevice(inputID)
    }
    guard videoInputIDs.contains(inputID) else {
      throw WorkspaceV4IntegrityError.missingVideoInputDevice(inputID)
    }
    for trigger in vision.triggers {
      guard case .intervalTrigger(let interval)? = trigger.definition else {
        throw WorkspaceV4IntegrityError.missingConcreteDefinition
      }
      guard interval.intervalSeconds.isFinite,
        interval.intervalSeconds >= minimumVisionIntervalSeconds
      else {
        throw WorkspaceV4IntegrityError.invalidVisionInterval
      }
    }
    if vision.hasRegionOfInterest {
      let region = vision.regionOfInterest
      guard region.x >= 0, region.x <= 1,
        region.y >= 0, region.y <= 1,
        region.width > 0, region.width <= 1,
        region.height > 0, region.height <= 1,
        region.x + region.width <= 1,
        region.y + region.height <= 1
      else { throw WorkspaceV4IntegrityError.invalidVisionRegionOfInterest }
    }
    if vision.hasMinimumTextHeight {
      guard vision.minimumTextHeight >= 0, vision.minimumTextHeight <= 1 else {
        throw WorkspaceV4IntegrityError.invalidMinimumTextHeight
      }
    }
  }

  private static func validateCanvasConfiguration(
    _ canvas: Ldtx_Workspace_V4_CanvasConfiguration
  ) throws {
    guard canvas.frameRate == 0 || (1...240).contains(canvas.frameRate) else {
      throw WorkspaceV4IntegrityError.unsupportedFrameRate(canvas.frameRate)
    }
    if !canvas.landscapeProfileID.isEmpty,
      canvas.landscapeProfileID != "sdr-landscape-1080p60"
    {
      throw WorkspaceV4IntegrityError.unsupportedOutputProfile(canvas.landscapeProfileID)
    }
    if !canvas.portraitProfileID.isEmpty,
      canvas.portraitProfileID != "sdr-portrait-1080p60"
    {
      throw WorkspaceV4IntegrityError.unsupportedOutputProfile(canvas.portraitProfileID)
    }
  }

  private static func validate(
    _ preference: Ldtx_Workspace_V4_ProgramPreference,
    audioInputIDs: Set<UInt64>,
    landscapeVideoLayerIDs: Set<UInt64>,
    portraitVideoLayerIDs: Set<UInt64>
  ) throws {
    let audioPreferenceIDs =
      Array(preference.landscapeAudioChannelGains.keys)
      + preference.landscapeAudioChannelMuted.keys
      + preference.portraitAudioChannelGains.keys
      + preference.portraitAudioChannelMuted.keys
    for id in audioPreferenceIDs {
      guard audioInputIDs.contains(id) else {
        throw WorkspaceV4IntegrityError.missingAudioInputDevice(id)
      }
    }
    guard preference.landscapeAudioChannelGains.values.allSatisfy(\.isFinite),
      preference.portraitAudioChannelGains.values.allSatisfy(\.isFinite)
    else { throw WorkspaceV4IntegrityError.invalidColor }
    for id in Array(preference.landscapeVideoLayerTransforms.keys)
      + preference.landscapeVideoLayerMuted.keys
    {
      guard landscapeVideoLayerIDs.contains(id) else {
        throw WorkspaceV4IntegrityError.missingVideoLayer(id)
      }
    }
    for id in Array(preference.portraitVideoLayerTransforms.keys)
      + preference.portraitVideoLayerMuted.keys
    {
      guard portraitVideoLayerIDs.contains(id) else {
        throw WorkspaceV4IntegrityError.missingVideoLayer(id)
      }
    }
    for transform in Array(preference.landscapeVideoLayerTransforms.values)
      + Array(preference.portraitVideoLayerTransforms.values)
    {
      guard transform.translationX.isFinite, (0...1).contains(transform.translationX),
        transform.translationY.isFinite, (0...1).contains(transform.translationY),
        transform.scaleX.isFinite, transform.scaleX >= 0,
        transform.scaleY.isFinite, transform.scaleY >= 0,
        transform.topInset.isFinite, (0...1).contains(transform.topInset),
        transform.rightInset.isFinite, (0...1).contains(transform.rightInset),
        transform.bottomInset.isFinite, (0...1).contains(transform.bottomInset),
        transform.leftInset.isFinite, (0...1).contains(transform.leftInset)
      else { throw WorkspaceV4IntegrityError.invalidBasicTransform }
    }
  }
}

public enum WorkspaceV4IntegrityError: Error, Equatable, Sendable {
  case missingConcreteDefinition
  case invalidInternalID
  case duplicateInternalID
  case duplicateDisplayName(String)
  case emptyDisplayName
  case duplicateVideoLayer(UInt64)
  case missingVideoLayer(UInt64)
  case missingProgram(UInt64)
  case missingInputDevice(UInt64)
  case missingVideoInputDevice(UInt64)
  case missingAudioInputDevice(UInt64)
  case missingVisionInputDevice
  case invalidVisionInterval
  case invalidVisionRegionOfInterest
  case invalidMinimumTextHeight
  case unsupportedOutputProfile(String)
  case unsupportedFrameRate(UInt32)
  case invalidRadialGradient
  case invalidBasicTransform
  case invalidLinearGradient
  case invalidConicGradient
  case invalidClockGeometry
  case invalidColor
}
