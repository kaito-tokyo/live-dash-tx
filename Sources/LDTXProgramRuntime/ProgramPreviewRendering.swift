// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Combine
import CoreMedia
import CoreVideo
import Foundation
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import OSLog
import os

/// A revision token whose value is meaningful only within the lock-protected
/// state that produced it.
///
/// Revision IDs are equality tokens, not sequence numbers that can be compared
/// across two state instances. A state begins at a random positive 32-bit seed
/// and each published change advances the same ID by exactly one.
public typealias OpaqueRevisionID = Int64

private enum OpaqueRevisionIDs {
  /// Keeping IDs positive prevents a signed overflow from silently producing
  /// a value whose ordering suggests a different generation.
  static let lowerBound: OpaqueRevisionID = 1
  static let upperBound: OpaqueRevisionID = .max

  static func initial() -> OpaqueRevisionID {
    OpaqueRevisionID(UInt32.random(in: UInt32(lowerBound) ... .max))
  }

  static func next(after revision: OpaqueRevisionID) -> OpaqueRevisionID {
    precondition(
      (lowerBound...upperBound).contains(revision),
      "Opaque revision IDs must remain within their positive range."
    )
    precondition(
      revision < upperBound,
      "Opaque revision ID space is exhausted; create a new lock-local state instead."
    )
    return revision + 1
  }
}

/// A lock-local opaque-revision mix-in.
///
/// `opaqueRevisionID` is deliberately not part of a protobuf message. It is a
/// process-local coordination token, so its scope is the enclosing
/// `OSAllocatedUnfairLock`, not the persisted Program definition. State
/// structures conform directly, so they can add coherent cached or derived
/// fields without being constrained to a generic value wrapper.
public protocol ProgramRevisioned {
  var opaqueRevisionID: OpaqueRevisionID { get set }
}

extension ProgramRevisioned {
  public mutating func advanceRevision() {
    opaqueRevisionID = OpaqueRevisionIDs.next(after: opaqueRevisionID)
  }
}

public enum ProgramPreviewError: Error {
  case pixelBufferCreationFailed
}

public struct ProgramRuntimeConfiguration: Sendable {
  public var outputProfile: ProgramOutputProfile
  public var composite: CompositeProgramDefinition
  public var audioChannels: [ProgramAudioChannel]
  public var canvasWidth: Int
  public var canvasHeight: Int
  public var outputWidth: Int
  public var outputHeight: Int
  public var frameRate: Int
  public var timeSeconds: Float
  /// Physical camera ID for the Workspace-level PTS master.
  /// `nil` means this runtime uses the host clock.
  public var videoPTSMasterCameraID: String?
  public var cameraIDsByInputKey: [String: String]
  public var inputDeviceNamesByInputKey: [String: String]
  public var cameraInputColorOverrides: [String: CameraInputColorRangeOverride]
  public var backgroundRemovalInputKeys: Set<String>
  public var videoLayerProgramName: String

  public init(
    composite: CompositeProgramDefinition,
    audioChannels: [ProgramAudioChannel],
    outputProfile: ProgramOutputProfile = .sdr1080p60,
    canvasWidth: Int,
    canvasHeight: Int,
    outputWidth: Int,
    outputHeight: Int,
    frameRate: Int,
    timeSeconds: Float,
    videoPTSMasterCameraID: String?,
    cameraIDsByInputKey: [String: String],
    inputDeviceNamesByInputKey: [String: String] = [:],
    cameraInputColorOverrides: [String: CameraInputColorRangeOverride],
    backgroundRemovalInputKeys: Set<String>,
    videoLayerProgramName: String = "New Program"
  ) {
    self.outputProfile =
      outputProfile.width == outputWidth
        && outputProfile.height == outputHeight
        && outputProfile.frameRate == frameRate
      ? outputProfile
      : ProgramOutputProfile(
        id: "runtime-\(outputWidth)x\(outputHeight)p\(frameRate)",
        width: outputWidth,
        height: outputHeight,
        frameRate: frameRate,
        videoBitRate: outputProfile.videoBitRate,
        audioSampleRate: outputProfile.audioSampleRate,
        audioChannelCount: outputProfile.audioChannelCount,
        audioBitRate: outputProfile.audioBitRate,
        targetSegmentDurationSeconds: outputProfile.targetSegmentDurationSeconds
      )
    self.composite = composite
    self.audioChannels = audioChannels
    self.canvasWidth = canvasWidth
    self.canvasHeight = canvasHeight
    self.outputWidth = outputWidth
    self.outputHeight = outputHeight
    self.frameRate = frameRate
    self.timeSeconds = timeSeconds
    self.videoPTSMasterCameraID = videoPTSMasterCameraID
    self.cameraIDsByInputKey = cameraIDsByInputKey
    self.inputDeviceNamesByInputKey = inputDeviceNamesByInputKey
    self.cameraInputColorOverrides = cameraInputColorOverrides
    self.backgroundRemovalInputKeys = backgroundRemovalInputKeys
    self.videoLayerProgramName = videoLayerProgramName
  }

