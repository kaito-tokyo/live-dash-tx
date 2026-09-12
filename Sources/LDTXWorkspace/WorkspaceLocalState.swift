// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf

/// App-local state for one Workspace package.
public struct WorkspaceLocalState: Equatable, Sendable {
  public var selectedProgramInternalID: UInt64?
  public var videoInputDevicePhysicalIDs: [UInt64: String]
  public var audioInputDevicePhysicalIDs: [UInt64: String]
  public var monitorAudioInputDeviceInternalIDs: Set<UInt64>
  public var synchronizesLandscapeMixToPortraitByProgramInternalID: [UInt64: Bool]
  public var landscapeYouTubeLiveStreamID: String?
  public var portraitYouTubeLiveStreamID: String?

  public init(
    selectedProgramInternalID: UInt64? = nil,
    videoInputDevicePhysicalIDs: [UInt64: String] = [:],
    audioInputDevicePhysicalIDs: [UInt64: String] = [:],
    monitorAudioInputDeviceInternalIDs: Set<UInt64> = [],
    synchronizesLandscapeMixToPortraitByProgramInternalID: [UInt64: Bool] = [:],
    landscapeYouTubeLiveStreamID: String? = nil,
    portraitYouTubeLiveStreamID: String? = nil
  ) {
    self.selectedProgramInternalID = selectedProgramInternalID
    self.videoInputDevicePhysicalIDs = videoInputDevicePhysicalIDs
    self.audioInputDevicePhysicalIDs = audioInputDevicePhysicalIDs
    self.monitorAudioInputDeviceInternalIDs = monitorAudioInputDeviceInternalIDs
    self.synchronizesLandscapeMixToPortraitByProgramInternalID =
      synchronizesLandscapeMixToPortraitByProgramInternalID
    self.landscapeYouTubeLiveStreamID = landscapeYouTubeLiveStreamID
    self.portraitYouTubeLiveStreamID = portraitYouTubeLiveStreamID
  }
}

/// All app-local Workspace state, keyed by standardized package path.
public struct WorkspaceLocalStateStore: Equatable, Sendable {
  public var statesByWorkspacePath: [String: WorkspaceLocalState]

  public init(statesByWorkspacePath: [String: WorkspaceLocalState] = [:]) {
    self.statesByWorkspacePath = statesByWorkspacePath
  }

  public subscript(packageURL: URL) -> WorkspaceLocalState {
    get { statesByWorkspacePath[Self.key(for: packageURL)] ?? WorkspaceLocalState() }
    set { statesByWorkspacePath[Self.key(for: packageURL)] = newValue }
  }

  public static func key(for packageURL: URL) -> String {
    packageURL.standardizedFileURL.path
  }
}

public enum WorkspaceLocalStatePersistenceCodec {
  public static func encode(_ store: WorkspaceLocalStateStore) throws -> Data {
    var options = BinaryEncodingOptions()
    options.useDeterministicOrdering = true
    return try store.protoMessage.serializedData(options: options)
  }

  public static func decode(from data: Data) throws -> WorkspaceLocalStateStore {
    try Ldtx_App_V1_WorkspaceLocalStateStore(serializedBytes: data).domainModel
  }
}

extension WorkspaceLocalStateStore {
  fileprivate var protoMessage: Ldtx_App_V1_WorkspaceLocalStateStore {
    var proto = Ldtx_App_V1_WorkspaceLocalStateStore()
    proto.statesByWorkspacePath = statesByWorkspacePath.mapValues(\.protoMessage)
    return proto
  }
}

extension Ldtx_App_V1_WorkspaceLocalStateStore {
  fileprivate var domainModel: WorkspaceLocalStateStore {
    WorkspaceLocalStateStore(statesByWorkspacePath: statesByWorkspacePath.mapValues(\.domainModel))
  }
}

extension WorkspaceLocalState {
  fileprivate var protoMessage: Ldtx_App_V1_WorkspaceLocalState {
    var proto = Ldtx_App_V1_WorkspaceLocalState()
    if let selectedProgramInternalID {
      proto.selectedProgramInternalID = selectedProgramInternalID
    }
    proto.videoInputDevicePhysicalIds = videoInputDevicePhysicalIDs
    proto.audioInputDevicePhysicalIds = audioInputDevicePhysicalIDs
    proto.monitorAudioInputDeviceInternalIds = monitorAudioInputDeviceInternalIDs.sorted()
    proto.synchronizesLandscapeMixToPortraitByProgramInternalID =
      synchronizesLandscapeMixToPortraitByProgramInternalID
    if let landscapeYouTubeLiveStreamID {
      proto.landscapeYoutubeLiveStreamID = landscapeYouTubeLiveStreamID
    }
    if let portraitYouTubeLiveStreamID {
      proto.portraitYoutubeLiveStreamID = portraitYouTubeLiveStreamID
    }
    return proto
  }
}

extension Ldtx_App_V1_WorkspaceLocalState {
  fileprivate var domainModel: WorkspaceLocalState {
    WorkspaceLocalState(
      selectedProgramInternalID: hasSelectedProgramInternalID
        ? selectedProgramInternalID : nil,
      videoInputDevicePhysicalIDs: videoInputDevicePhysicalIds,
      audioInputDevicePhysicalIDs: audioInputDevicePhysicalIds,
      monitorAudioInputDeviceInternalIDs: Set(monitorAudioInputDeviceInternalIds),
      synchronizesLandscapeMixToPortraitByProgramInternalID:
        synchronizesLandscapeMixToPortraitByProgramInternalID,
      landscapeYouTubeLiveStreamID: hasLandscapeYoutubeLiveStreamID
        ? landscapeYoutubeLiveStreamID : nil,
      portraitYouTubeLiveStreamID: hasPortraitYoutubeLiveStreamID
        ? portraitYoutubeLiveStreamID : nil
    )
  }
}
