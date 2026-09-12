// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// File names shared by the persisted Workspace package envelope.
public enum WorkspacePackageLayout {
  public static let pathExtension = "ldtxworkspace"
  public static let protobufFileName = "workspace.pb"
  public static let jsonFileName = "workspace.json"
  public static let preferencesProtobufFileName = "preferences.pb"
  public static let preferencesJSONFileName = "preferences.json"
  public static let assetsDirectoryName = "Assets"
  public static let extensionsDirectoryName = "Extensions"
}

/// The two persisted Version 4 documents in one Workspace package.
public struct WorkspaceV4Package: Equatable, Sendable {
  public var definition: WorkspaceV4DefinitionDocument
  public var preferences: WorkspaceV4PreferencesDocument

  public init(
    definition: WorkspaceV4DefinitionDocument,
    preferences: WorkspaceV4PreferencesDocument
  ) {
    self.definition = definition
    self.preferences = preferences
  }
}

/// Reads and writes the protobuf-only Version 4 Workspace package format.
/// Assets and Extensions are copied unchanged when a package is replaced.
public struct WorkspaceV4PackageService {
  private let fileManager: FileManager
  private let backupService: WorkspaceBackupService?

  public init(
    fileManager: FileManager = .default,
    backupService: WorkspaceBackupService? = nil
  ) {
    self.fileManager = fileManager
    self.backupService = backupService
  }

  /// Returns whether this package has a decodable V4 definition envelope.
  /// It does not mutate the package and does not convert earlier formats.
  public func isV4Package(at packageURL: URL) -> Bool {
    (try? load(at: packageURL)) != nil
  }