  public var diagnosticDescription: String {
    "canvas=\(canvasWidth)x\(canvasHeight), output=\(outputWidth)x\(outputHeight), fps=\(frameRate), videoPTSMasterCameraID=\(videoPTSMasterCameraID ?? "hostClock"), cameraIDs=\(cameraIDsByInputKey), inputDeviceNames=\(inputDeviceNamesByInputKey), cameraInputColorOverrides=\(cameraInputColorOverrides), backgroundRemovalInputKeys=\(backgroundRemovalInputKeys.sorted()), audioChannels=\(audioChannels.map { $0.component.definition.rawValue }.joined(separator: ",")), steps=\(composite.steps.map { $0.component.definition.rawValue }.joined(separator: ","))"
  }
}

extension ProgramRuntimeConfiguration {
  func hasEquivalentInputPipeline(to other: Self) -> Bool {
    canvasWidth == other.canvasWidth && canvasHeight == other.canvasHeight
      && outputWidth == other.outputWidth && outputHeight == other.outputHeight
      && frameRate == other.frameRate && videoPTSMasterCameraID == other.videoPTSMasterCameraID
      && cameraIDsByInputKey == other.cameraIDsByInputKey
      && inputDeviceNamesByInputKey == other.inputDeviceNamesByInputKey
      && cameraInputColorOverrides == other.cameraInputColorOverrides
      && backgroundRemovalInputKeys == other.backgroundRemovalInputKeys
      && videoLayerProgramName == other.videoLayerProgramName
      && audioChannels == other.audioChannels
      && composite.normalizingInputDeviceDestinations()
        == other.composite.normalizingInputDeviceDestinations()
  }
}

extension CompositeProgramDefinition {
  fileprivate func normalizingInputDeviceDestinations() -> Self {
    var normalized = self
    for index in normalized.steps.indices {
      guard case .inputCameraDevice(var component) = normalized.steps[index].component else {
        continue
      }
      component.destination = InputDeviceDestination()
      normalized.steps[index].component = .inputCameraDevice(component)
    }
    return normalized
  }
}

/// The single shared mutable Program state used by preview and output consumers.
///
/// The value stored here is the runtime projection of the protobuf-backed Program
/// definition. Consumers borrow or copy it only while holding the OS allocated
/// unfair lock; they do not maintain independent preview/output mailboxes.
public final class ProgramRuntimeState: @unchecked Sendable {
  private struct RuntimeContext: Sendable {
    var canvasWidth: Int
    var canvasHeight: Int
    var outputWidth: Int
    var outputHeight: Int
    var frameRate: Int
    var timeSeconds: Float
    var cameraIDsByInputKey: [String: String]
    var inputDeviceNamesByInputKey: [String: String]
    var cameraInputColorOverrides: [String: CameraInputColorRangeOverride]
    var backgroundRemovalInputKeys: Set<String>
    var videoLayerProgramName: String
    var videoPTSMasterCameraID: String?

