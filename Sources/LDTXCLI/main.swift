// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import LDTXDiagnostics
import LDTXRecording
import LDTXWorkspace

@main
struct LDTXHelper: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ldtx",
    abstract: "Inspect, verify, and remux LDTX recording packages, or run its stdio MCP server.",
    subcommands: [
      RecordCommand.self, WorkspaceCommand.self, DiagnosticsCommand.self, MCPCommand.self,
    ]
  )

  static func inspect(_ path: String) throws {
    let package = try RecordingPackage(contentsOf: URL(fileURLWithPath: path).standardizedFileURL)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(RecordingInspectionValue(package: package))
    print(String(decoding: data, as: UTF8.self))
  }

  static func verify(_ path: String, strict: Bool) async throws {
    let package = try RecordingPackage(contentsOf: URL(fileURLWithPath: path).standardizedFileURL)
    if strict { try package.requireFinalized() }
    let warnings = try await RecordingPackageVerifier().verify(package, strict: strict)
    for warning in warnings { writeWarning(warning) }
    print("OK: \(package.identifier) (\(package.audioTracks.count) audio tracks)")
  }

  static func remux(
    _ path: String,
    output: String?,
    replace: Bool,
    strict: Bool,
    canvas: RecordingCanvas?
  ) async throws {
    let packageURL = URL(fileURLWithPath: path).standardizedFileURL
    let package = try RecordingPackage(contentsOf: packageURL)
    if strict { try package.requireFinalized() }
    let warnings = try await RecordingPackageVerifier().verify(
      package, strict: strict, canvas: canvas)
    for warning in warnings { writeWarning(warning) }
    let outputURL =
      output.map { URL(fileURLWithPath: $0).standardizedFileURL }
      ?? RecordingPackage.defaultRemuxOutputURL(for: packageURL)
    try await RecordingRemuxer().remux(
      package: package,
      to: outputURL,
      replaceExisting: replace,
      canvas: canvas
    )
    print(outputURL.path)
  }

  static func writeWarning(_ warning: String) {
    FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
  }
}

