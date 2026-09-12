// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace

/// A renderer-only projection of one V4 Program. This is derived at the
/// rendering boundary and never becomes a Version 3 Workspace model.
struct WorkspaceV4RenderGraph: Sendable {
  var composite: CompositeProgramDefinition
  var layerPreferences: [VideoLayerPreference]
  var audioPreferences: ProgramPreferences

  init(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    programInternalID: UInt64,
    role: ProgramCanvasRole,
    localState: WorkspaceLocalState = .init()
  ) throws {
    guard let program = definition.programs.first(where: { $0.internalID == programInternalID })
    else {
      throw WorkspaceV4RenderGraphError.missingProgram(programInternalID)
    }
    let layerIDs =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    let preference = preferences.programPreferences[programInternalID] ?? .init()
    let transforms =
      role == .landscape
      ? preference.landscapeVideoLayerTransforms : preference.portraitVideoLayerTransforms
    let muted =
      role == .landscape
      ? preference.landscapeVideoLayerMuted : preference.portraitVideoLayerMuted
    let components = Self.componentsByInternalID(definition)
    let inputDevices = Self.videoInputDevicesByInternalID(definition)
    let canvasWidth: Float = role == .landscape ? 1_920 : 1_080
    let canvasHeight: Float = role == .landscape ? 1_080 : 1_920
    var steps: [CompositeProgramStep] = []
    var layerPreferences: [VideoLayerPreference] = []
    for internalID in layerIDs {
      guard
        var component = components[internalID] ?? inputDevices[internalID].map(Self.inputComponent)
      else { throw WorkspaceV4RenderGraphError.missingVideoLayer(internalID) }
      let transform = transforms[internalID] ?? .init()
      let topInset = Self.unitInterval(transform.topInset, default: 0)
      let rightInset = Self.unitInterval(transform.rightInset, default: 0)
      let bottomInset = Self.unitInterval(transform.bottomInset, default: 0)
      let leftInset = Self.unitInterval(transform.leftInset, default: 0)
      let translationX = Self.unitInterval(transform.translationX, default: 0)
      let translationY = Self.unitInterval(transform.translationY, default: 0)
      let scaleX = Self.scale(transform.scaleX)
      let scaleY = Self.scale(transform.scaleY)
      let name = "v4-\(internalID)"
      if case .inputCameraDevice(var input) = component {
        input.sourceCropTop = topInset * 100
        input.sourceCropRight = rightInset * 100
        input.sourceCropBottom = bottomInset * 100
        input.sourceCropLeft = leftInset * 100
        input.destinationX = translationX * canvasWidth
        input.destinationY = translationY * canvasHeight
        input.destinationScaleX = scaleX
        input.destinationScaleY = scaleY
        component = .inputCameraDevice(input)
      }
      if case .clock(var clock) = component {
        clock.destinationX = translationX * canvasWidth
        clock.destinationY = translationY * canvasHeight
        if role == .portrait {
          clock.destinationWidth *= 1_920 / 1_080
          clock.destinationHeight *= 1_080 / 1_920
        }
        clock.destinationWidth *= scaleX
        clock.destinationHeight *= scaleY
        component = .clock(clock)
      }
      steps.append(CompositeProgramStep(id: name, component: component))
      layerPreferences.append(
        VideoLayerPreference(
          componentName: name,
          destinationX: translationX,
          destinationY: translationY,
          destinationScaleX: scaleX,
          destinationScaleY: scaleY,
          isMuted: muted[internalID] ?? false
        ))
    }
    let audioChannels = Self.audioChannels(definition)
    composite = CompositeProgramDefinition(steps: steps, audioChannels: audioChannels)
    self.layerPreferences = layerPreferences
    let audioMixRole: ProgramCanvasRole =
      role == .portrait
        && localState.synchronizesLandscapeMixToPortraitByProgramInternalID[programInternalID]
          == true
      ? .landscape : role
    var audioPreferences = ProgramPreferences(
      masterVolume: Self.linearGain(
        audioMixRole == .landscape
          ? preference.landscapeMasterVolume : preference.portraitMasterVolume))
    let gains =
      audioMixRole == .landscape
      ? preference.landscapeAudioChannelGains : preference.portraitAudioChannelGains
    let mutedAudio =
      audioMixRole == .landscape
      ? preference.landscapeAudioChannelMuted : preference.portraitAudioChannelMuted
    for channel in audioChannels {
      guard case .inputAudioDevice(let input) = channel.component,
        let id = input.inputDeviceID.flatMap({ UInt64($0.dropFirst(3)) })
      else { continue }
      audioPreferences.audioChannelGainsByName[channel.name] = Self.linearGain(gains[id] ?? 0)
      audioPreferences.audioMutedByInputDeviceName[channel.name] = mutedAudio[id] ?? false
    }
    audioPreferences.videoLayersByProgramName["v4-\(programInternalID)"] = layerPreferences
    self.audioPreferences = audioPreferences
  }

