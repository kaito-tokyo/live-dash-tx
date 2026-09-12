// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppKitUI
import LDTXAppUI
import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import LDTXRecording
import LDTXWorkspace
import LDTXYouTubeRTMPS
import SwiftUI
import UniformTypeIdentifiers

/// The native window for a Version 4 Workspace.
@MainActor
final class WorkspaceV4WindowController: NSWindowController, NSWindowDelegate {
  let session: WorkspaceV4RuntimeSession
  let split: PaneSplitViewController
  let recordingSession: WorkspaceV4RecordingSession
  let audioCoordinator: WorkspaceAudioCoordinator
  let visionFeature: any WorkspaceV4VisionFeatureProviding
  let request: WorkspaceWindowRequest
  var identityChanged: ((WorkspaceWindowRequest) -> Void)?
  private var isClosingAfterConfirmation = false

  init(
    request: WorkspaceWindowRequest,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry,
    diagnosticsContext: RecordingDiagnosticsContext? = nil
  ) {
    self.request = request
    let session = WorkspaceV4RuntimeSession(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
    self.session = session
    recordingSession = WorkspaceV4RecordingSession(
      workspaceSession: session,
      diagnosticsContext: diagnosticsContext)
    audioCoordinator = WorkspaceAudioCoordinator(
      captureSessionCoordinator: session.captureSessionCoordinator)
    visionFeature = AppFeatureRegistry.provider.makeV4VisionFeature()
    let synchronizeVision = { [weak session, weak visionFeature] in
      guard let session, let visionFeature else { return }
      visionFeature.synchronize(
        visions: session.store.workspace.definition.definition.visions,
        context: session.visionFeatureContext
      )
    }
    split = PaneSplitViewController(
      sidebar: paneHost(
        WorkspaceV4Sidebar(
          session: session,
          synchronizeVision: synchronizeVision,
          submitVision: { [weak session, weak visionFeature] id in
            guard let session, let visionFeature else { return }
            visionFeature.submit(visionInternalID: id, context: session.visionFeatureContext)
          },
          refreshOutputMix: { [weak recordingSession] in
            recordingSession?.updateMixPreferences()
          },
          outputIsActive: { [weak recordingSession] in recordingSession?.isRecording ?? false },
          synchronizeAudioMonitor: { [weak session, weak audioCoordinator] in
            guard let session, let audioCoordinator else { return }
            synchronizeV4AudioMonitor(session: session, audioCoordinator: audioCoordinator)
          })),
      content: paneHost(
        WorkspaceV4Content(
          session: session, recordingSession: recordingSession,
          saveBeforeStartingOutput: { [weak session] in
            guard let session, let url = session.url else { return false }
            if session.isDirty { try? session.save(to: url) }
            return !session.isDirty
          },
          synchronizeVision: synchronizeVision,
          synchronizeAudioMonitor: { [weak session, weak audioCoordinator] in
            guard let session, let audioCoordinator else { return }
            synchronizeV4AudioMonitor(session: session, audioCoordinator: audioCoordinator)
          })),
      inspector: paneHost(
        WorkspaceV4Inspector(session: session, recordingSession: recordingSession)),
      sidebarCanCollapse: true
    )
    let window = PaneWindow(contentViewController: split)
    window.title = "Workspace"
    window.titleVisibility = .hidden
    window.setContentSize(NSSize(width: 1062, height: 700))
    window.center()
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .unified
    super.init(window: window)
    window.delegate = self
    split.setInitialWidths(sidebar: 240, content: 480)
    session.installRuntime(
      AppFeatureRegistry.provider.makeProgramRuntime(
        captureSessionCoordinator: session.captureSessionCoordinator,
        programPreferencesState: ProgramPreferencesState(),
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry),
      role: .landscape)
    session.installRuntime(
      AppFeatureRegistry.provider.makeProgramRuntime(
        captureSessionCoordinator: session.captureSessionCoordinator,
        programPreferencesState: ProgramPreferencesState(),
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry),
      role: .portrait)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  @discardableResult
  func start() -> Bool {
    do {
      switch request.source {
      case .new:
        try session.create(displayName: "Untitled Workspace")
      case .file(let url):
        try session.open(at: url)
        configureRestoration(for: url)
      }
      visionFeature.synchronize(
        visions: session.store.workspace.definition.definition.visions,
        context: session.visionFeatureContext
      )
      return true
    } catch {
      present(error: error)
      return false
    }
  }

  func save() {
    guard let url = session.url else {
      saveAs()
      return
    }
    do { try session.save(to: url) } catch { present(error: error) }
  }

  func saveAs() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(importedAs: "tokyo.kaito.ldtx.workspace")]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Workspace.ldtxworkspace"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try session.save(to: url)
      configureRestoration(for: url)
      identityChanged?(WorkspaceWindowRequest.file(url))
    } catch { present(error: error) }
  }

  func reload() {
    guard !recordingSession.isRecording else { return }
    if session.isDirty {
      let alert = NSAlert()
      alert.messageText = "Discard unsaved changes and reload?"
      alert.informativeText = "The Workspace will be replaced with its saved state on disk."
      alert.addButton(withTitle: "Reload")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    do {
      try session.reloadFromDisk()
      let availableCameraIDs = Set(DefaultCaptureDeviceService().availableCameras().map(\.id))
      session.synchronizeCaptureInputs(availableCameraIDs: availableCameraIDs) { _ in }
      visionFeature.synchronize(
        visions: session.store.workspace.definition.definition.visions,
        context: session.visionFeatureContext)
      synchronizeAudioMonitor()
    } catch { present(error: error) }
  }

  func toggleInspector(_ sender: Any?) {
    split.toggleInspector(sender)
  }

  private func configureRestoration(for url: URL) {
    guard let window = window as? PaneWindow else { return }
    window.title = url.deletingPathExtension().lastPathComponent
    window.representedURL = url
    window.restorationURL = url
    window.restorationKind = "workspace"
    window.identifier =
      window.identifier
      ?? NSUserInterfaceItemIdentifier("WorkspaceV4.AppKit.v1." + UUID().uuidString)
    window.restorationClass = ApplicationWindowRestorer.self
    window.isRestorable = true
    window.invalidateRestorableState()
  }

  func closeWorkspace() async {
    visionFeature.stop()
    await recordingSession.stop()
    await withCheckedContinuation { continuation in
      session.captureSessionCoordinator.stopAndReset { continuation.resume() }
    }
    await audioCoordinator.stopAndReset()
    session.close()
  }

  func windowWillClose(_ notification: Notification) {
    visionFeature.stop()
    Task { await self.closeWorkspace() }
  }

  func confirmClose() -> Bool {
    confirmClose(stoppingOutput: false)
  }

  func confirmTermination() -> Bool {
    confirmClose(stoppingOutput: true)
  }

  func cancelTerminationConfirmation() {
    isClosingAfterConfirmation = false
  }

  private func confirmClose(stoppingOutput: Bool) -> Bool {
    guard stoppingOutput || !recordingSession.isRecording else {
      let alert = NSAlert()
      alert.messageText = "Stop output before closing this Workspace."
      alert.informativeText =
        "The active output session must be stopped before this Workspace can close."
      alert.runModal()
      return false
    }
    guard !isClosingAfterConfirmation, session.isDirty else { return true }

    let alert = NSAlert()
    alert.messageText = "Save changes to this Workspace?"
    alert.informativeText =
      "Your unsaved Workspace changes will be lost if you close without saving."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Discard")
    alert.alertStyle = .warning

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      save()
      guard !session.isDirty else { return false }
      isClosingAfterConfirmation = true
      return true
    case .alertThirdButtonReturn:
      isClosingAfterConfirmation = true
      return true
    default:
      return false
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }

  private func present(error: Error) {
    let alert = NSAlert(error: error)
    guard let window else {
      alert.runModal()
      return
    }
    alert.beginSheetModal(for: window)
  }

  private func synchronizeAudioMonitor() {
    synchronizeV4AudioMonitor(session: session, audioCoordinator: audioCoordinator)
  }
}

