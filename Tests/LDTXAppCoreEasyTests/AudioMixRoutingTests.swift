// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXAudioEngine
import LDTXProgram
import LDTXWorkspace
import Testing

@testable import LDTXProgramRuntime

@Suite
struct AudioMixRoutingUnitTestSuite {
  @Test func independentMasterVolumesAndMonitorRouting() {
    let channel = ProgramAudioChannel(
      id: "Mic", component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Mic")))
    var landscape = ProgramPreferences(masterVolume: 0.5, monitorVolume: 0.25)
    landscape.setAudioChannelGain(0.4, for: channel, in: [channel])
    var portrait = landscape
    portrait.masterVolume = 0.75
    #expect(abs(landscape.outputAudioChannelGain(for: channel, in: [channel]) - 0.2) < 0.00001)
    #expect(abs(portrait.outputAudioChannelGain(for: channel, in: [channel]) - 0.3) < 0.00001)
    landscape.setAudioMuted(true, inputDeviceName: "Mic")
    #expect(landscape.outputAudioChannelGain(for: channel, in: [channel]) == 0)
    #expect(
      abs(landscape.monitorMixPreferences.outputAudioChannelGain(for: channel, in: [channel]) - 0.1)
        < 0.00001)
    #expect(portrait.masterVolume == 0.75)
  }

  @Test func audioMixSettingsRoundTrip() throws {
    var source = ProgramPreferences(masterVolume: 0.5, monitorVolume: 0.25)
    source.setAudioMuted(true, inputDeviceName: "Mic")
    let protobuf = try ProgramPersistenceCodec.encodeProgramPreferences(source)
    #expect(try ProgramPersistenceCodec.decodeProgramPreferences(from: protobuf) == source)
    #expect(
      try JSONDecoder().decode(ProgramPreferences.self, from: JSONEncoder().encode(source))
        == source)
    let defaults = try ProgramPersistenceCodec.decodeProgramPreferences(from: Data())
    #expect(defaults.masterVolume == 1)
    #expect(defaults.monitorVolume == 1)
  }
}

extension AudioMixRoutingUnitTestSuite {
  @Test func sharedPhysicalInputAndMatchingBusesAreReused() {
    let engine = WorkspaceAudioEngine(hardwareEnabled: false)
    let input = engine.input(uid: "A", kind: 3)
    #expect(engine.input(uid: "A", kind: 3) == input)
    let route = WorkspaceAudioEngine.Route(input: input, gain: 2, connected: true)
    let preview = UUID()
    let output = UUID()
    let previewBus = engine.configureBus(owner: preview, routes: [route], master: 3)
    #expect(engine.configureBus(owner: output, routes: [route], master: 3) == previewBus)
    let changed = engine.configureBus(owner: preview, routes: [route], master: 4)
    #expect(changed != previewBus)
    #expect(engine.configureBus(owner: output, routes: [route], master: 4) == changed)
    engine.releaseBus(owner: output)
    #expect(engine.configureBus(owner: preview, routes: [route], master: 4) == changed)
  }

  @Test func monitorToggleDoesNotRestartWorkspaceInput() {
    let engine = WorkspaceAudioEngine(hardwareEnabled: false)
    let input = engine.input(uid: "A", kind: 3)
    let before = LDTXAudioGetStatistics(engine.native, input).generation
    for connected in [true, false, true] {
      engine.configureMonitor(
        routes: [.init(input: input, gain: 3, connected: connected)], master: 2)
      #expect(LDTXAudioGetStatistics(engine.native, input).generation == before)
    }
  }
}