  private static func videoInputDevicesByInternalID(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) -> [UInt64: Ldtx_Workspace_V4_VideoInputDevice] {
    Dictionary(
      uniqueKeysWithValues: definition.inputDevices.compactMap {
        guard case .videoDevice(let device)? = $0.definition else { return nil }
        return (device.internalID, device)
      })
  }

  private static func componentsByInternalID(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) -> [UInt64: ProgramComponent] {
    Dictionary(
      uniqueKeysWithValues: definition.videoComponents.compactMap {
        guard let definition = $0.definition else { return nil }
        switch definition {
        case .solidColorFill(let fill):
          return (
            fill.internalID,
            .fillSolidColor(
              FillSolidColorComponent(
                red: fill.color.red, green: fill.color.green, blue: fill.color.blue,
                alpha: fill.color.alpha))
          )
        case .linearGradientFill(let fill):
          return (
            fill.internalID,
            .fillLinearGradient(
              FillLinearGradientComponent(
                startX: fill.startX, startY: fill.startY, endX: fill.endX, endY: fill.endY,
                startRed: fill.startColor.red, startGreen: fill.startColor.green,
                startBlue: fill.startColor.blue, startAlpha: fill.startColor.alpha,
                endRed: fill.endColor.red, endGreen: fill.endColor.green,
                endBlue: fill.endColor.blue, endAlpha: fill.endColor.alpha))
          )
        case .radialGradientFill(let fill):
          return (
            fill.internalID,
            .fillRadialGradient(
              FillRadialGradientComponent(
                centerX: fill.centerX, centerY: fill.centerY, innerRadius: fill.innerRadius,
                outerRadius: fill.outerRadius, innerRed: fill.innerColor.red,
                innerGreen: fill.innerColor.green, innerBlue: fill.innerColor.blue,
                innerAlpha: fill.innerColor.alpha, outerRed: fill.outerColor.red,
                outerGreen: fill.outerColor.green, outerBlue: fill.outerColor.blue,
                outerAlpha: fill.outerColor.alpha))
          )
        case .conicGradientFill(let fill):
          return (
            fill.internalID,
            .fillConicGradient(
              FillConicGradientComponent(
                centerX: fill.centerX, centerY: fill.centerY,
                startAngleRadians: fill.startAngleRadians, startRed: fill.startColor.red,
                startGreen: fill.startColor.green, startBlue: fill.startColor.blue,
                startAlpha: fill.startColor.alpha, endRed: fill.endColor.red,
                endGreen: fill.endColor.green, endBlue: fill.endColor.blue,
                endAlpha: fill.endColor.alpha))
          )
        case .vfxSource(let source):
          return (
            source.internalID,
            .inputCameraDevice(InputDeviceComponent(inputDeviceID: "v4-vfx-\(source.internalID)"))
          )
        case .clock(let clock):
          return (
            clock.internalID,
            .clock(
              ClockComponent(
                destinationWidth: clock.width, destinationHeight: clock.height,
                showsSeconds: clock.showsSeconds, uses24HourTime: clock.uses24HourTime,
                foregroundRed: clock.foregroundColor.red,
                foregroundGreen: clock.foregroundColor.green,
                foregroundBlue: clock.foregroundColor.blue,
                foregroundAlpha: clock.foregroundColor.alpha,
                backgroundRed: clock.backgroundColor.red,
                backgroundGreen: clock.backgroundColor.green,
                backgroundBlue: clock.backgroundColor.blue,
                backgroundAlpha: clock.backgroundColor.alpha,
                showsDate: clock.showsDate, usesSystemTimeZone: !clock.hasUtcOffsetMinutes,
                utcOffsetMinutes: clock.utcOffsetMinutes,
                outlines: clock.outlines.map {
                  ClockTextOutline(thickness: $0.thickness, color: colorString($0.color))
                }))
          )
        case .testPattern(let pattern): return (pattern.internalID, .testPattern)
        }
      })
  }