    init(configuration: ProgramRuntimeConfiguration) {
      canvasWidth = configuration.canvasWidth
      canvasHeight = configuration.canvasHeight
      outputWidth = configuration.outputWidth
      outputHeight = configuration.outputHeight
      frameRate = configuration.frameRate
      timeSeconds = configuration.timeSeconds
      cameraIDsByInputKey = configuration.cameraIDsByInputKey
      inputDeviceNamesByInputKey = configuration.inputDeviceNamesByInputKey
      cameraInputColorOverrides = configuration.cameraInputColorOverrides
      backgroundRemovalInputKeys = configuration.backgroundRemovalInputKeys
      videoLayerProgramName = configuration.videoLayerProgramName
      videoPTSMasterCameraID = configuration.videoPTSMasterCameraID
    }

    func makeConfiguration(
      composite: CompositeProgramDefinition
    ) -> ProgramRuntimeConfiguration {
      return ProgramRuntimeConfiguration(
        composite: composite,
        audioChannels: composite.audioChannels,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
        frameRate: frameRate,
        timeSeconds: timeSeconds,
        videoPTSMasterCameraID: videoPTSMasterCameraID,
        cameraIDsByInputKey: cameraIDsByInputKey,
        inputDeviceNamesByInputKey: inputDeviceNamesByInputKey,
        cameraInputColorOverrides: cameraInputColorOverrides,
        backgroundRemovalInputKeys: backgroundRemovalInputKeys,
        videoLayerProgramName: videoLayerProgramName
      )
    }
  }

  /// The protobuf representation remains the persisted source of truth, but
  /// is never exposed as mutable shared runtime state. The configuration is
  /// decoded once while replacing the revisioned value, not by every frame
  /// reader.
  private struct ProgramValue: Sendable {
    let message: Ldtx_Program_V1_Program
    let configuration: ProgramRuntimeConfiguration

    init(configuration: ProgramRuntimeConfiguration) {
      var programDefinition = configuration.composite
      programDefinition.audioChannels = configuration.audioChannels
      let message = ProgramPersistenceCodec.encodeProgram(programDefinition)
      var composite = ProgramPersistenceCodec.decodeProgram(message)
      composite.restoreRuntimeDestinations(from: configuration.composite)

      self.message = message
      self.configuration = RuntimeContext(configuration: configuration)
        .makeConfiguration(composite: composite)
    }

  }

  private struct Storage: Sendable, ProgramRevisioned {
    /// Retains a stable revision before the first Program is installed.
    var opaqueRevisionID = OpaqueRevisionIDs.initial()
    var program: ProgramValue?
  }

  private let storage = OSAllocatedUnfairLock(initialState: Storage())

  public init(configuration: ProgramRuntimeConfiguration? = nil) {
    if let configuration {
      replace(with: configuration)
    }
  }

  public func replace(with configuration: ProgramRuntimeConfiguration) {
    storage.withLock {
      guard $0.program?.configuration.hasEquivalentInputPipeline(to: configuration) != true else {
        return
      }
      $0.program = ProgramValue(configuration: configuration)
      $0.advanceRevision()
    }
  }

  public func clear() {
    storage.withLock {
      guard $0.program != nil else { return }
      $0.program = nil
      $0.advanceRevision()
    }
  }

  public func read<T: Sendable>(
    _ body: @Sendable (ProgramRuntimeConfiguration?) throws -> T
  ) rethrows -> T {
    let configuration = storage.withLock { state in
      state.program?.configuration
    }
    return try body(configuration)
  }

  public var opaqueRevisionID: OpaqueRevisionID {
    storage.withLock(\.opaqueRevisionID)
  }
}

extension CompositeProgramDefinition {
  fileprivate mutating func restoreRuntimeDestinations(from source: CompositeProgramDefinition) {
    let sourceByName = Dictionary(
      source.steps.map { ($0.name, $0.component) },
      uniquingKeysWith: { first, _ in first })
    for index in steps.indices {
      guard let sourceComponent = sourceByName[steps[index].name] else { continue }
      switch (steps[index].component, sourceComponent) {
      case (.inputCameraDevice(var component), .inputCameraDevice(let source)):
        component.destination = source.destination
        steps[index].component = .inputCameraDevice(component)
      case (.clock(var component), .clock(let source)):
        component.destinationX = source.destinationX
        component.destinationY = source.destinationY
        component.destinationWidth = source.destinationWidth
        component.destinationHeight = source.destinationHeight
        steps[index].component = .clock(component)
      default:
        continue
      }
    }
  }
}