  /// Returns whether the package has the V4 protobuf-only file layout.
  ///
  /// This is intentionally a structural check rather than a decode check so
  /// malformed V4 packages still reach the V4 runtime and report a V4 error.
  public func isV4PackageCandidate(at packageURL: URL) -> Bool {
    guard fileManager.fileExists(atPath: packageURL.path) else { return false }
    let workspaceURL = packageURL.appendingPathComponent(
      WorkspacePackageLayout.protobufFileName)
    let preferencesURL = packageURL.appendingPathComponent(
      WorkspacePackageLayout.preferencesProtobufFileName)
    let legacyJSONURL = packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName)
    let legacyPreferencesJSONURL = packageURL.appendingPathComponent(
      WorkspacePackageLayout.preferencesJSONFileName)
    return fileManager.fileExists(atPath: workspaceURL.path)
      && fileManager.fileExists(atPath: preferencesURL.path)
      && !fileManager.fileExists(atPath: legacyJSONURL.path)
      && !fileManager.fileExists(atPath: legacyPreferencesJSONURL.path)
  }

  public func load(at packageURL: URL) throws -> WorkspaceV4Package {
    let packageURL = try packageDirectory(at: packageURL)
    if fileManager.fileExists(
      atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName).path
    )
      || fileManager.fileExists(
        atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.preferencesJSONFileName)
          .path
      )
    {
      throw WorkspaceV4PackageServiceError.unsupportedWorkspaceV3Package(packageURL)
    }
    do {
      let workspace = try WorkspaceV4Package(
        definition: WorkspaceV4PersistenceCodec.decodeDefinition(
          from: Data(
            contentsOf: packageURL.appendingPathComponent(
              WorkspacePackageLayout.protobufFileName))),
        preferences: WorkspaceV4PersistenceCodec.decodePreferences(
          from: Data(
            contentsOf: packageURL.appendingPathComponent(
              WorkspacePackageLayout.preferencesProtobufFileName)))
      )
      try WorkspaceV4IntegrityValidator.validate(workspace)
      return workspace
    } catch let error as WorkspaceV4PersistenceError {
      if case .missingDefinition = error {
        throw WorkspaceV4PackageServiceError.unsupportedWorkspaceV3Package(packageURL)
      }
      throw error
    }
  }

  public func save(
    _ workspace: WorkspaceV4Package,
    to packageURL: URL,
    resourcesSourceURL: URL? = nil
  ) throws {
    try WorkspaceV4IntegrityValidator.validate(workspace)
    let definitionData = try WorkspaceV4PersistenceCodec.encodeDefinition(workspace.definition)
    let preferencesData = try WorkspaceV4PersistenceCodec.encodePreferences(workspace.preferences)
    if let backupService {
      let generation = try backupService.createGeneration(
        lineageID: workspace.definition.externalID,
        sourcePackageURL: packageURL
      ) { generationURL in
        try replaceContents(
          at: generationURL,
          definitionData: definitionData,
          preferencesData: preferencesData
        )
        if let resourcesSourceURL {
          try copyResources(from: resourcesSourceURL, to: generationURL)
        }
      }
      do {
        _ = try load(at: generation.packageURL)
        try publishContents(from: generation.packageURL, to: packageURL)
      } catch {
        try? backupService.discardGeneration(generation)
        throw error
      }
      // Publication has succeeded. Retaining a rollback generation is useful,
      // but failure to prune it must not report this save as failed.
      try? backupService.finishGeneration(generation)
      return
    }
    try replacePackage(
      at: packageURL,
      definitionData: definitionData,
      preferencesData: preferencesData,
      resourcesSourceURL: resourcesSourceURL
    )
  }

  private func replaceContents(
    at packageURL: URL,
    definitionData: Data,
    preferencesData: Data
  ) throws {
    try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try removeObsoleteArtifacts(at: packageURL)
    try definitionData.write(
      to: packageURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName),
      options: .atomic
    )
    try preferencesData.write(
      to: packageURL.appendingPathComponent(WorkspacePackageLayout.preferencesProtobufFileName),
      options: .atomic
    )
  }

  private func replacePackage(
    at packageURL: URL,
    definitionData: Data,
    preferencesData: Data,
    resourcesSourceURL: URL?
  ) throws {
    let parentURL = packageURL.deletingLastPathComponent()
    let stagingURL = parentURL.appendingPathComponent(
      ".\(packageURL.lastPathComponent).staging-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? fileManager.removeItem(at: stagingURL) }
    var isDirectory = ObjCBool(false)
    let exists = fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory)
    if exists {
      guard isDirectory.boolValue else {
        throw WorkspaceV4PackageServiceError.packageURLIsNotDirectory(packageURL)
      }
      try fileManager.copyItem(at: packageURL, to: stagingURL)
    }
    try replaceContents(
      at: stagingURL, definitionData: definitionData, preferencesData: preferencesData)
    if let resourcesSourceURL {
      try copyResources(from: resourcesSourceURL, to: stagingURL)
    }
    var visibleStagingURL = stagingURL
    var values = URLResourceValues()
    values.isHidden = false
    try visibleStagingURL.setResourceValues(values)
    if exists {
      _ = try fileManager.replaceItemAt(
        packageURL, withItemAt: stagingURL, backupItemName: nil,
        options: [.usingNewMetadataOnly]
      )
    } else {
      try fileManager.moveItem(at: stagingURL, to: packageURL)
    }
  }

  private func copyResources(from sourceURL: URL, to destinationURL: URL) throws {
    for name in [
      WorkspacePackageLayout.assetsDirectoryName,
      WorkspacePackageLayout.extensionsDirectoryName,
    ] {
      let source = sourceURL.appendingPathComponent(name, isDirectory: true)
      let destination = destinationURL.appendingPathComponent(name, isDirectory: true)
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      if fileManager.fileExists(atPath: source.path) {
        try fileManager.copyItem(at: source, to: destination)
      }
    }
  }

  private func publishContents(from sourceURL: URL, to destinationURL: URL) throws {
    let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
      ".\(destinationURL.lastPathComponent).publish-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? fileManager.removeItem(at: temporaryURL) }
    if fileManager.fileExists(atPath: destinationURL.path) {
      try fileManager.copyItem(at: destinationURL, to: temporaryURL)
    }
    try synchronizeDirectoryContents(from: sourceURL, to: temporaryURL)
    if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(
        destinationURL, withItemAt: temporaryURL, backupItemName: nil,
        options: [.usingNewMetadataOnly]
      )
    } else {
      try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }
  }

  private func synchronizeDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let sourceItems = try fileManager.contentsOfDirectory(
      at: sourceURL, includingPropertiesForKeys: [.isDirectoryKey]
    )
    let sourceNames = Set(sourceItems.map(\.lastPathComponent))
    for sourceURL in sourceItems {
      let destinationURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
      if try sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        try synchronizeDirectoryContents(from: sourceURL, to: destinationURL)
      } else {
        if fileManager.fileExists(atPath: destinationURL.path) {
          try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
      }
    }
    for destinationURL in try fileManager.contentsOfDirectory(
      at: destinationURL, includingPropertiesForKeys: nil
    ) where !sourceNames.contains(destinationURL.lastPathComponent) {
      try fileManager.removeItem(at: destinationURL)
    }
  }

  private func removeObsoleteArtifacts(at packageURL: URL) throws {
    for name in [
      WorkspacePackageLayout.jsonFileName,
      WorkspacePackageLayout.preferencesJSONFileName,
      "LDTX.lock",
    ] {
      let url = packageURL.appendingPathComponent(name)
      if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }
  }

  private func packageDirectory(at url: URL) throws -> URL {
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
    else { throw WorkspaceV4PackageServiceError.packageNotFound(url) }
    return url
  }
}

public enum WorkspaceV4PackageServiceError: Error, Equatable, LocalizedError, Sendable {
  case packageNotFound(URL)
  case packageURLIsNotDirectory(URL)
  case unsupportedWorkspaceV3Package(URL)

  public var errorDescription: String? {
    switch self {
    case .packageNotFound(let url): "Workspace package was not found: \(url.path)"
    case .packageURLIsNotDirectory(let url):
      "The selected Workspace is not a package directory: \(url.path)"
    case .unsupportedWorkspaceV3Package(let url):
      "This Workspace uses the retired V3 format and cannot be opened. Convert it to V4 first: \(url.path)"
    }
  }
}