  private static func inputComponent(_ device: Ldtx_Workspace_V4_VideoInputDevice)
    -> ProgramComponent
  {
    inputComponent(inputDeviceInternalID: device.internalID)
  }

  private static func inputComponent(inputDeviceInternalID: UInt64) -> ProgramComponent {
    .inputCameraDevice(InputDeviceComponent(inputDeviceID: "v4-\(inputDeviceInternalID)"))
  }

  private static func audioChannels(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) -> [ProgramAudioChannel] {
    definition.inputDevices.compactMap {
      guard case .audioDevice(let device)? = $0.definition else { return nil }
      return ProgramAudioChannel(
        name: "v4-\(device.internalID)",
        component: .inputAudioDevice(
          InputAudioDeviceComponent(inputDeviceID: "v4-\(device.internalID)"))
      )
    }
  }

  private static func linearGain(_ decibels: Double) -> Double {
    ProgramPreferences.linearAudioChannelGain(fromDecibels: decibels)
  }

  private static func colorString(_ color: Ldtx_Workspace_V4_ExtendedSrgbColor) -> String {
    return String(
      format: "#%02X%02X%02X%02X", colorComponent(color.red), colorComponent(color.green),
      colorComponent(color.blue), colorComponent(color.alpha))
  }

  private static func colorComponent(_ value: Float) -> Int {
    guard value.isFinite else { return 0 }
    return Int((min(max(value, 0), 1) * 255).rounded())
  }

  private static func unitInterval(_ value: Float, default defaultValue: Float) -> Float {
    guard value.isFinite else { return defaultValue }
    return min(max(value, 0), 1)
  }

  private static func scale(_ value: Float) -> Float {
    guard value.isFinite else { return 1 }
    return value == 0 ? 1 : min(max(value, 0.01), 100)
  }
}

extension WorkspaceV4RenderGraph {
  /// Builds the runtime configuration from V4 documents and path-local device
  /// assignments. The Workspace V3 persistence model is not consulted.
  static func runtimeConfiguration(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    localState: WorkspaceLocalState,
    programInternalID: UInt64,
    role: ProgramCanvasRole,
    timeSeconds: Float
  ) throws -> ProgramRuntimeConfiguration {
    try runtimeProjection(
      definition: definition, preferences: preferences, localState: localState,
      programInternalID: programInternalID, role: role, timeSeconds: timeSeconds
    ).configuration
  }