private struct WorkspaceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workspace",
    abstract: "Create, inspect, and validate protobuf-only Workspace v4 packages.",
    subcommands: [Create.self, Dump.self, Validate.self]
  )

  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Create a new Workspace v4 package, optionally from protobuf JSON.")
    @Argument(help: "Path for a new .ldtxworkspace package.") var package: String
    @Option(help: "Workspace display name.") var name: String?
    @Option(help: "WorkspaceDefinitionV4 protobuf JSON to import.") var json: String?
    @Option(help: "WorkspacePreferencesV4 protobuf JSON to import with --json.")
    var preferencesJSON: String?
    @Flag(help: "Replace an existing Workspace package at the destination.") var replace = false

    mutating func run() async throws {
      let url = URL(fileURLWithPath: package).standardizedFileURL
      let existedBeforeCreate = FileManager.default.fileExists(atPath: url.path)
      guard replace || !existedBeforeCreate else {
        throw ValidationError("Workspace already exists: \(url.path)")
      }
      guard preferencesJSON == nil || json != nil else {
        throw ValidationError("--preferences-json requires --json")
      }
      let lockService = WorkspaceV4PackageLockService()
      let lock = try lockService.acquire(at: url, createsPackageDirectory: true)
      defer { lockService.release(lock) }
      do {
        let workspace: WorkspaceV4Package
        if let json {
          var definition = try Ldtx_Workspace_V4_WorkspaceDefinitionV4(
            jsonUTF8Data: Data(contentsOf: URL(fileURLWithPath: json)))
          if let name { definition.displayName = name }
          let preferences =
            try preferencesJSON.map {
              try Ldtx_Workspace_V4_WorkspacePreferencesV4(
                jsonUTF8Data: Data(contentsOf: URL(fileURLWithPath: $0)))
            } ?? Ldtx_Workspace_V4_WorkspacePreferencesV4()
          workspace = WorkspaceV4Package(
            definition: WorkspaceV4DefinitionDocument(
              externalID: WorkspaceV4PersistenceCodec.makeExternalID(), definition: definition),
            preferences: WorkspaceV4PreferencesDocument(
              externalID: WorkspaceV4PersistenceCodec.makeExternalID(), preferences: preferences))
        } else {
          workspace = WorkspaceV4Package(
            definition: WorkspaceV4DefinitionDocument(
              externalID: WorkspaceV4PersistenceCodec.makeExternalID(),
              definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
                $0.displayName = name ?? url.deletingPathExtension().lastPathComponent
              }),
            preferences: WorkspaceV4PreferencesDocument(
              externalID: WorkspaceV4PersistenceCodec.makeExternalID(),
              preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4()))
        }
        try WorkspaceV4PackageService(backupService: WorkspaceBackupService()).save(
          workspace, to: url)
        print("Created Workspace v4: \(url.path)")
      } catch {
        if !existedBeforeCreate {
          try? FileManager.default.removeItem(at: url)
        }
        throw error
      }
    }
  }

  struct Dump: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print a read-only debug dump of stored Program layers.")
    @Argument(help: "Path to an .ldtxworkspace package.") var package: String
    @Option(help: "Limit output to one Program name.") var program: String?

    mutating func run() throws {
      let url = URL(fileURLWithPath: package).standardizedFileURL
      let lockService = WorkspaceV4PackageLockService()
      let lock = try lockService.acquire(at: url)
      defer { lockService.release(lock) }
      let dump = try workspaceV4DebugDump(
        at: url, programName: program)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      print(String(decoding: try encoder.encode(dump), as: UTF8.self))
    }
  }

  struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Validate protobuf-only v4 files, references, and profiles.")
    @Argument(help: "Path to an .ldtxworkspace package.") var package: String

    mutating func run() throws {
      let url = URL(fileURLWithPath: package).standardizedFileURL
      let lockService = WorkspaceV4PackageLockService()
      let lock = try lockService.acquire(at: url)
      defer { lockService.release(lock) }
      _ = try WorkspaceV4PackageService().load(at: url)
      print("OK: Workspace v4 \(url.path)")
    }
  }
}

public struct WorkspaceV4DebugDump: Codable, Equatable {
  static let format = "ldtx-workspace-debug-dump-v4"
  public struct Program: Codable, Equatable {
    public var internalID: UInt64
    public var displayName: String
    public var landscapeVideoLayerInternalIDs: [UInt64]
    public var portraitVideoLayerInternalIDs: [UInt64]
  }
  public var format: String
  public var definitionExternalID: UUID
  public var preferencesExternalID: UUID
  public var displayName: String
  public var programs: [Program]
}

public func workspaceV4DebugDump(
  at packageURL: URL, programName: String? = nil
) throws -> WorkspaceV4DebugDump {
  let workspace = try WorkspaceV4PackageService().load(at: packageURL)
  let programs = workspace.definition.definition.programs.filter {
    programName == nil || $0.displayName == programName
  }
  guard programName == nil || !programs.isEmpty else {
    throw ValidationError("Program not found: \(programName ?? "")")
  }
  return WorkspaceV4DebugDump(
    format: WorkspaceV4DebugDump.format,
    definitionExternalID: workspace.definition.externalID,
    preferencesExternalID: workspace.preferences.externalID,
    displayName: workspace.definition.definition.displayName,
    programs: programs.map {
      WorkspaceV4DebugDump.Program(
        internalID: $0.internalID, displayName: $0.displayName,
        landscapeVideoLayerInternalIDs: $0.landscapeVideoLayerInternalIds,
        portraitVideoLayerInternalIDs: $0.portraitVideoLayerInternalIds)
    })
}

private enum RecordingCanvasArgument: String, ExpressibleByArgument {
  case landscape
  case portrait

  var value: RecordingCanvas {
    self == .landscape ? .landscape : .portrait
  }
}