@MainActor
private func synchronizeV4AudioMonitor(
  session: WorkspaceV4RuntimeSession,
  audioCoordinator: WorkspaceAudioCoordinator
) {
  guard let programInternalID = session.selectedProgramInternalID,
    let projection = try? session.persistence.runtimeProjection(
      programInternalID: programInternalID, role: .landscape)
  else {
    Task { await audioCoordinator.stopAndReset() }
    return
  }
  let audioDeviceIDs = Dictionary(
    uniqueKeysWithValues:
      session.store.workspace.definition.definition.inputDevices.compactMap {
        input -> (String, String)? in
        guard case .audioDevice(let device)? = input.definition,
          let physicalID = session.physicalAudioDeviceID(for: device.internalID)
        else { return nil }
        return ("v4-\(device.internalID)", physicalID)
      })
  let monitoredKeys = Set(
    session.store.workspace.definition.definition.inputDevices.compactMap {
      input -> String? in
      guard case .audioDevice(let device)? = input.definition,
        session.monitorsAudioInputDevice(device.internalID)
      else { return nil }
      return "v4-\(device.internalID)"
    })
  var preferences = projection.preferences
  preferences.masterVolume = ProgramPreferences.linearAudioChannelGain(
    fromDecibels: session.store.workspace.preferences.preferences.monitorVolume)
  _ = audioCoordinator.restart(
    audioChannels: projection.configuration.audioChannels,
    inputAudioDeviceMappings: audioDeviceIDs,
    programPreferences: preferences,
    inputPassthroughChannelKeys: monitoredKeys,
    shouldRemainRunning: { true },
    failureHandler: { _ in },
    errorHandler: { _ in })
}

private struct WorkspaceV4Sidebar: View {
  @Bindable var session: WorkspaceV4RuntimeSession
  let synchronizeVision: () -> Void
  let submitVision: (UInt64) -> Void
  let refreshOutputMix: () -> Void
  let outputIsActive: () -> Bool
  let synchronizeAudioMonitor: () -> Void
  @State private var errorMessage: String?

