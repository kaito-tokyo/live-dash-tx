// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import LDTXRecording
import LDTXWorkspace
import LDTXYouTubeRTMPS
import Observation
import UniformTypeIdentifiers

/// Owns local recording for a Version 4 Workspace without consulting a V3
/// Workspace model or `WorkspaceContainer`.
@MainActor
@Observable
final class WorkspaceV4RecordingSession {
  enum State: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case failed(String)
  }

  private let workspaceSession: WorkspaceV4RuntimeSession
  private let diagnosticsContext: RecordingDiagnosticsContext?
  private var activeSession: ActiveDualProgramOutputSession?
  private var recordService: SessionRecordService?
  private var youtubeRTMPSService: YouTubeRTMPSWorkspaceService?
  private var landscapeSubscription: ProgramOutputMediaHub.Subscription?
  private var portraitSubscription: ProgramOutputMediaHub.Subscription?
  private var landscapeHub: ProgramOutputMediaHub?
  private var portraitHub: ProgramOutputMediaHub?
  private var youtubeLandscapeSubscription: ProgramOutputMediaHub.Subscription?
  private var youtubePortraitSubscription: ProgramOutputMediaHub.Subscription?
  private var inputAudioSubscriptions: [WorkspaceCaptureSessionCoordinator.AudioSubscription] = []
  private var terminalFailureMessage: String?
  var state: State = .idle

  init(
    workspaceSession: WorkspaceV4RuntimeSession,
    diagnosticsContext: RecordingDiagnosticsContext? = nil
  ) {
    self.workspaceSession = workspaceSession
    self.diagnosticsContext = diagnosticsContext
  }

  var isRecording: Bool { state == .recording || state == .starting || state == .stopping }

  func start() async {
    guard state == .idle || isFailed else { return }
    if isFailed {
      clearSessionReferences()
      state = .idle
    }
    guard let selectedProgramInternalID = workspaceSession.selectedProgramInternalID else {
      state = .failed("Select a Program before starting recording.")
      return
    }
    let output = workspaceSession.store.workspace.definition.definition.outputConfiguration
    guard output.recordsLandscape || output.recordsPortrait || output.streamsToYoutube else {
      state = .failed("Enable recording or YouTube streaming in Output settings.")
      return
    }
    guard let landscapeRuntime = workspaceSession.runtime(for: .landscape),
      let portraitRuntime = workspaceSession.runtime(for: .portrait)
    else {
      state = .failed("The selected Program runtime is unavailable.")
      return
    }
    guard let landscapeConfiguration = landscapeRuntime.programState.read({ $0 }),
      let portraitConfiguration = portraitRuntime.programState.read({ $0 })
    else {
      state = .failed("The selected Program has not been rendered yet.")
      return
    }

    state = .starting
    let availableCameraIDs = Set(DefaultCaptureDeviceService().availableCameras().map(\.id))
    let unavailableCameraID = workspaceSession.store.workspace.definition.definition.inputDevices
      .compactMap { wrapper -> String? in
        guard case .videoDevice(let input)? = wrapper.definition,
          let cameraID = workspaceSession.physicalVideoDeviceID(for: input.internalID),
          !cameraID.isEmpty, !availableCameraIDs.contains(cameraID)
        else { return nil }
        return cameraID
      }.first
    if let unavailableCameraID {
      state = .failed("Assigned camera is unavailable: \(unavailableCameraID)")
      return
    }
    let audioInputs = workspaceSession.store.workspace.definition.definition.inputDevices.compactMap
    {
      wrapper -> UInt64? in
      guard case .audioDevice(let input)? = wrapper.definition else { return nil }
      return input.internalID
    }
    let audioMappings = audioDeviceIDsByInputKey()
    if let missingAudioInputID = audioInputs.first(where: { audioMappings["v4-\($0)"] == nil }) {
      state = .failed(
        "Assign a physical audio device before starting output (\(missingAudioInputID)).")
      return
    }
    let baseDirectory = outputDirectory(for: output)
    let runsLandscape =
      output.recordsLandscape
      || (output.streamsToYoutube && output.resolvedYouTubeIngestMode != .portraitRtmps)
    let runsPortrait =
      output.recordsPortrait
      || (output.streamsToYoutube && output.resolvedYouTubeIngestMode != .landscapeRtmps)
    do {
      if output.recordsLandscape || output.recordsPortrait {
        try DefaultLocalOutputService(fileManager: .default).validateWritableBaseDirectory(
          baseDirectory)
      }
      try await requestRequiredCaptureAccess(
        configurations: [
          runsLandscape ? landscapeConfiguration : nil,
          runsPortrait ? portraitConfiguration : nil,
        ].compactMap { $0 }
      )
      guard state == .starting else { return }
    } catch {
      state = .failed(error.localizedDescription)
      return
    }

    let youtubeService: YouTubeRTMPSWorkspaceService?
    do {
      youtubeService = output.streamsToYoutube ? try makeYouTubeRTMPSService(for: output) : nil
    } catch {
      state = .failed(error.localizedDescription)
      return
    }
    let service: SessionRecordService?
    do {
      if output.recordsLandscape || output.recordsPortrait {
        let recordService = try SessionRecordService(
          baseDirectory: baseDirectory,
          recordID: SessionRecordService.makeRecordID(),
          writerConfiguration: ProgramOutputEncodingConfiguration.make(
            configuration: landscapeConfiguration),
          portraitWriterConfiguration: ProgramOutputEncodingConfiguration.make(
            configuration: portraitConfiguration),
          audioTracks: inputAudioTracks,
          recordsLandscape: output.recordsLandscape,
          recordsPortrait: output.recordsPortrait,
          customFields: output.recordingCustomFields,
          diagnosticsContext: diagnosticsContext,
          failureHandler: { [weak self] error in
            Task { @MainActor in await self?.fail(error) }
          })
        try recordService.start()
        workspaceSession.visionArchiveHandler = { [weak recordService] internalID, image, output in
          guard let recordService else { return }
          Self.archiveVisionResult(
            internalID: internalID, image: image, output: output,
            timelineMilliseconds: recordService.recordingTimelineMilliseconds(),
            packageDirectory: recordService.packageDirectory)
        }
        workspaceSession.visionArchiveTimelineProvider = recordService.recordingTimelineMilliseconds
        service = recordService
      } else {
        service = nil
      }
    } catch {
      state = .failed(error.localizedDescription)
      return
    }

    let landscapeHub = ProgramOutputMediaHub()
    let portraitHub = ProgramOutputMediaHub()
    let outputSession = ActiveDualProgramOutputSession(
      landscapeRuntime: landscapeRuntime,
      portraitRuntime: portraitRuntime,
      captureSessionCoordinator: workspaceSession.captureSessionCoordinator,
      landscapeMediaHub: landscapeHub,
      portraitMediaHub: portraitHub,
      portraitPreferences: portraitPreferences(for: selectedProgramInternalID),
      portraitAudioDeviceIDsByInputKey: audioDeviceIDsByInputKey(),
      runsLandscape: runsLandscape,
      runsPortrait: runsPortrait)
    if let service {
      installRecordingSubscriptions(
        service: service, landscapeHub: landscapeHub, portraitHub: portraitHub,
        recordsLandscape: output.recordsLandscape, recordsPortrait: output.recordsPortrait)
    }
    if let youtubeService {
      installYouTubeRTMPSSubscriptions(
        youtubeService, landscapeHub: landscapeHub, portraitHub: portraitHub)
      youtubeRTMPSService = youtubeService
    }
    activeSession = outputSession
    recordService = service
    self.landscapeHub = landscapeHub
    self.portraitHub = portraitHub

    do {
      if let service {
        try await installInputAudioSubscriptions(service: service, tracks: inputAudioTracks)
      }
      try await start(outputSession)
      if let youtubeRTMPSService {
        try await youtubeRTMPSService.waitUntilPublishing()
      }
      guard state == .starting else { return }
      state = .recording
    } catch {
      await fail(error)
    }
  }

  func stop() async {
    guard state == .starting || state == .recording || isFailed else { return }
    let priorFailure = failureMessage
    state = .stopping
    terminalFailureMessage = priorFailure
    if let activeSession { await stop(activeSession) }
    await unsubscribeAndDrain()
    if let recordService {
      await finalize(recordService)
    }
    if let youtubeRTMPSService {
      if case .failure(let error) = await youtubeRTMPSService.finish() {
        terminalFailureMessage = error.localizedDescription
      }
    }
    clearSessionReferences()
    state = terminalFailureMessage.map(State.failed) ?? .idle
    terminalFailureMessage = nil
  }

  func updateMixPreferences() {
    guard let activeSession, let programID = workspaceSession.selectedProgramInternalID else {
      return
    }
    activeSession.updateProgramPreferences(preferences(for: programID, role: .landscape))
    activeSession.updatePortraitProgramPreferences(portraitPreferences(for: programID))
  }

  func captureScreenshots() throws -> [URL] {
    guard let recordService else { throw ScreenCaptureError.frameUnavailable }
    var sources: [ScreenCaptureSource] = []
    if let frame = workspaceSession.runtime(for: .landscape)?.latestFrame() {
      sources.append(ScreenCaptureSource(name: "Landscape", pixelBuffer: frame.pixelBuffer))
    }
    if let frame = workspaceSession.runtime(for: .portrait)?.latestFrame() {
      sources.append(ScreenCaptureSource(name: "Portrait", pixelBuffer: frame.pixelBuffer))
    }
    for wrapper in workspaceSession.store.workspace.definition.definition.inputDevices {
      guard case .videoDevice(let input)? = wrapper.definition,
        let cameraID = workspaceSession.physicalVideoDeviceID(for: input.internalID),
        let frame = workspaceSession.captureSessionCoordinator.latestFrame(forCameraID: cameraID)
      else { continue }
      sources.append(ScreenCaptureSource(name: input.displayName, pixelBuffer: frame.pixelBuffer))
    }
    return try ScreenCaptureService().captureSet(
      sources: sources, capturedAt: Date(),
      recordingPackageDirectory: recordService.packageDirectory
    ).outputURLs
  }

  var screenshotsDirectory: URL? {
    recordService?.packageDirectory.appendingPathComponent("Screenshots", isDirectory: true)
  }

  private func installRecordingSubscriptions(
    service: SessionRecordService,
    landscapeHub: ProgramOutputMediaHub,
    portraitHub: ProgramOutputMediaHub,
    recordsLandscape: Bool,
    recordsPortrait: Bool
  ) {
    if recordsLandscape {
      landscapeSubscription = landscapeHub.subscribe(
        mainVideo: service.appendMainVideo,
        mainAudioMix: service.appendMainAudioMix,
        failureHandler: { [weak self] error in Task { @MainActor in await self?.fail(error) } })
    }
    if recordsPortrait {
      portraitSubscription = portraitHub.subscribe(
        mainVideo: service.appendPortraitVideo,
        mainAudioMix: service.appendPortraitAudioMix,
        failureHandler: { [weak self] error in Task { @MainActor in await self?.fail(error) } })
    }
  }

  private func installYouTubeRTMPSSubscriptions(
    _ service: YouTubeRTMPSWorkspaceService,
    landscapeHub: ProgramOutputMediaHub,
    portraitHub: ProgramOutputMediaHub
  ) {
    let output = workspaceSession.store.workspace.definition.definition.outputConfiguration
    switch output.resolvedYouTubeIngestMode {
    case .landscapeRtmps:
      youtubeLandscapeSubscription = landscapeHub.subscribe(
        mainVideo: service.appendLandscapeVideo,
        mainAudioMix: service.appendLandscapeAudioMix,
        failureHandler: service.failMediaDelivery)
    case .portraitRtmps:
      youtubePortraitSubscription = portraitHub.subscribe(
        mainVideo: service.appendPortraitVideo,
        mainAudioMix: service.appendPortraitAudioMix,
        failureHandler: service.failMediaDelivery)
    case .dualRtmps:
      youtubeLandscapeSubscription = landscapeHub.subscribe(
        mainVideo: service.appendLandscapeVideo,
        mainAudioMix: service.appendLandscapeAudioMix,
        failureHandler: service.failMediaDelivery)
      youtubePortraitSubscription = portraitHub.subscribe(
        mainVideo: service.appendPortraitVideo,
        mainAudioMix: service.appendPortraitAudioMix,
        failureHandler: service.failMediaDelivery)
    default:
      break
    }
  }

  private func start(_ session: ActiveDualProgramOutputSession) async throws {
    try await withCheckedThrowingContinuation { continuation in
      session.start(
        programPreferences: landscapePreferences,
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey(),
        eventHandler: { _ in },
        failureHandler: { [weak self] error in Task { @MainActor in await self?.fail(error) } },
        completionHandler: { continuation.resume(with: $0) })
    }
  }

  private func stop(_ session: ActiveDualProgramOutputSession) async {
    await withCheckedContinuation { continuation in
      session.stop { continuation.resume() }
    }
  }

  private func unsubscribeAndDrain() async {
    if let landscapeHub, let landscapeSubscription {
      _ = await landscapeHub.unsubscribeAndDrain(landscapeSubscription)
    }
    if let portraitHub, let portraitSubscription {
      _ = await portraitHub.unsubscribeAndDrain(portraitSubscription)
    }
    if let landscapeHub, let youtubeLandscapeSubscription {
      _ = await landscapeHub.unsubscribeAndDrain(youtubeLandscapeSubscription)
    }
    if let portraitHub, let youtubePortraitSubscription {
      _ = await portraitHub.unsubscribeAndDrain(youtubePortraitSubscription)
    }
    let subscriptions = inputAudioSubscriptions
    inputAudioSubscriptions = []
    for subscription in subscriptions {
      await withCheckedContinuation { continuation in
        workspaceSession.captureSessionCoordinator.unsubscribeAudio(subscription) {
          continuation.resume()
        }
      }
    }
  }

  private func installInputAudioSubscriptions(
    service: SessionRecordService,
    tracks: [SessionRecordAudioTrack]
  ) async throws {
    for track in tracks {
      guard state == .starting else { return }
      try await withCheckedThrowingContinuation { continuation in
        let subscription = workspaceSession.captureSessionCoordinator.subscribeAudio(
          deviceID: track.deviceID,
          failureHandler: { [weak self] failure in
            Task { @MainActor in await self?.fail(failure) }
          },
          sampleHandler: { sampleBuffer in
            service.appendInputAudio(sampleBuffer, trackID: track.trackID)
          },
          completionHandler: { result in
            continuation.resume(with: result)
          }
        )
        inputAudioSubscriptions.append(subscription)
      }
      guard state == .starting else { return }
    }
  }

  private func finalize(_ service: SessionRecordService) async {
    let result = await withCheckedContinuation { continuation in
      if service.recordingTimelineMilliseconds() == nil {
        service.cancelBeforeFirstVideo { continuation.resume(returning: $0) }
      } else {
        service.stop { continuation.resume(returning: $0) }
      }
    }
    if case .failed(let error) = result {
      terminalFailureMessage = error.localizedDescription
    }
  }

  private func fail(_ error: Error) async {
    guard state == .starting || state == .recording else { return }
    state = .failed(error.localizedDescription)
    await stop()
  }

  private func clearSessionReferences() {
    workspaceSession.visionArchiveHandler = nil
    workspaceSession.visionArchiveTimelineProvider = nil
    activeSession = nil
    recordService = nil
    youtubeRTMPSService = nil
    landscapeSubscription = nil
    portraitSubscription = nil
    youtubeLandscapeSubscription = nil
    youtubePortraitSubscription = nil
    inputAudioSubscriptions = []
    landscapeHub = nil
    portraitHub = nil
  }

  private static func archiveVisionResult(
    internalID: UInt64, image: CIImage, output: String, timelineMilliseconds: UInt64?,
    packageDirectory: URL
  ) {
    let directory = packageDirectory.appendingPathComponent("Visions", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = "vision-\(internalID)-\(UInt64(Date().timeIntervalSince1970 * 1_000))"
    let imageURL = directory.appendingPathComponent("\(stem).jpg")
    let metadataURL = directory.appendingPathComponent("\(stem).json")
    let context = CIContext(options: [.cacheIntermediates: false])
    if let cgImage = context.createCGImage(image, from: image.extent),
      let destination = CGImageDestinationCreateWithURL(
        imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    {
      CGImageDestinationAddImage(destination, cgImage, nil)
      _ = CGImageDestinationFinalize(destination)
    }
    var metadata: [String: String] = ["visionID": String(internalID), "output": output]
    if let timelineMilliseconds {
      metadata["recordingTimelineMilliseconds"] = String(timelineMilliseconds)
    }
    if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
      try? data.write(to: metadataURL, options: .atomic)
    }
  }

  private var isFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  private var failureMessage: String? {
    if case .failed(let message) = state { return message }
    return nil
  }

  private var landscapePreferences: ProgramPreferences {
    guard let id = workspaceSession.selectedProgramInternalID else { return ProgramPreferences() }
    return preferences(for: id, role: .landscape)
  }

  private func portraitPreferences(for programInternalID: UInt64) -> ProgramPreferences {
    preferences(
      for: programInternalID,
      role: workspaceSession.synchronizesLandscapeMixToPortrait(for: programInternalID)
        ? .landscape : .portrait)
  }

  private func preferences(for programInternalID: UInt64, role: ProgramCanvasRole)
    -> ProgramPreferences
  {
    let preference =
      workspaceSession.store.workspace.preferences.preferences.programPreferences[
        programInternalID] ?? .init()
    let gain =
      role == .landscape ? preference.landscapeMasterVolume : preference.portraitMasterVolume
    var preferences = ProgramPreferences(
      masterVolume: ProgramPreferences.linearAudioChannelGain(fromDecibels: gain))
    let gains =
      role == .landscape
      ? preference.landscapeAudioChannelGains : preference.portraitAudioChannelGains
    let muted =
      role == .landscape
      ? preference.landscapeAudioChannelMuted : preference.portraitAudioChannelMuted
    for inputDeviceInternalID in Set(gains.keys).union(muted.keys) {
      let key = "v4-\(inputDeviceInternalID)"
      preferences.audioChannelGainsByName[key] =
        ProgramPreferences.linearAudioChannelGain(fromDecibels: gains[inputDeviceInternalID] ?? 0)
      preferences.audioMutedByInputDeviceName[key] = muted[inputDeviceInternalID] ?? false
    }
    return preferences
  }

  private func audioDeviceIDsByInputKey() -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: workspaceSession.store.workspace.definition.definition.inputDevices
        .compactMap {
          guard case .audioDevice(let input)? = $0.definition,
            let physicalID = workspaceSession.physicalAudioDeviceID(for: input.internalID)
          else { return nil }
          return ("v4-\(input.internalID)", physicalID)
        })
  }

  private var inputAudioTracks: [SessionRecordAudioTrack] {
    let names: [String: String] = Dictionary(
      uniqueKeysWithValues:
        workspaceSession.store.workspace.definition.definition.inputDevices.compactMap { input in
          guard case .audioDevice(let device)? = input.definition else { return nil }
          return ("v4-\(device.internalID)", device.displayName)
        })
    return SessionRecordAudioTrack.make(
      deviceIDsByInputKey: audioDeviceIDsByInputKey(), deviceNamesByInputKey: names)
  }

  private func makeYouTubeRTMPSService(
    for output: Ldtx_Workspace_V4_OutputConfiguration
  ) throws -> YouTubeRTMPSWorkspaceService {
    let configurations = try YouTubeStreamKeyConfigurationStore().load()
    let destinations = try WorkspaceV4YouTubeRTMPSDestinationResolver.resolve(
      output: output, configurations: configurations,
      landscapeStreamID: workspaceSession.landscapeYouTubeLiveStreamID,
      portraitStreamID: workspaceSession.portraitYouTubeLiveStreamID)
    return YouTubeRTMPSWorkspaceService(
      destinations: destinations,
      failureHandler: { [weak self] error in
        Task { @MainActor in await self?.fail(error) }
      })
  }

  private func outputDirectory(for output: Ldtx_Workspace_V4_OutputConfiguration) -> URL {
    if output.hasOutputFolderPath, !output.outputFolderPath.isEmpty {
      return URL(fileURLWithPath: output.outputFolderPath, isDirectory: true)
    }
    if let path = applicationOutputPreferences.defaultOutputFolderPath,
      !path.isEmpty
    {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return DefaultLocalOutputService(fileManager: .default).defaultBaseDirectory
  }

  private var applicationOutputPreferences: ApplicationOutputPreferences {
    let defaults = UserDefaults.standard
    let currentData =
      defaults.data(forKey: "tokyo.kaito.ldtx.application-output-preferences.v1") ?? Data()
    let legacyData = defaults.data(forKey: "tokyo.kaito.ldtx.output-settings.v1") ?? Data()
    guard
      let data =
        try? ApplicationOutputPreferencesPersistenceCodec.migrateLegacyOutputSettingsIfNeeded(
          currentData: currentData, legacyData: legacyData),
      let preferences = try? ApplicationOutputPreferencesPersistenceCodec.decode(from: data)
    else { return ApplicationOutputPreferences() }
    return preferences
  }

  private func requestRequiredCaptureAccess(
    configurations: [ProgramRuntimeConfiguration]
  ) async throws {
    let requiresVideoAccess = configurations.contains { configuration in
      configuration.composite.steps.contains { step in
        guard case .inputCameraDevice(let input) = step.component,
          let inputDeviceID = input.inputDeviceID
        else { return false }
        return configuration.cameraIDsByInputKey[inputDeviceID] != nil
      }
    }
    let audioInputIDs = Set(
      configurations.flatMap { configuration in
        configuration.audioChannels.compactMap { channel -> UInt64? in
          guard case .inputAudioDevice(let input) = channel.component,
            let inputDeviceID = input.inputDeviceID,
            inputDeviceID.hasPrefix("v4-"),
            let id = UInt64(inputDeviceID.dropFirst(3))
          else { return nil }
          return id
        }
      })
    if requiresVideoAccess, await requestCaptureAccess(for: .video) == false {
      throw CameraCaptureServiceError.cameraAccessDenied
    }
    if audioInputIDs.contains(where: { workspaceSession.physicalAudioDeviceID(for: $0) != nil }),
      await requestCaptureAccess(for: .audio) == false
    {
      throw CameraCaptureServiceError.microphoneAccessDenied
    }
  }

  private func requestCaptureAccess(for mediaType: AVMediaType) async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
      true
    case .notDetermined:
      await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: mediaType) { continuation.resume(returning: $0) }
      }
    case .denied, .restricted:
      false
    @unknown default:
      false
    }
  }
}

