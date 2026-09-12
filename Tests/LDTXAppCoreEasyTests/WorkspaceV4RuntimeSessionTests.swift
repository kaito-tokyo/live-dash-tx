// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgramRuntime
import LDTXWorkspace
import LDTXYouTubeRTMPS
import Testing

@testable import LDTXAppCore

@MainActor
@Suite("Version 4 Workspace runtime session")
struct WorkspaceV4RuntimeSessionIntegrationTestSuite {
  @Test("resolves a selected single-Canvas V4 RTMPS destination")
  func resolvesSingleCanvasRTMPSDestination() throws {
    var output = Ldtx_Workspace_V4_OutputConfiguration()
    output.youtubeIngestMode = .landscapeRtmps
    let configuration = YouTubeRTMPSStreamKeyConfiguration(
      id: "landscape", name: "Landscape", streamURL: "rtmps://a.rtmp.youtube.com/live2",
      streamKey: "landscape-key")

    let destinations = try WorkspaceV4YouTubeRTMPSDestinationResolver.resolve(
      output: output, configurations: [configuration], landscapeStreamID: "landscape",
      portraitStreamID: nil)

    #expect(destinations.canvases == [.landscape])
    #expect(destinations.landscape?.streamName == "landscape-key")
  }

  @Test("uses Landscape RTMPS for an unspecified V4 ingest mode")
  func resolvesUnspecifiedIngestModeAsLandscapeRTMPS() throws {
    let output = Ldtx_Workspace_V4_OutputConfiguration()
    let configuration = YouTubeRTMPSStreamKeyConfiguration(
      id: "landscape", name: "Landscape", streamURL: "rtmps://a.rtmp.youtube.com/live2",
      streamKey: "landscape-key")

    let destinations = try WorkspaceV4YouTubeRTMPSDestinationResolver.resolve(
      output: output, configurations: [configuration], landscapeStreamID: "landscape",
      portraitStreamID: nil)

    #expect(destinations.canvases == [.landscape])
    #expect(destinations.landscape?.streamName == "landscape-key")
  }

