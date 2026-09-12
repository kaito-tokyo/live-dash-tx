// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf

public enum YouTubeIngestMode: UInt32, Codable, CaseIterable, Equatable, Sendable {
  case dash = 0
  case dualRTMPS = 1
}

public struct OutputDestination: Codable, Equatable, Sendable {
  public var recordsLandscape: Bool
  public var recordsPortrait: Bool
  public var streamsToYouTube: Bool
  public var youtubeIngestMode: YouTubeIngestMode
  public var overridesOutputFolder: Bool
  public var outputFolderPath: String?
  public var recordingCustomFields: [String: String]

  public init(
    recordsLocally: Bool = true,
    recordsLandscape: Bool? = nil,
    recordsPortrait: Bool = false,
    streamsToYouTube: Bool = false,
    youtubeIngestMode: YouTubeIngestMode = .dash,
    overridesOutputFolder: Bool = false,
    outputFolderPath: String? = nil,
    recordingCustomFields: [String: String] = [:]
  ) {
    self.recordsLandscape = recordsLandscape ?? recordsLocally
    self.recordsPortrait = recordsPortrait
    self.streamsToYouTube = streamsToYouTube
    self.youtubeIngestMode = youtubeIngestMode
    self.overridesOutputFolder = overridesOutputFolder
    self.outputFolderPath = outputFolderPath
    self.recordingCustomFields = recordingCustomFields
  }

  public var recordsLocally: Bool {
    get { recordsLandscape || recordsPortrait }
    set {
      recordsLandscape = newValue
      if !newValue { recordsPortrait = false }
    }
  }

  /// Returns a structurally normalized value without consulting the current
  /// filesystem. Folder availability is validated immediately before output starts.
  public func normalized(fileManager _: FileManager = .default) -> OutputDestination? {
    guard overridesOutputFolder else {
      return outputFolderPath == nil ? self : nil
    }
    guard let outputFolderPath, !outputFolderPath.isEmpty else { return nil }
    let url = URL(fileURLWithPath: outputFolderPath, isDirectory: true).standardizedFileURL
    var result = self
    result.outputFolderPath = url.path
    return result
  }

  /// Concrete destination written into every newly created Workspace.
  public static let newWorkspaceInitialValue = OutputDestination(
    recordsLocally: true,
    streamsToYouTube: false
  )

  /// Recovery-only value for persisted preferences that predate or omit the
  /// destination message. Its behavior is intentionally not a migration contract.
  public static let missingPersistedValueFallback = OutputDestination(
    recordsLocally: true,
    streamsToYouTube: false
  )
}

public struct ApplicationOutputPreferences: Codable, Equatable, Sendable {
  public var defaultOutputFolderPath: String?

  public init(defaultOutputFolderPath: String? = nil) {
    self.defaultOutputFolderPath = defaultOutputFolderPath
  }
}

public enum ApplicationOutputPreferencesPersistenceCodec {
  public static func encode(_ preferences: ApplicationOutputPreferences) throws -> Data {
    try preferences.protoMessage.serializedData()
  }

  public static func decode(from data: Data) throws -> ApplicationOutputPreferences {
    try Ldtx_App_V1_ApplicationOutputPreferences(serializedBytes: data).domainModel
  }

  public static func migrateLegacyOutputSettings(from data: Data) throws
    -> ApplicationOutputPreferences?
  {
    let legacy = try Ldtx_App_V1_LegacyOutputSettings(serializedBytes: data)
    guard legacy.hasRecording,
      legacy.recording.hasBaseDirectoryPath,
      legacy.recording.baseDirectoryPath.hasPrefix("/")
    else { return nil }
    let path = URL(
      fileURLWithPath: legacy.recording.baseDirectoryPath,
      isDirectory: true
    ).standardizedFileURL.path
    return ApplicationOutputPreferences(defaultOutputFolderPath: path)
  }

  public static func migrateLegacyOutputSettingsIfNeeded(
    currentData: Data,
    legacyData: Data
  ) throws -> Data? {
    guard currentData.isEmpty,
      !legacyData.isEmpty,
      let preferences = try migrateLegacyOutputSettings(from: legacyData)
    else { return nil }
    return try encode(preferences)
  }
}

extension ApplicationOutputPreferences {
  fileprivate var protoMessage: Ldtx_App_V1_ApplicationOutputPreferences {
    var proto = Ldtx_App_V1_ApplicationOutputPreferences()
    if let defaultOutputFolderPath { proto.defaultOutputFolderPath = defaultOutputFolderPath }
    return proto
  }
}

extension Ldtx_App_V1_ApplicationOutputPreferences {
  fileprivate var domainModel: ApplicationOutputPreferences {
    ApplicationOutputPreferences(
      defaultOutputFolderPath: hasDefaultOutputFolderPath ? defaultOutputFolderPath : nil
    )
  }
}