private struct DiagnosticsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diagnostics",
    abstract: "Query LDTX process load samples.",
    subcommands: [Samples.self]
  )

  struct Samples: AsyncParsableCommand {
    @Option(help: "Inclusive RFC 3339 UTC start time.") var start: String
    @Option(help: "Exclusive RFC 3339 UTC end time.") var end: String
    @Option(name: .customLong("app-version"), help: "Application marketing version.")
    var appVersion: String?
    @Option(name: .customLong("bundle-id"), help: "Application bundle identifier.")
    var bundleID: String?

    mutating func run() async throws {
      try LDTXHelper.writeDiagnosticsSamples(
        start: start,
        end: end,
        product: .ldtx,
        applicationVersion: appVersion,
        bundleIdentifier: bundleID
      )
    }
  }
}

private struct RecordCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "record",
    abstract: "Inspect, verify, and remux .ldtxrecord packages.",
    subcommands: [Inspect.self, Verify.self, Remux.self, Seal.self, VerifyShield.self]
  )

  struct Inspect: AsyncParsableCommand {
    @Argument(help: "Path to an .ldtxrecord package.") var path: String
    mutating func run() async throws { try LDTXHelper.inspect(path) }
  }

  struct Verify: AsyncParsableCommand {
    @Argument(help: "Path to an .ldtxrecord package.") var path: String
    @Flag(help: "Reject an unfinalized package instead of attempting recovery.") var strict = false
    mutating func run() async throws { try await LDTXHelper.verify(path, strict: strict) }
  }

  struct Remux: AsyncParsableCommand {
    @Argument(help: "Path to an .ldtxrecord package.") var path: String
    @Option(name: [.short, .long], help: "Output MP4 path.") var output: String?
    @Flag(help: "Replace an existing output file.") var replace = false
    @Flag(help: "Reject an unfinalized package instead of attempting recovery.") var strict = false
    @Option(help: "Canvas to remux when a v3 recording contains both outputs.")
    var canvas: RecordingCanvasArgument?
    mutating func run() async throws {
      try await LDTXHelper.remux(
        path, output: output, replace: replace, strict: strict, canvas: canvas?.value)
    }
  }

  struct Seal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Seal a finalized package with Recording Shield v1.")
    @Argument(help: "Path to an .ldtxrecord package.") var path: String
    mutating func run() async throws {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      let statement = try RecordingShieldSealer().seal(packageAt: url)
      print(
        "Sealed \(statement.subject.count) files: \(url.appendingPathComponent(RecordingShieldProfile.manifestFileName).path)"
      )
    }
  }

  struct VerifyShield: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "verify-shield", abstract: "Verify Recording Shield integrity.")
    @Argument(help: "Path to an .ldtxrecord package.") var path: String
    mutating func run() async throws {
      let result = RecordingShieldVerifier().verify(
        packageAt: URL(fileURLWithPath: path).standardizedFileURL)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      print(String(decoding: try encoder.encode(result), as: UTF8.self))
      if result.status != .valid { throw ExitCode.failure }
    }
  }
}

private struct MCPCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Run the LDTX recording stdio MCP server."
  )

  mutating func run() async throws { try await LDTXMCPServer().run() }
}