  @Test("rejects V4 RTMPS without the selected Stream Key")
  func rejectsMissingRTMPSStreamKey() {
    var output = Ldtx_Workspace_V4_OutputConfiguration()
    output.youtubeIngestMode = .portraitRtmps

    #expect(throws: WorkspaceV4YouTubeOutputError.missingPortraitStreamKey) {
      try WorkspaceV4YouTubeRTMPSDestinationResolver.resolve(
        output: output, configurations: [], landscapeStreamID: nil, portraitStreamID: nil)
    }
  }

  @Test("resolves a V4 OCR Vision by internal ID without a V3 definition")
  func resolvesV4VisionFromTheRuntimeSession() throws {
    let session = try makeSession(capture: WorkspaceCaptureSessionCoordinator())
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = 42
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
    session.store.editDefinition { $0.visions = [wrapper] }

    #expect(session.visionFeatureContext.vision(42) == vision)
  }

  @Test("saves and opens a V4 package without a V3 session")
  func savesAndOpensV4Package() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Unite.ldtxworkspace")
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    let programID = try session.store.addProgram(displayName: "Main")

    try session.save(to: packageURL)
    #expect(session.url == packageURL)
    #expect(!session.isDirty)
    session.close()

    let reopened = try makeSession(capture: capture)
    try reopened.open(at: packageURL)
    #expect(reopened.store.workspace.definition.definition.programs.map(\.displayName) == ["Main"])
    #expect(reopened.selectedProgramInternalID == programID)
    reopened.close()
  }

  @Test("installs the selected V4 Program directly into both runtimes")
  func installsSelectedProgramIntoRuntimes() throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    let programID = try session.store.addProgram(displayName: "Main")
    let landscape = ProgramRuntime(
      captureSessionCoordinator: capture,
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(),
      scheduler: ManualProgramRuntimeScheduler())
    let portrait = ProgramRuntime(
      captureSessionCoordinator: capture,
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(),
      scheduler: ManualProgramRuntimeScheduler())
    session.installRuntime(landscape, role: .landscape)
    session.installRuntime(portrait, role: .portrait)
    session.selectedProgramInternalID = programID

    #expect(landscape.programState.read { $0?.videoLayerProgramName } == "v4-\(programID)")
    #expect(portrait.programState.read { $0?.videoLayerProgramName } == "v4-\(programID)")
  }

  @Test("selects the next Program after removing the current V4 Program")
  func selectsNextProgramAfterRemovingCurrentProgram() throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    let first = try session.store.addProgram(displayName: "First")
    let second = try session.store.addProgram(displayName: "Second")
    session.selectedProgramInternalID = first

    try session.removeProgram(internalID: first)

    #expect(session.selectedProgramInternalID == second)
  }

  @Test("keeps unsaved physical camera assignments in the V4 runtime")
  func keepsUnsavedPhysicalCameraAssignmentsInRuntime() throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    let videoInputID = try session.store.addVideoInputDevice(displayName: "Camera")
    let programID = try session.store.addProgram(displayName: "Main")
    try session.store.setVideoLayerOrder(
      [videoInputID], forProgramInternalID: programID, role: .landscape)
    let runtime = ProgramRuntime(
      captureSessionCoordinator: capture,
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(),
      scheduler: ManualProgramRuntimeScheduler())
    session.installRuntime(runtime, role: .landscape)
    session.selectedProgramInternalID = programID

    session.setPhysicalVideoDeviceID("camera-id", for: videoInputID)

    #expect(session.physicalVideoDeviceID(for: videoInputID) == "camera-id")
    #expect(
      runtime.programState.read { $0?.cameraIDsByInputKey } == ["v4-\(videoInputID)": "camera-id"])
  }

  @Test("moves unsaved physical assignments into Save As local state")
  func movesUnsavedPhysicalAssignmentsIntoSaveAsLocalState() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let suiteName = "WorkspaceV4RuntimeSessionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = WorkspaceV4RuntimeSession(
      persistence: try WorkspaceV4PersistenceCoordinator(
        store: WorkspaceV4Store(cleanNamed: "Unite"),
        localStateStorage: WorkspaceLocalStateStorage(userDefaults: defaults)),
      captureSessionCoordinator: capture)
    let videoInputID = try session.store.addVideoInputDevice(displayName: "Camera")
    session.setPhysicalVideoDeviceID("camera-id", for: videoInputID)

    try session.save(to: rootURL.appendingPathComponent("Unite.ldtxworkspace"))

    #expect(session.physicalVideoDeviceID(for: videoInputID) == "camera-id")
  }

  @Test("rejects V4 recording before a Program is selected")
  func rejectsRecordingWithoutASelectedProgram() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    let recording = WorkspaceV4RecordingSession(workspaceSession: session)

    await recording.start()

    #expect(recording.state == .failed("Select a Program before starting recording."))
  }

  @Test("retries V4 recording after correcting its validation")
  func retriesRecordingAfterCorrectingValidation() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    let recording = WorkspaceV4RecordingSession(workspaceSession: session)
    await recording.start()
    let programID = try session.store.addProgram(displayName: "Main")
    session.selectedProgramInternalID = programID

    await recording.start()

    #expect(recording.state == .failed("Enable recording or YouTube streaming in Output settings."))
  }

  @Test("does not start V4 YouTube output without a selected Program runtime")
  func rejectsYouTubeOutputWithoutARuntime() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    let recording = WorkspaceV4RecordingSession(workspaceSession: session)
    session.selectedProgramInternalID = try session.store.addProgram(displayName: "Main")
    session.store.editDefinition { $0.outputConfiguration.streamsToYoutube = true }

    await recording.start()

    #expect(recording.state == .failed("The selected Program runtime is unavailable."))
  }

  private func makeSession(
    capture: WorkspaceCaptureSessionCoordinator
  ) throws -> WorkspaceV4RuntimeSession {
    WorkspaceV4RuntimeSession(
      persistence: try WorkspaceV4PersistenceCoordinator(
        store: WorkspaceV4Store(cleanNamed: "Unite")),
      captureSessionCoordinator: capture
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