  var body: some View {
    List {
      Section("Programs") {
        ForEach(session.store.workspace.definition.definition.programs, id: \.internalID) {
          program in
          HStack {
            Button(program.displayName) {
              session.selectedProgramInternalID = program.internalID
              synchronizeAudioMonitor()
              refreshOutputMix()
            }
            .buttonStyle(.plain)
            Spacer()
            Button(role: .destructive) {
              try? session.removeProgram(internalID: program.internalID)
              synchronizeAudioMonitor()
            } label: {
              Image(systemName: "minus")
            }
            .accessibilityLabel("Remove \(program.displayName)")
            .disabled(outputIsActive())
          }
        }
      }
      Section("Input Devices") {
        ForEach(session.store.workspace.definition.definition.inputDevices.indices, id: \.self) {
          index in
          let input = session.store.workspace.definition.definition.inputDevices[index]
          HStack {
            Text(inputLabel(input))
            Spacer()
            Button(role: .destructive) {
              removeInputDevice(input)
            } label: {
              Image(systemName: "minus")
            }
            .accessibilityLabel("Remove \(inputLabel(input))")
            .disabled(outputIsActive())
          }
        }
      }
      Section("Video Components") {
        ForEach(session.store.workspace.definition.definition.videoComponents.indices, id: \.self) {
          index in
          let component = session.store.workspace.definition.definition.videoComponents[index]
          HStack {
            Text(componentLabel(component))
            Spacer()
            Button(role: .destructive) {
              removeVideoComponent(component)
            } label: {
              Image(systemName: "minus")
            }
            .accessibilityLabel("Remove \(componentLabel(component))")
            .disabled(outputIsActive())
          }
        }
      }
      Section("Visions") {
        ForEach(session.store.workspace.definition.definition.visions.indices, id: \.self) {
          index in
          let vision = session.store.workspace.definition.definition.visions[index]
          VStack(alignment: .leading) {
            HStack {
              Text(visionLabel(vision))
              Spacer()
              Button(role: .destructive) {
                removeVision(vision)
              } label: {
                Image(systemName: "minus")
              }
              .accessibilityLabel("Remove \(visionLabel(vision))")
              .disabled(outputIsActive())
            }
            if case .ocrVision(let value)? = vision.definition,
              let result = session.visionResults[value.internalID]
            {
              Text(result).font(.caption).lineLimit(3)
            }
            if case .ocrVision(let value)? = vision.definition, value.triggers.isEmpty {
              Button("Analyze Current Frame") { submitVision(value.internalID) }
                .disabled(outputIsActive())
            }
            if case .ocrVision(let value)? = vision.definition,
              let failure = session.visionFailureMessages[value.internalID]
            {
              Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .alert(
      "Cannot Remove Resource",
      isPresented: Binding(
        get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func inputLabel(_ input: Ldtx_Workspace_V4_InputDeviceWrapper) -> String {
    switch input.definition {
    case .videoDevice(let device): device.displayName
    case .audioDevice(let device): device.displayName
    case nil: "Invalid Input Device"
    }
  }

  private func componentLabel(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> String {
    switch component.definition {
    case .vfxSource(let value): value.displayName
    case .solidColorFill(let value): value.displayName
    case .linearGradientFill(let value): value.displayName
    case .radialGradientFill(let value): value.displayName
    case .conicGradientFill(let value): value.displayName
    case .clock(let value): value.displayName
    case .testPattern(let value): value.displayName
    case nil: "Invalid Video Component"
    }
  }

  private func visionLabel(_ vision: Ldtx_Workspace_V4_VisionWrapper) -> String {
    switch vision.definition {
    case .ocrVision(let value): value.displayName
    case nil: "Invalid Vision"
    }
  }

  private func removeInputDevice(_ input: Ldtx_Workspace_V4_InputDeviceWrapper) {
    let internalID: UInt64
    switch input.definition {
    case .videoDevice(let value): internalID = value.internalID
    case .audioDevice(let value): internalID = value.internalID
    case nil: return
    }
    do {
      try session.store.removeInputDevice(internalID: internalID)
      session.updateRuntimes()
      synchronizeVision()
      let availableCameraIDs = Set(DefaultCaptureDeviceService().availableCameras().map(\.id))
      session.synchronizeCaptureInputs(availableCameraIDs: availableCameraIDs) { _ in }
      synchronizeAudioMonitor()
    } catch { errorMessage = error.localizedDescription }
  }

  private func removeVideoComponent(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) {
    guard let internalID = componentInternalID(component) else { return }
    do {
      try session.store.removeVideoComponent(internalID: internalID)
      session.updateRuntimes()
    } catch { errorMessage = error.localizedDescription }
  }

  private func removeVision(_ vision: Ldtx_Workspace_V4_VisionWrapper) {
    guard case .ocrVision(let value)? = vision.definition else { return }
    do {
      try session.store.removeVision(internalID: value.internalID)
      synchronizeVision()
    } catch { errorMessage = error.localizedDescription }
  }

  private func componentInternalID(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> UInt64?
  {
    switch component.definition {
    case .vfxSource(let value): value.internalID
    case .solidColorFill(let value): value.internalID
    case .linearGradientFill(let value): value.internalID
    case .radialGradientFill(let value): value.internalID
    case .conicGradientFill(let value): value.internalID
    case .clock(let value): value.internalID
    case .testPattern(let value): value.internalID
    case nil: nil
    }
  }
}

private struct WorkspaceV4Content: View {
  @Bindable var session: WorkspaceV4RuntimeSession
  @Bindable var recordingSession: WorkspaceV4RecordingSession
  let saveBeforeStartingOutput: () -> Bool
  let synchronizeVision: () -> Void
  let synchronizeAudioMonitor: () -> Void
  @State private var errorMessage: String?
  @State private var cameras: [CameraCaptureSource] = []
  @State private var audioDevices: [AudioCaptureSource] = []
  @State private var selectedVideoDeviceIDs: [UInt64: String] = [:]
  @State private var selectedAudioDeviceIDs: [UInt64: String] = [:]

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        Text(session.store.workspace.definition.definition.displayName)
          .font(.title2.weight(.semibold))
        HStack {
          Button("Add Program") { addProgram() }.disabled(recordingSession.isRecording)
          Button("Add Video Input") { addVideoInput() }.disabled(recordingSession.isRecording)
          Button("Add Audio Input") { addAudioInput() }.disabled(recordingSession.isRecording)
          Button("Add VFX Source") { addVFXSource() }
            .disabled(firstVideoInputID == nil || recordingSession.isRecording)
          Menu("Add Video Component") {
            Button("Solid Color") { addSolidColor() }
            Button("Linear Gradient") { addLinearGradient() }
            Button("Radial Gradient") { addRadialGradient() }
            Button("Conic Gradient") { addConicGradient() }
            Divider()
            Button("Clock") { addClock() }
            Button("Test Pattern") { addTestPattern() }
          }
          .disabled(recordingSession.isRecording)
          Button("Add OCR Vision") { addOcrVision() }
            .disabled(firstVideoInputID == nil || recordingSession.isRecording)
          Button(recordingSession.isRecording ? "Stop Output" : "Start Output") {
            Task {
              if recordingSession.isRecording {
                await recordingSession.stop()
              } else if saveBeforeStartingOutput() {
                await recordingSession.start()
              } else {
                errorMessage = "Save this Workspace before starting output."
              }
            }
          }
          if recordingSession.isRecording {
            Button("Capture Screenshot(s)") {
              do { _ = try recordingSession.captureScreenshots() } catch {
                errorMessage = error.localizedDescription
              }
            }
            Button("Open Screenshots Folder") {
              if let url = recordingSession.screenshotsDirectory {
                NSWorkspace.shared.open(url)
              }
            }
          }
        }
        if let landscapeRuntime = session.runtime(for: .landscape),
          let portraitRuntime = session.runtime(for: .portrait)
        {
          WorkspaceRuntimeCanvasPairPreview(
            landscapeRuntime: landscapeRuntime,
            portraitRuntime: portraitRuntime,
            landscapeSize: canvasSize(
              for: landscapeRuntime, fallback: CGSize(width: 1_920, height: 1_080)),
            portraitSize: canvasSize(
              for: portraitRuntime, fallback: CGSize(width: 1_080, height: 1_920))
          )
          .frame(maxWidth: .infinity)
          .accessibilityIdentifier("workspaceV4CanvasPreview")
        }
        videoLayers
        audioMix
        inputDeviceAssignments
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        if case .failed(let message) = recordingSession.state {
          Text(message).foregroundStyle(.red)
        }
        Spacer()
      }
      .padding(20)
    }
    .onAppear {
      refreshCaptureDevices()
      synchronizeAudioMonitor()
    }
    .onChange(of: session.url) { _, _ in
      refreshCaptureDevices()
      synchronizeAudioMonitor()
    }
  }

  private func addProgram() {
    do {
      let programID = try session.store.addProgram(displayName: uniqueProgramDisplayName("Program"))
      if session.selectedProgramInternalID == nil {
        session.selectedProgramInternalID = programID
      }
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
    synchronizeAudioMonitor()
  }
  private func addVideoInput() {
    perform { try session.store.addVideoInputDevice(displayName: uniqueDisplayName("Video Input")) }
  }
  private func addAudioInput() {
    perform { try session.store.addAudioInputDevice(displayName: uniqueDisplayName("Audio Input")) }
    synchronizeAudioMonitor()
  }
  private func addVFXSource() {
    guard let inputID = firstVideoInputID else { return }
    do {
      let componentID = try session.store.addVFXSource(
        displayName: uniqueDisplayName("VFX Source"), inputDeviceInternalID: inputID)
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addSolidColor() {
    do {
      var color = Ldtx_Workspace_V4_ExtendedSrgbColor()
      color.red = 0.2
      color.green = 0.2
      color.blue = 0.2
      color.alpha = 1
      let componentID = try session.store.addSolidColorFill(
        displayName: uniqueDisplayName("Solid Color"), color: color)
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addClock() {
    do {
      let componentID = try session.store.addClock(displayName: uniqueDisplayName("Clock"))
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addLinearGradient() {
    do {
      let componentID = try session.store.addLinearGradientFill(
        displayName: uniqueDisplayName("Linear Gradient"))
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addRadialGradient() {
    do {
      let componentID = try session.store.addRadialGradientFill(
        displayName: uniqueDisplayName("Radial Gradient"))
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addConicGradient() {
    do {
      let componentID = try session.store.addConicGradientFill(
        displayName: uniqueDisplayName("Conic Gradient"))
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addTestPattern() {
    do {
      let componentID = try session.store.addTestPattern(
        displayName: uniqueDisplayName("Test Pattern"))
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addOcrVision() {
    guard let inputID = firstVideoInputID else { return }
    perform {
      try session.store.addOcrVision(
        displayName: uniqueDisplayName("OCR Vision"), inputDeviceInternalID: inputID)
    }
    synchronizeVision()
  }

  private func addToSelectedProgram(_ videoLayerInternalID: UInt64) {
    guard let programID = session.selectedProgramInternalID else { return }
    for role in ProgramCanvasRole.allCases {
      let existing =
        session.store.workspace.definition.definition.programs.first {
          $0.internalID == programID
        }.map {
          role == .landscape ? $0.landscapeVideoLayerInternalIds : $0.portraitVideoLayerInternalIds
        }
        ?? []
      try? session.store.setVideoLayerOrder(
        existing + [videoLayerInternalID], forProgramInternalID: programID, role: role)
    }
  }

  private func uniqueDisplayName(_ base: String) -> String {
    let definition = session.store.workspace.definition.definition
    let names = Set(
      definition.inputDevices.compactMap { wrapper -> String? in
        switch wrapper.definition {
        case .videoDevice(let value): value.displayName
        case .audioDevice(let value): value.displayName
        case nil: nil
        }
      }
        + definition.videoComponents.compactMap { wrapper -> String? in
          switch wrapper.definition {
          case .solidColorFill(let value): value.displayName
          case .linearGradientFill(let value): value.displayName
          case .radialGradientFill(let value): value.displayName
          case .conicGradientFill(let value): value.displayName
          case .vfxSource(let value): value.displayName
          case .clock(let value): value.displayName
          case .testPattern(let value): value.displayName
          case nil: nil
          }
        }
        + definition.visions.compactMap { wrapper -> String? in
          guard case .ocrVision(let value)? = wrapper.definition else { return nil }
          return value.displayName
        })
    guard names.contains(base) else { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
  }

  private func uniqueProgramDisplayName(_ base: String) -> String {
    let names = Set(session.store.workspace.definition.definition.programs.map(\.displayName))
    guard names.contains(base) else { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
  }

  @ViewBuilder
  private var videoLayers: some View {
    if let selectedProgram {
      GroupBox("Video Layers") {
        VStack(alignment: .leading) {
          videoLayerList(for: selectedProgram, role: .landscape, title: "Landscape")
          videoLayerList(for: selectedProgram, role: .portrait, title: "Portrait")
        }
      }
    }
  }

  private func videoLayerList(
    for program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole,
    title: String
  ) -> some View {
    let layerIDs =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    return VStack(alignment: .leading) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Menu("Add Video Layer") {
          ForEach(availableVideoLayerIDs(for: program, role: role), id: \.self) { internalID in
            Button(videoLayerDisplayName(for: internalID)) {
              addVideoLayer(internalID, to: program, role: role)
            }
          }
        }
        .disabled(availableVideoLayerIDs(for: program, role: role).isEmpty)
      }
      if layerIDs.isEmpty {
        Text("No video layers").foregroundStyle(.secondary)
      }
      ForEach(Array(layerIDs.enumerated()), id: \.element) { index, internalID in
        VStack(alignment: .leading) {
          HStack {
            Text(videoLayerDisplayName(for: internalID))
            Spacer()
            Button {
              moveVideoLayer(in: program, role: role, from: index, offset: -1)
            } label: {
              Image(systemName: "arrow.up")
            }
            .disabled(index == 0)
            Button {
              moveVideoLayer(in: program, role: role, from: index, offset: 1)
            } label: {
              Image(systemName: "arrow.down")
            }
            .disabled(index == layerIDs.count - 1)
            Button {
              removeVideoLayer(in: program, role: role, at: index)
            } label: {
              Image(systemName: "minus")
            }
            .accessibilityLabel("Remove \(videoLayerDisplayName(for: internalID)) from \(title)")
          }
          WorkspaceV4LayerTransformEditor(
            session: session, programInternalID: program.internalID,
            role: role, videoLayerInternalID: internalID)
        }
      }
    }
  }

  private var selectedProgram: Ldtx_Workspace_V4_ProgramDefinition? {
    guard let id = session.selectedProgramInternalID else { return nil }
    return session.store.workspace.definition.definition.programs.first { $0.internalID == id }
  }

  @ViewBuilder
  private var audioMix: some View {
    if let selectedProgram, !audioInputs.isEmpty {
      GroupBox("Audio Mix") {
        VStack(alignment: .leading) {
          audioMix(
            role: .landscape, title: "Landscape", programInternalID: selectedProgram.internalID)
          HStack {
            Text("Monitor").frame(width: 96, alignment: .leading)
            Slider(value: monitorVolumeBinding, in: -60...12)
          }
          ForEach(audioInputs, id: \.internalID) { input in
            Toggle("Monitor \(input.displayName)", isOn: monitorBinding(for: input.internalID))
              .toggleStyle(.checkbox)
          }
          Toggle(
            "Sync Landscape Mix to Portrait",
            isOn: Binding(
              get: { session.synchronizesLandscapeMixToPortrait(for: selectedProgram.internalID) },
              set: {
                session.setSynchronizesLandscapeMixToPortrait($0, for: selectedProgram.internalID)
                recordingSession.updateMixPreferences()
              }
            ))
          audioMix(
            role: .portrait, title: "Portrait", programInternalID: selectedProgram.internalID)
        }
      }
    }
  }

  private func audioMix(
    role: ProgramCanvasRole,
    title: String,
    programInternalID: UInt64
  ) -> some View {
    VStack(alignment: .leading) {
      Text(title).font(.headline)
      HStack {
        Text("Master").frame(width: 96, alignment: .leading)
        Slider(value: masterVolumeBinding(for: programInternalID, role: role), in: -60...12)
      }
      ForEach(audioInputs, id: \.internalID) { input in
        HStack {
          Text(input.displayName).frame(width: 96, alignment: .leading)
          Slider(
            value: audioGainBinding(
              for: input.internalID, programInternalID: programInternalID, role: role), in: -60...12
          )
          Toggle(
            "Mute",
            isOn: audioMuteBinding(
              for: input.internalID, programInternalID: programInternalID, role: role)
          )
          .toggleStyle(.checkbox)
        }
      }
    }
  }

  private func masterVolumeBinding(
    for programInternalID: UInt64,
    role: ProgramCanvasRole
  ) -> Binding<Double> {
    Binding(
      get: {
        let preference = session.store.workspace.preferences.preferences.programPreferences[
          programInternalID]
        return role == .landscape
          ? preference?.landscapeMasterVolume ?? 0 : preference?.portraitMasterVolume ?? 0
      },
      set: { value in
        try? session.store.setMasterVolume(value, programInternalID: programInternalID, role: role)
        session.updateRuntimes()
        recordingSession.updateMixPreferences()
        synchronizeAudioMonitor()
      })
  }

  private func audioGainBinding(
    for inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) -> Binding<Double> {
    Binding(
      get: {
        let preference = session.store.workspace.preferences.preferences.programPreferences[
          programInternalID]
        return role == .landscape
          ? preference?.landscapeAudioChannelGains[inputDeviceInternalID] ?? 0
          : preference?.portraitAudioChannelGains[inputDeviceInternalID] ?? 0
      },
      set: { value in
        try? session.store.setAudioChannelGain(
          value, forAudioInputDeviceInternalID: inputDeviceInternalID,
          programInternalID: programInternalID, role: role)
        session.updateRuntimes()
        recordingSession.updateMixPreferences()
        synchronizeAudioMonitor()
      })
  }

  private func audioMuteBinding(
    for inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) -> Binding<Bool> {
    Binding(
      get: {
        let preference = session.store.workspace.preferences.preferences.programPreferences[
          programInternalID]
        return role == .landscape
          ? preference?.landscapeAudioChannelMuted[inputDeviceInternalID] ?? false
          : preference?.portraitAudioChannelMuted[inputDeviceInternalID] ?? false
      },
      set: { value in
        try? session.store.setAudioChannelMuted(
          value, forAudioInputDeviceInternalID: inputDeviceInternalID,
          programInternalID: programInternalID, role: role)
        session.updateRuntimes()
        recordingSession.updateMixPreferences()
        synchronizeAudioMonitor()
      })
  }

  private var monitorVolumeBinding: Binding<Double> {
    Binding(
      get: { session.store.workspace.preferences.preferences.monitorVolume },
      set: { value in
        try? session.store.setMonitorVolume(value)
        synchronizeAudioMonitor()
      })
  }

  private func monitorBinding(for inputDeviceInternalID: UInt64) -> Binding<Bool> {
    Binding(
      get: { session.monitorsAudioInputDevice(inputDeviceInternalID) },
      set: { enabled in
        session.setMonitorsAudioInputDevice(enabled, for: inputDeviceInternalID)
        synchronizeAudioMonitor()
      })
  }

  private func moveVideoLayer(
    in program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole,
    from index: Int,
    offset: Int
  ) {
    var layerIDs =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    let destination = index + offset
    guard layerIDs.indices.contains(index), layerIDs.indices.contains(destination) else { return }
    layerIDs.swapAt(index, destination)
    performLayerOrderUpdate(layerIDs, for: program.internalID, role: role)
  }

  private func removeVideoLayer(
    in program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole,
    at index: Int
  ) {
    var layerIDs =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    guard layerIDs.indices.contains(index) else { return }
    layerIDs.remove(at: index)
    performLayerOrderUpdate(layerIDs, for: program.internalID, role: role)
  }

  private func availableVideoLayerIDs(
    for program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole
  ) -> [UInt64] {
    let usedIDs = Set(
      role == .landscape
        ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds)
    let inputIDs = session.store.workspace.definition.definition.inputDevices.compactMap {
      input -> UInt64? in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return device.internalID
    }
    let componentIDs = session.store.workspace.definition.definition.videoComponents.compactMap {
      componentInternalID($0)
    }
    return (inputIDs + componentIDs).filter { !usedIDs.contains($0) }
  }

  private func addVideoLayer(
    _ internalID: UInt64,
    to program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole
  ) {
    let existing =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    performLayerOrderUpdate(existing + [internalID], for: program.internalID, role: role)
  }

  private func performLayerOrderUpdate(
    _ layerIDs: [UInt64], for programInternalID: UInt64, role: ProgramCanvasRole
  ) {
    do {
      try session.store.setVideoLayerOrder(
        layerIDs, forProgramInternalID: programInternalID, role: role)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func videoLayerDisplayName(for internalID: UInt64) -> String {
    if let input = session.store.workspace.definition.definition.inputDevices.first(where: {
      input in
      switch input.definition {
      case .videoDevice(let device): device.internalID == internalID
      case .audioDevice, nil: false
      }
    }), case .videoDevice(let device)? = input.definition {
      return device.displayName
    }
    if let component = session.store.workspace.definition.definition.videoComponents.first(where: {
      componentInternalID($0) == internalID
    }) {
      return componentDisplayName(component)
    }
    return "Missing Video Layer"
  }

  private func componentInternalID(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> UInt64?
  {
    switch component.definition {
    case .vfxSource(let value): value.internalID
    case .solidColorFill(let value): value.internalID
    case .linearGradientFill(let value): value.internalID
    case .radialGradientFill(let value): value.internalID
    case .conicGradientFill(let value): value.internalID
    case .clock(let value): value.internalID
    case .testPattern(let value): value.internalID
    case nil: nil
    }
  }

  private func componentDisplayName(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> String
  {
    switch component.definition {
    case .vfxSource(let value): value.displayName
    case .solidColorFill(let value): value.displayName
    case .linearGradientFill(let value): value.displayName
    case .radialGradientFill(let value): value.displayName
    case .conicGradientFill(let value): value.displayName
    case .clock(let value): value.displayName
    case .testPattern(let value): value.displayName
    case nil: "Invalid Video Component"
    }
  }

  private var firstVideoInputID: UInt64? {
    session.store.workspace.definition.definition.inputDevices.compactMap { input -> UInt64? in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return device.internalID
    }.first
  }

  @ViewBuilder
  private var inputDeviceAssignments: some View {
    if !videoInputs.isEmpty || !audioInputs.isEmpty {
      GroupBox("Physical Devices") {
        VStack(alignment: .leading) {
          ForEach(videoInputs, id: \.internalID) { input in
            Picker(input.displayName, selection: videoDeviceBinding(for: input.internalID)) {
              Text("No camera").tag("")
              ForEach(cameras) { camera in
                Text(camera.name).tag(camera.id)
              }
            }
          }
          ForEach(audioInputs, id: \.internalID) { input in
            Picker(input.displayName, selection: audioDeviceBinding(for: input.internalID)) {
              Text("No audio device").tag("")
              ForEach(audioDevices) { device in
                Text(device.name).tag(device.id)
              }
            }
            .disabled(recordingSession.isRecording)
          }
          Button("Refresh Physical Devices") { refreshCaptureDevices() }
        }
      }
    }
  }

  private var videoInputs: [Ldtx_Workspace_V4_VideoInputDevice] {
    session.store.workspace.definition.definition.inputDevices.compactMap { input in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return device
    }
  }

  private var audioInputs: [Ldtx_Workspace_V4_AudioInputDevice] {
    session.store.workspace.definition.definition.inputDevices.compactMap { input in
      guard case .audioDevice(let device)? = input.definition else { return nil }
      return device
    }
  }

  private func videoDeviceBinding(for internalID: UInt64) -> Binding<String> {
    Binding(
      get: { selectedVideoDeviceIDs[internalID] ?? "" },
      set: { id in
        selectedVideoDeviceIDs[internalID] = id
        session.setPhysicalVideoDeviceID(id.isEmpty ? nil : id, for: internalID)
        synchronizeCaptureInputs()
      })
  }

  private func audioDeviceBinding(for internalID: UInt64) -> Binding<String> {
    Binding(
      get: { selectedAudioDeviceIDs[internalID] ?? "" },
      set: { id in
        selectedAudioDeviceIDs[internalID] = id
        session.setPhysicalAudioDeviceID(id.isEmpty ? nil : id, for: internalID)
        synchronizeCaptureInputs()
        synchronizeAudioMonitor()
      })
  }

  private func refreshCaptureDevices() {
    let service = DefaultCaptureDeviceService()
    cameras = service.availableCameras()
    audioDevices = service.availableAudioDevices()
    selectedVideoDeviceIDs = Dictionary(
      uniqueKeysWithValues: videoInputs.compactMap { input in
        session.physicalVideoDeviceID(for: input.internalID).map { (input.internalID, $0) }
      })
    selectedAudioDeviceIDs = Dictionary(
      uniqueKeysWithValues: audioInputs.compactMap { input in
        session.physicalAudioDeviceID(for: input.internalID).map { (input.internalID, $0) }
      })
    synchronizeCaptureInputs()
  }

  private func synchronizeCaptureInputs() {
    session.synchronizeCaptureInputs(availableCameraIDs: Set(cameras.map(\.id))) { failedIDs in
      guard !failedIDs.isEmpty else { return }
      Task { @MainActor in
        errorMessage =
          "Assigned camera(s) are unavailable: \(failedIDs.sorted().joined(separator: ", "))"
      }
    }
  }

  private func canvasSize(for runtime: ProgramRuntime, fallback: CGSize) -> CGSize {
    runtime.programState.read { configuration in
      guard let configuration, configuration.canvasWidth > 0, configuration.canvasHeight > 0 else {
        return fallback
      }
      return CGSize(width: configuration.canvasWidth, height: configuration.canvasHeight)
    }
  }

  private func perform(_ action: () throws -> UInt64) {
    do {
      let id = try action()
      if session.selectedProgramInternalID == nil,
        session.store.workspace.definition.definition.programs.contains(where: {
          $0.internalID == id
        })
      {
        session.selectedProgramInternalID = id
      } else {
        session.updateRuntimes()
      }
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }
}

private struct WorkspaceV4LayerTransformEditor: View {
  @Bindable var session: WorkspaceV4RuntimeSession
  let programInternalID: UInt64
  let role: ProgramCanvasRole
  let videoLayerInternalID: UInt64

  var body: some View {
    DisclosureGroup("Transform") {
      VStack(alignment: .leading) {
        transformSlider("X", value: valueBinding(\.translationX, defaultValue: 0), range: 0...1)
        transformSlider("Y", value: valueBinding(\.translationY, defaultValue: 0), range: 0...1)
        transformSlider("Scale X", value: valueBinding(\.scaleX, defaultValue: 1), range: 0.01...2)
        transformSlider("Scale Y", value: valueBinding(\.scaleY, defaultValue: 1), range: 0.01...2)
      }
      .padding(.leading)
    }
  }

  private func transformSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>)
    -> some View
  {
    HStack {
      Text(title).frame(width: 56, alignment: .leading)
      Slider(value: value, in: range)
    }
  }

  private func valueBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_BasicTransform, Float>,
    defaultValue: Float
  ) -> Binding<Double> {
    Binding(
      get: {
        let value = transform[keyPath: keyPath]
        return Double(value == 0 && defaultValue != 0 ? defaultValue : value)
      },
      set: { value in
        var transform = transform
        transform[keyPath: keyPath] = Float(value)
        try? session.store.setBasicTransform(
          transform, forVideoLayerInternalID: videoLayerInternalID,
          programInternalID: programInternalID, role: role)
        session.updateRuntimes()
      }
    )
  }

  private var transform: Ldtx_Workspace_V4_BasicTransform {
    let preference = session.store.workspace.preferences.preferences.programPreferences[
      programInternalID]
    let transforms =
      role == .landscape
      ? preference?.landscapeVideoLayerTransforms : preference?.portraitVideoLayerTransforms
    return transforms?[videoLayerInternalID] ?? .init()
  }
}

private struct WorkspaceV4StreamKeyManager: View {
  @Environment(\.dismiss) private var dismiss
  @State private var drafts: [YouTubeRTMPSStreamKeyConfiguration]
  let load: () throws -> [YouTubeRTMPSStreamKeyConfiguration]
  let save: ([YouTubeRTMPSStreamKeyConfiguration]) throws -> Void
  @State private var errorMessage: String?

  init(
    configurations: [YouTubeRTMPSStreamKeyConfiguration],
    load: @escaping () throws -> [YouTubeRTMPSStreamKeyConfiguration],
    save: @escaping ([YouTubeRTMPSStreamKeyConfiguration]) throws -> Void
  ) {
    _drafts = State(initialValue: configurations)
    self.load = load
    self.save = save
  }

  var body: some View {
    NavigationStack {
      Form {
        Button("Add Configuration") { drafts.append(.init()) }
        ForEach($drafts) { $configuration in
          Section {
            TextField("Name", text: $configuration.name)
            TextField("Stream URL", text: $configuration.streamURL)
            TextField("Backup Server URL", text: $configuration.backupServerURL)
            SecureField("Stream Key", text: $configuration.streamKey)
            Button("Delete Configuration", role: .destructive) {
              drafts.removeAll { $0.id == configuration.id }
            }
          }
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      .navigationTitle("Manage Stream Keys")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              try save(drafts)
              dismiss()
            } catch { errorMessage = "The stream key configurations could not be saved." }
          }
        }
      }
    }
    .frame(minWidth: 520, minHeight: 360)
    .onAppear {
      do { drafts = try load() } catch {
        errorMessage = "The stream key configurations could not be loaded."
      }
    }
  }
}

private struct WorkspaceV4Inspector: View {
  @Bindable var session: WorkspaceV4RuntimeSession
  @Bindable var recordingSession: WorkspaceV4RecordingSession
  @State private var streamKeyConfigurations: [YouTubeRTMPSStreamKeyConfiguration] = []
  @State private var isShowingStreamKeyManager = false
  var body: some View {
    Form {
      Section("Workspace") {
        Text(workspaceStateLabel)
          .foregroundStyle(.secondary)
      }
      Section("Canvas") {
        Stepper("Frame Rate: \(frameRate)", value: frameRateBinding, in: 1...240)
          .disabled(recordingSession.isRecording)
      }
      Section("Output") {
        TextField("Recording Folder", text: outputFolderPathBinding)
        Group {
          Toggle("Record Landscape", isOn: outputBinding(\.recordsLandscape))
          Toggle("Record Portrait", isOn: outputBinding(\.recordsPortrait))
          Toggle("Stream to YouTube", isOn: outputBinding(\.streamsToYoutube))
          Picker("YouTube Ingest", selection: ingestModeBinding) {
            ForEach(ingestModes, id: \.rawValue) { mode in
              Text(ingestModeLabel(mode)).tag(mode)
            }
          }
          if !isAvailableIngestMode(
            session.store.workspace.definition.definition.outputConfiguration
              .resolvedYouTubeIngestMode)
          {
            Text("This YouTube ingest mode is not available yet.")
              .foregroundStyle(.secondary)
          }
          if usesLandscapeRTMPS {
            streamKeyPicker("Landscape Stream Key", selection: landscapeStreamKeyBinding)
          }
          if usesPortraitRTMPS {
            streamKeyPicker("Portrait Stream Key", selection: portraitStreamKeyBinding)
          }
          Button("Manage Stream Keys") { isShowingStreamKeyManager = true }
            .popover(isPresented: $isShowingStreamKeyManager) {
              WorkspaceV4StreamKeyManager(
                configurations: streamKeyConfigurations,
                load: { try YouTubeStreamKeyConfigurationStore().load() },
                save: { configurations in
                  try YouTubeStreamKeyConfigurationStore().save(configurations)
                  streamKeyConfigurations = configurations
                }
              )
            }
        }
        .disabled(recordingSession.isRecording)
      }
    }
    .padding(16)
    .onAppear { streamKeyConfigurations = (try? YouTubeStreamKeyConfigurationStore().load()) ?? [] }
  }

  private var frameRate: Int {
    let value = session.store.workspace.definition.definition.canvasConfiguration.frameRate
    return value == 0 ? 60 : Int(value)
  }

  private var workspaceStateLabel: String {
    guard session.url != nil else { return "Unsaved Workspace" }
    return session.isDirty ? "Unsaved changes" : "Saved"
  }

  private var frameRateBinding: Binding<Int> {
    Binding(
      get: { frameRate },
      set: { value in
        session.store.editDefinition { $0.canvasConfiguration.frameRate = UInt32(value) }
        session.updateRuntimes()
        let availableCameraIDs = Set(DefaultCaptureDeviceService().availableCameras().map(\.id))
        session.synchronizeCaptureInputs(availableCameraIDs: availableCameraIDs) { _ in }
      }
    )
  }

  private func outputBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_OutputConfiguration, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { session.store.workspace.definition.definition.outputConfiguration[keyPath: keyPath] },
      set: { value in
        session.store.editDefinition { definition in
          definition.outputConfiguration[keyPath: keyPath] = value
        }
      }
    )
  }

  private var ingestModeBinding: Binding<Ldtx_Workspace_V4_YouTubeIngestMode> {
    Binding(
      get: {
        session.store.workspace.definition.definition.outputConfiguration.resolvedYouTubeIngestMode
      },
      set: { value in
        session.store.editDefinition { $0.outputConfiguration.youtubeIngestMode = value }
      }
    )
  }

  private var outputFolderPathBinding: Binding<String> {
    Binding(
      get: {
        let output = session.store.workspace.definition.definition.outputConfiguration
        return output.hasOutputFolderPath ? output.outputFolderPath : ""
      },
      set: { path in
        session.store.editDefinition { definition in
          if path.isEmpty {
            definition.outputConfiguration.clearOutputFolderPath()
          } else {
            definition.outputConfiguration.outputFolderPath = path
          }
        }
      }
    )
  }

  private var ingestModes: [Ldtx_Workspace_V4_YouTubeIngestMode] {
    [
      .landscapeRtmps, .portraitRtmps, .dualRtmps,
    ]
  }

  private func isAvailableIngestMode(_ mode: Ldtx_Workspace_V4_YouTubeIngestMode) -> Bool {
    switch mode {
    case .landscapeRtmps, .portraitRtmps, .dualRtmps: true
    default: false
    }
  }

  private var usesLandscapeRTMPS: Bool {
    switch session.store.workspace.definition.definition.outputConfiguration
      .resolvedYouTubeIngestMode
    {
    case .landscapeRtmps, .dualRtmps: true
    default: false
    }
  }

  private var usesPortraitRTMPS: Bool {
    switch session.store.workspace.definition.definition.outputConfiguration
      .resolvedYouTubeIngestMode
    {
    case .portraitRtmps, .dualRtmps: true
    default: false
    }
  }

  private var landscapeStreamKeyBinding: Binding<String> {
    Binding(
      get: { session.landscapeYouTubeLiveStreamID ?? "" },
      set: { session.setLandscapeYouTubeLiveStreamID($0.isEmpty ? nil : $0) })
  }

  private var portraitStreamKeyBinding: Binding<String> {
    Binding(
      get: { session.portraitYouTubeLiveStreamID ?? "" },
      set: { session.setPortraitYouTubeLiveStreamID($0.isEmpty ? nil : $0) })
  }

  private func streamKeyPicker(_ title: String, selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      Text("Select Stream Key").tag("")
      ForEach(streamKeyConfigurations) { configuration in
        Text(configuration.name).tag(configuration.id)
      }
    }
  }

  private func ingestModeLabel(_ mode: Ldtx_Workspace_V4_YouTubeIngestMode) -> String {
    switch mode {
    case .landscapeRtmps: "Landscape RTMPS"
    case .portraitRtmps: "Portrait RTMPS"
    case .dualRtmps: "Dual RTMPS"
    case .landscapeHls: "Landscape HLS"
    case .portraitHls: "Portrait HLS"
    case .landscapeDash: "Landscape DASH"
    case .portraitDash: "Portrait DASH"
    case .unspecified, .UNRECOGNIZED: "Unspecified"
    }
  }
}