/// The revisioned canvas placement for one Program Runtime.
///
/// Destination updates are deliberately kept out of `ProgramRuntimeState`:
/// they alter only compositor command arguments and must not make the input
/// preprocessing pipeline reconsider its camera, crop, or removal setup.
public final class ProgramDestinationState: @unchecked Sendable {
  private struct ClockDestination: Equatable, Sendable {
    var x: Float
    var y: Float
    var width: Float
    var height: Float
  }

  private struct Storage: Sendable, ProgramRevisioned {
    var opaqueRevisionID = OpaqueRevisionIDs.initial()
    var destinationsByStepName: [String: InputDeviceDestination] = [:]
    var clockDestinationsByStepName: [String: ClockDestination] = [:]
  }

  private let storage = OSAllocatedUnfairLock(initialState: Storage())

  public init(composite: CompositeProgramDefinition = CompositeProgramDefinition()) {
    replace(with: composite)
  }

  public func replace(with composite: CompositeProgramDefinition) {
    let destinations = Self.destinations(in: composite)
    let clockDestinations = Self.clockDestinations(in: composite)
    storage.withLock {
      guard
        $0.destinationsByStepName != destinations
          || $0.clockDestinationsByStepName != clockDestinations
      else { return }
      $0.destinationsByStepName = destinations
      $0.clockDestinationsByStepName = clockDestinations
      $0.advanceRevision()
    }
  }

  public func destination(forStepNamed name: String) -> InputDeviceDestination? {
    storage.withLock { $0.destinationsByStepName[name] }
  }

  public var opaqueRevisionID: OpaqueRevisionID {
    storage.withLock(\.opaqueRevisionID)
  }

  public func applying(to composite: CompositeProgramDefinition) -> CompositeProgramDefinition {
    let clockDestinations = storage.withLock(\.clockDestinationsByStepName)
    guard !clockDestinations.isEmpty else { return composite }
    var result = composite
    for index in result.steps.indices {
      let step = result.steps[index]
      guard case .clock(var component) = step.component,
        let destination = clockDestinations[step.name]
      else { continue }
      component.destinationX = destination.x
      component.destinationY = destination.y
      component.destinationWidth = destination.width
      component.destinationHeight = destination.height
      result.steps[index].component = .clock(component)
    }
    return result
  }

  private static func destinations(
    in composite: CompositeProgramDefinition
  ) -> [String: InputDeviceDestination] {
    var destinations: [String: InputDeviceDestination] = [:]
    for step in composite.steps {
      guard case .inputCameraDevice(let component) = step.component,
        destinations[step.name] == nil
      else { continue }
      destinations[step.name] = component.destination
    }
    return destinations
  }

  private static func clockDestinations(
    in composite: CompositeProgramDefinition
  ) -> [String: ClockDestination] {
    var destinations: [String: ClockDestination] = [:]
    for step in composite.steps {
      guard case .clock(let component) = step.component,
        destinations[step.name] == nil
      else { continue }
      destinations[step.name] = ClockDestination(
        x: component.destinationX,
        y: component.destinationY,
        width: component.destinationWidth,
        height: component.destinationHeight
      )
    }
    return destinations
  }
}

/// Shared, revisioned Workspace preferences consumed by every Program Runtime.
///
/// The value and its revision live under the same OS-allocated lock so render
/// queues can read a coherent Preferences value without copying it into each
/// Runtime when the Workspace changes it.
public final class ProgramPreferencesState: @unchecked Sendable {
  private struct Storage: Sendable, ProgramRevisioned {
    var opaqueRevisionID = OpaqueRevisionIDs.initial()
    var preferences = ProgramPreferences()
  }

  private let storage = OSAllocatedUnfairLock(initialState: Storage())

  public init(preferences: ProgramPreferences = ProgramPreferences()) {
    storage.withLock { $0.preferences = preferences }
  }