extension LDTXHelper {
  static func writeDiagnosticsSamples(
    start: String,
    end: String,
    product: DiagnosticsProduct? = nil,
    applicationVersion: String? = nil,
    bundleIdentifier: String? = nil,
    applicationSupportDirectory: URL? = nil,
    output: FileHandle = .standardOutput
  ) throws {
    let (database, startMilliseconds, endMilliseconds) = try openDiagnosticsQuery(
      start: start,
      end: end,
      product: product,
      applicationVersion: applicationVersion,
      bundleIdentifier: bundleIdentifier,
      applicationSupportDirectory: applicationSupportDirectory
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try output.write(contentsOf: Data("[\n".utf8))
    var isFirst = true
    if startMilliseconds < endMilliseconds {
      try database.forEachSample(from: startMilliseconds, to: endMilliseconds) { sample in
        if !isFirst { try output.write(contentsOf: Data(",\n".utf8)) }
        try output.write(contentsOf: encoder.encode(sample))
        isFirst = false
      }
    }
    try output.write(contentsOf: Data("\n]\n".utf8))
  }

  static func queryDiagnosticsSamplePage(
    start: String,
    end: String,
    product: DiagnosticsProduct? = nil,
    applicationVersion: String? = nil,
    bundleIdentifier: String? = nil,
    applicationSupportDirectory: URL? = nil,
    cursor: DiagnosticsSampleCursor? = nil,
    limit: Int
  ) throws -> DiagnosticsSamplePage {
    let (database, startMilliseconds, endMilliseconds) = try openDiagnosticsQuery(
      start: start,
      end: end,
      product: product,
      applicationVersion: applicationVersion,
      bundleIdentifier: bundleIdentifier,
      applicationSupportDirectory: applicationSupportDirectory
    )
    guard startMilliseconds < endMilliseconds else {
      return DiagnosticsSamplePage(samples: [], nextCursor: nil)
    }
    return try database.samplePage(
      from: startMilliseconds, to: endMilliseconds, after: cursor, limit: limit)
  }

  private static func openDiagnosticsQuery(
    start: String,
    end: String,
    product: DiagnosticsProduct?,
    applicationVersion: String?,
    bundleIdentifier: String?,
    applicationSupportDirectory: URL?
  ) throws -> (DiagnosticsDatabase, Int64, Int64) {
    let startDate = try diagnosticsDate(start)
    let endDate = try diagnosticsDate(end)
    guard startDate < endDate else { throw DiagnosticsDatabaseError.invalidTimeRange }
    let hostBundle = diagnosticsHostApplicationBundle()
    guard let resolvedBundleIdentifier = bundleIdentifier ?? hostBundle?.bundleIdentifier else {
      throw ValidationError("--bundle-id is required outside an application bundle.")
    }
    let resolvedProduct = product ?? .ldtx
    guard
      let resolvedVersion = applicationVersion
        ?? hostBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else {
      throw ValidationError("--app-version is required when the Helper has no application version.")
    }
    let location = try DiagnosticsDatabaseLocation(
      product: resolvedProduct,
      bundleIdentifier: resolvedBundleIdentifier,
      applicationVersion: resolvedVersion,
      applicationSupportDirectory: applicationSupportDirectory
    )
    let database = try DiagnosticsDatabase(location: location, createIfMissing: false)
    return (
      database,
      diagnosticsUnixMillisecondsCeiling(startDate),
      diagnosticsUnixMillisecondsCeiling(endDate)
    )
  }

  private static func diagnosticsUnixMillisecondsCeiling(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded(.up))
  }

  static func diagnosticsHostApplicationBundle() -> Bundle? {
    var candidate = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      .deletingLastPathComponent()
    while candidate.path != "/" {
      if candidate.pathExtension == "app" { return Bundle(url: candidate) }
      candidate.deleteLastPathComponent()
    }
    return nil
  }

  private static func diagnosticsDate(_ value: String) throws -> Date {
    do {
      return try Date(value, strategy: .iso8601)
    } catch {
      throw ValidationError("Invalid RFC 3339 timestamp: \(value)")
    }
  }
}

struct RecordingInspectionValue: Encodable {
  struct AudioTrack: Encodable {
    var identifier: String
    var name: String
    var mediaFile: String
    var playlist: String?
  }

  var formatVersion: Int
  var identifier: String
  var finalized: Bool
  var manifestFile: String
  var mainMediaFile: String
  var mainPlaylist: String?
  var masterPlaylist: String?
  var audioTracks: [AudioTrack]

  init(package: RecordingPackage) {
    formatVersion = package.formatVersion
    identifier = package.identifier
    finalized = package.isFinalized
    manifestFile = package.manifestPath
    mainMediaFile = package.mainMediaPath
    mainPlaylist = package.mainPlaylistPath
    masterPlaylist = package.masterPlaylistPath
    audioTracks = package.audioTracks.map {
      AudioTrack(
        identifier: $0.identifier, name: $0.name, mediaFile: $0.mediaPath, playlist: $0.playlistPath
      )
    }
  }
}