enum WorkspaceV4YouTubeOutputError: LocalizedError, Equatable {
  case missingLandscapeStreamKey
  case missingPortraitStreamKey
  case unsupportedIngestMode

  var errorDescription: String? {
    switch self {
    case .missingLandscapeStreamKey:
      "Select a Landscape Stream Key before starting YouTube output."
    case .missingPortraitStreamKey:
      "Select a Portrait Stream Key before starting YouTube output."
    case .unsupportedIngestMode:
      "The selected YouTube ingest mode is not available for Version 4 Workspaces yet."
    }
  }
}

enum WorkspaceV4YouTubeRTMPSDestinationResolver {
  static func resolve(
    output: Ldtx_Workspace_V4_OutputConfiguration,
    configurations: [YouTubeRTMPSStreamKeyConfiguration],
    landscapeStreamID: String?,
    portraitStreamID: String?
  ) throws -> YouTubeRTMPSDestinations {
    let landscape = configurations.first { $0.id == landscapeStreamID }
    let portrait = configurations.first { $0.id == portraitStreamID }
    switch output.resolvedYouTubeIngestMode {
    case .landscapeRtmps:
      guard let landscape else { throw WorkspaceV4YouTubeOutputError.missingLandscapeStreamKey }
      return try YouTubeRTMPSDestinations(landscape: landscape.destination())
    case .portraitRtmps:
      guard let portrait else { throw WorkspaceV4YouTubeOutputError.missingPortraitStreamKey }
      return try YouTubeRTMPSDestinations(portrait: portrait.destination())
    case .dualRtmps:
      guard let landscape else { throw WorkspaceV4YouTubeOutputError.missingLandscapeStreamKey }
      guard let portrait else { throw WorkspaceV4YouTubeOutputError.missingPortraitStreamKey }
      return try YouTubeRTMPSDestinations(
        landscape: landscape.destination(), portrait: portrait.destination())
    default:
      throw WorkspaceV4YouTubeOutputError.unsupportedIngestMode
    }
  }
}