  public func replace(with preferences: ProgramPreferences) {
    storage.withLock {
      guard $0.preferences != preferences else { return }
      $0.preferences = preferences
      $0.advanceRevision()
    }
  }

  public func read<T: Sendable>(
    _ body: @Sendable (ProgramPreferences) throws -> T
  ) rethrows -> T {
    try storage.withLock { state in
      try body(state.preferences)
    }
  }

  public var opaqueRevisionID: OpaqueRevisionID {
    storage.withLock(\.opaqueRevisionID)
  }
}

public final class ProgramPreviewController: ObservableObject, @unchecked Sendable {
  private enum Backend {
    case runtime(ProgramRuntime)
    case standalone(ActiveProgramRenderer)
  }

  private let lock = NSLock()
  private let backend: Backend
  private let scheduler: any ProgramRuntimeScheduling
  private let renderQueue = DispatchQueue(
    label: "tokyo.kaito.ldtx.ProgramPreviewController.render", qos: .userInitiated)
  private var renderTimer: DispatchSourceTimer?
  private var framePacer = ProgramFramePacer()
  private let programState: ProgramRuntimeState
  private var latestRenderedFrame: ProgramFrame?
  private var sessionID = 0
  private var nextRenderedFrameID: UInt64 = 0
  private var isPreviewRunning = false
  private var preferredFrameRate: Int?

  public init(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry,
    clockCurrentTimeProvider: any ClockCurrentTimeProviding = SystemClockCurrentTimeProvider(),
    scheduler: any ProgramRuntimeScheduling = SystemProgramRuntimeScheduler()
  ) {
    programState = ProgramRuntimeState()
    backend = .standalone(
      ActiveProgramRenderer(
        captureSessionCoordinator: captureSessionCoordinator,
        backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        clockCurrentTimeProvider: clockCurrentTimeProvider
      )
    )
    self.scheduler = scheduler
  }

  public init(programRuntime: ProgramRuntime) {
    programState = programRuntime.programState
    backend = .runtime(programRuntime)
    scheduler = SystemProgramRuntimeScheduler()
  }

  deinit {
    stop()
  }

  public func configure(configuration: ProgramRuntimeConfiguration) {
    switch backend {
    case .runtime(let programRuntime):
      programRuntime.updateProgram(configuration)
    case .standalone:
      let previousSize = programState.read { configuration in
        configuration.map { ($0.outputWidth, $0.outputHeight) }
      }
      programState.replace(with: configuration)
      lock.lock()
      let shouldClearFrame =
        previousSize?.0 != configuration.outputWidth
        || previousSize?.1 != configuration.outputHeight
      if shouldClearFrame {
        latestRenderedFrame = nil
      }
      lock.unlock()
    }
  }

  public func updateProgramPreferences(_ preferences: ProgramPreferences) {
    switch backend {
    case .runtime(let programRuntime):
      programRuntime.updateProgramPreferences(preferences)
    case .standalone(let previewRenderer):
      previewRenderer.updateProgramPreferences(preferences)
    }
  }

  /// A Preview-only pacing preference. It never changes the shared Program
  /// Runtime configuration used by Output sessions.
  public func setPreferredFrameRate(_ frameRate: Int?) {
    lock.withLock {
      preferredFrameRate = frameRate.map { max($0, 1) }
    }
  }

  public func start() {
    switch backend {
    case .runtime(let programRuntime):
      let shouldStart = lock.withLock { () -> Bool in
        guard !isPreviewRunning else {
          return false
        }
        isPreviewRunning = true
        return true
      }
      if shouldStart {
        programRuntime.startPreview()
      }
    case .standalone(let previewRenderer):
      let currentSessionID: Int
      lock.lock()
      guard renderTimer == nil else {
        lock.unlock()
        return
      }
      sessionID += 1
      currentSessionID = sessionID
      let timer = DispatchSource.makeTimerSource(queue: renderQueue)
      timer.setEventHandler { [weak self] in
        self?.renderTick(sessionID: currentSessionID)
      }
      renderTimer = timer
      lock.unlock()

      renderQueue.async { [weak self, previewRenderer] in
        self?.framePacer = ProgramFramePacer()
        previewRenderer.beginSession(currentSessionID)
        timer.schedule(deadline: .now())
        timer.resume()
      }
    }
  }