  static func runtimeProjection(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    localState: WorkspaceLocalState,
    programInternalID: UInt64,
    role: ProgramCanvasRole,
    timeSeconds: Float
  ) throws -> WorkspaceV4RuntimeProjection {
    let graph = try Self(
      definition: definition, preferences: preferences,
      programInternalID: programInternalID, role: role, localState: localState)
    let layerIDs = try requiredLayerIDs(
      definition: definition, programInternalID: programInternalID, role: role)
    let profile = try outputProfile(for: role, canvas: definition.canvasConfiguration)
    let bitRate =
      role == .landscape
      ? definition.canvasConfiguration.landscapeVideoBitRate
      : definition.canvasConfiguration.portraitVideoBitRate
    let resolvedProfile = bitRate == 0 ? profile : profile.withVideoBitRate(Int(bitRate))
    let frameRate =
      definition.canvasConfiguration.frameRate == 0
      ? resolvedProfile.frameRate
      : Int(definition.canvasConfiguration.frameRate)
    let videoDeviceIDs = Self.videoInputDevicesByInternalID(definition)
    var cameraIDs: [String: String] = Dictionary(
      uniqueKeysWithValues: videoDeviceIDs.keys.compactMap { id in
        guard layerIDs.contains(id) else { return nil }
        return localState.videoInputDevicePhysicalIDs[id].map { ("v4-\(id)", $0) }
      })
    for wrapper in definition.videoComponents {
      guard case .vfxSource(let source)? = wrapper.definition,
        layerIDs.contains(source.internalID),
        let physicalID = localState.videoInputDevicePhysicalIDs[source.inputDeviceInternalID]
      else { continue }
      cameraIDs["v4-vfx-\(source.internalID)"] = physicalID
    }
    var inputDeviceNames = Dictionary(
      uniqueKeysWithValues: videoDeviceIDs.compactMap {
        layerIDs.contains($0.key) ? ("v4-\($0.key)", $0.value.displayName) : nil
      })
    for wrapper in definition.videoComponents {
      guard case .vfxSource(let source)? = wrapper.definition, layerIDs.contains(source.internalID)
      else { continue }
      inputDeviceNames["v4-vfx-\(source.internalID)"] = source.displayName
    }
    let masterCameraID =
      definition.canvasConfiguration.hasPtsMasterVideoInputDeviceInternalID
      ? localState.videoInputDevicePhysicalIDs[
        definition.canvasConfiguration.ptsMasterVideoInputDeviceInternalID]
      : nil
    return WorkspaceV4RuntimeProjection(
      configuration: ProgramRuntimeConfiguration(
        composite: graph.composite,
        audioChannels: graph.composite.audioChannels,
        outputProfile: resolvedProfile,
        canvasWidth: resolvedProfile.width,
        canvasHeight: resolvedProfile.height,
        outputWidth: resolvedProfile.width,
        outputHeight: resolvedProfile.height,
        frameRate: frameRate,
        timeSeconds: timeSeconds,
        videoPTSMasterCameraID: masterCameraID,
        cameraIDsByInputKey: cameraIDs,
        inputDeviceNamesByInputKey: inputDeviceNames,
        cameraInputColorOverrides: [:],
        backgroundRemovalInputKeys: backgroundRemovalInputKeys(
          definition: definition, layerIDs: layerIDs),
        videoLayerProgramName: "v4-\(programInternalID)"
      ),
      preferences: graph.audioPreferences
    )
  }

  private static func requiredLayerIDs(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws -> [UInt64] {
    guard let program = definition.programs.first(where: { $0.internalID == programInternalID })
    else {
      throw WorkspaceV4RenderGraphError.missingProgram(programInternalID)
    }
    return role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
  }

  private static func outputProfile(
    for role: ProgramCanvasRole,
    canvas: Ldtx_Workspace_V4_CanvasConfiguration
  ) throws -> ProgramOutputProfile {
    switch role {
    case .landscape:
      guard
        canvas.landscapeProfileID.isEmpty
          || canvas.landscapeProfileID == "sdr-landscape-1080p60"
      else { throw WorkspaceV4RenderGraphError.unsupportedOutputProfile(canvas.landscapeProfileID) }
      return .sdr1080p60
    case .portrait:
      guard
        canvas.portraitProfileID.isEmpty
          || canvas.portraitProfileID == "sdr-portrait-1080p60"
      else { throw WorkspaceV4RenderGraphError.unsupportedOutputProfile(canvas.portraitProfileID) }
      return .sdrPortrait1080p60
    }
  }

  private static func backgroundRemovalInputKeys(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    layerIDs: [UInt64]
  ) -> Set<String> {
    Set(
      definition.videoComponents.compactMap { wrapper -> String? in
        guard case .vfxSource(let source)? = wrapper.definition,
          layerIDs.contains(source.internalID),
          source.effects.contains(where: { effect in
            guard case .backgroundRemoval(let removal)? = effect.definition else { return false }
            return removal.model == .mediapipeLandscape
          })
        else { return nil }
        return "v4-vfx-\(source.internalID)"
      })
  }
}

struct WorkspaceV4RuntimeProjection: Sendable {
  var configuration: ProgramRuntimeConfiguration
  var preferences: ProgramPreferences
}

enum WorkspaceV4RenderGraphError: Error, Equatable {
  case missingProgram(UInt64)
  case missingVideoLayer(UInt64)
  case unsupportedOutputProfile(String)
}
