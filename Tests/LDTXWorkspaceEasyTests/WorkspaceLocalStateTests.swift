// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXWorkspace

@Suite("Workspace local state")
struct WorkspaceLocalStateUnitTestSuite {
  @Test("persists all local state deterministically")
  func persistsState() throws {
    let state = WorkspaceLocalState(
      selectedProgramInternalID: 42,
      videoInputDevicePhysicalIDs: [3: "video-device"],
      audioInputDevicePhysicalIDs: [5: "audio-device"],
      monitorAudioInputDeviceInternalIDs: [11, 7],
      synchronizesLandscapeMixToPortraitByProgramInternalID: [42: true],
      landscapeYouTubeLiveStreamID: "landscape-stream",
      portraitYouTubeLiveStreamID: "portrait-stream"
    )
    let store = WorkspaceLocalStateStore(
      statesByWorkspacePath: ["/Workspace.ldtxworkspace": state]
    )

    let data = try WorkspaceLocalStatePersistenceCodec.encode(store)

    #expect(try WorkspaceLocalStatePersistenceCodec.decode(from: data) == store)
    #expect(try WorkspaceLocalStatePersistenceCodec.encode(store) == data)
  }

  @Test("keys package state by the standardized package path")
  func standardizesPackagePath() {
    let packageURL = URL(fileURLWithPath: "/tmp/Parent/../Workspace.ldtxworkspace")
    var store = WorkspaceLocalStateStore()
    store[packageURL].selectedProgramInternalID = 99

    #expect(
      store[URL(fileURLWithPath: "/tmp/Workspace.ldtxworkspace")]
        .selectedProgramInternalID == 99
    )
  }

  @Test("does not persist an absent Program selection")
  func omitsAbsentProgramSelection() throws {
    let store = WorkspaceLocalStateStore(
      statesByWorkspacePath: ["/Workspace.ldtxworkspace": WorkspaceLocalState()]
    )

    let decoded = try WorkspaceLocalStatePersistenceCodec.decode(
      from: WorkspaceLocalStatePersistenceCodec.encode(store)
    )

    #expect(
      decoded.statesByWorkspacePath["/Workspace.ldtxworkspace"]?.selectedProgramInternalID == nil)
  }
}