  public func stop() {
    switch backend {
    case .runtime(let programRuntime):
      let shouldStop = lock.withLock { () -> Bool in
        guard isPreviewRunning else {
          return false
        }
        isPreviewRunning = false
        return true
      }
      if shouldStop {
        programRuntime.stopPreview()
      }
    case .standalone(let previewRenderer):
      let currentSessionID: Int
      lock.lock()
      currentSessionID = sessionID
      renderTimer?.setEventHandler {}
      renderTimer?.cancel()
      renderTimer = nil
      latestRenderedFrame = nil
      lock.unlock()

      renderQueue.async {
        previewRenderer.endSession(currentSessionID)
      }
    }
  }

  public func latestFrame() -> ProgramFrame? {
    switch backend {
    case .runtime(let programRuntime):
      programRuntime.latestFrame()
    case .standalone:
      lock.withLock {
        latestRenderedFrame
      }
    }
  }

  public func latestPixelBuffer() -> CVPixelBuffer? {
    latestFrame()?.pixelBuffer
  }

  public func isPreparingRenderResources() -> Bool {
    latestFrame()?.isPreparingRenderResources ?? false
  }

  private func nextStandaloneFrameID() -> UInt64 {
    lock.withLock {
      nextRenderedFrameID &+= 1
      return nextRenderedFrameID
    }
  }

  private func setLatestFrame(_ frame: ProgramFrame) {
    lock.withLock {
      latestRenderedFrame = frame
    }
  }

  private func renderTick(sessionID: Int) {
    dispatchPrecondition(condition: .onQueue(renderQueue))
    guard case .standalone(let previewRenderer) = backend else {
      return
    }
    guard
      let timer = lock.withLock({ () -> DispatchSourceTimer? in
        guard self.sessionID == sessionID else { return nil }
        return renderTimer
      })
    else {
      previewRenderer.endSession(sessionID)
      return
    }
    guard var configuration = programState.read({ $0 }) else {
      timer.schedule(deadline: .now() + .milliseconds(100))
      return
    }
    let preferredFrameRate = lock.withLock { self.preferredFrameRate }
    let delayNanoseconds = framePacer.delayBeforeNextFrame(
      nowNanoseconds: scheduler.nowNanoseconds,
      frameRate: preferredFrameRate ?? configuration.frameRate
    )
    if delayNanoseconds > 0 {
      timer.schedule(deadline: .now() + .nanoseconds(Int(clamping: delayNanoseconds)))
      return
    }
    configuration.timeSeconds = Float(scheduler.uptimeSeconds)
    do {
      var frame = try previewRenderer.render(
        configuration: configuration,
        sessionID: sessionID,
        frameID: nextStandaloneFrameID()
      )
      if frame.presentationTime == nil,
        configuration.videoPTSMasterCameraID == nil
      {
        frame.presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
      }
      setLatestFrame(frame)
    } catch {
      if error is CancellationError {
        return
      }
      logProgramPreviewRenderFailed(error, configuration: configuration)
    }
    timer.schedule(deadline: .now())
  }
}

private func logProgramPreviewRenderFailed(
  _ error: Error, configuration: ProgramRuntimeConfiguration
) {
  let nsError = error as NSError
  programPreviewLogger.error(
    "Program preview render failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) canvasWidth=\(configuration.canvasWidth, privacy: .public) canvasHeight=\(configuration.canvasHeight, privacy: .public) outputWidth=\(configuration.outputWidth, privacy: .public) outputHeight=\(configuration.outputHeight, privacy: .public) frameRate=\(configuration.frameRate, privacy: .public) timeSeconds=\(configuration.timeSeconds, privacy: .public) cameraInputCount=\(configuration.cameraIDsByInputKey.count, privacy: .public) backgroundRemovalInputCount=\(configuration.backgroundRemovalInputKeys.count, privacy: .public) stepCount=\(configuration.composite.steps.count, privacy: .public)"
  )
}

private let programPreviewLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "ProgramPreview"
)
