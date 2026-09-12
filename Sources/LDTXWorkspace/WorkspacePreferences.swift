// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

@available(*, deprecated, message: "Use WorkspaceV4PreferencesDocument and WorkspaceV4Store.")
public struct WorkspacePreferences: Codable, Equatable, Sendable {
  public var programPreferences: ProgramPreferences
  public var portraitProgramPreferences: ProgramPreferences
  public var physicalDeviceIDsByInputDeviceID: [String: String]
  public var inputCameraDeviceMappings: [String: String]
  public var inputAudioDeviceMappings: [String: String]
  public var inputAudioMonitorChannelKeys: Set<String>
  public var selectedProgramName: String?
  public var outputDestination: OutputDestination

  public init(
    programPreferences: ProgramPreferences = ProgramPreferences(),
    portraitProgramPreferences: ProgramPreferences = ProgramPreferences(),
    physicalDeviceIDsByInputDeviceID: [String: String] = [:],
    inputCameraDeviceMappings: [String: String] = [:],
    inputAudioDeviceMappings: [String: String] = [:],
    inputAudioMonitorChannelKeys: Set<String> = [],
    selectedProgramName: String? = nil,
    outputDestination: OutputDestination = .newWorkspaceInitialValue
  ) {
    self.programPreferences = programPreferences
    self.portraitProgramPreferences = portraitProgramPreferences
    self.physicalDeviceIDsByInputDeviceID = physicalDeviceIDsByInputDeviceID
    self.inputCameraDeviceMappings = inputCameraDeviceMappings
    self.inputAudioDeviceMappings = inputAudioDeviceMappings
    self.inputAudioMonitorChannelKeys = inputAudioMonitorChannelKeys
    self.selectedProgramName = selectedProgramName
    self.outputDestination = outputDestination
  }

  public mutating func removeInputDevice(named name: String) {
    programPreferences.removeInputDevice(named: name)
    portraitProgramPreferences.removeInputDevice(named: name)
    physicalDeviceIDsByInputDeviceID.removeValue(forKey: name)
  }

  public func programPreferences(for role: ProgramCanvasRole) -> ProgramPreferences {
    role == .landscape ? programPreferences : portraitProgramPreferences
  }
}
