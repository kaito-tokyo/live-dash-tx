// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXProgram

/// Owns the fixed Landscape and Portrait output pipelines for one Workspace
/// output operation. Capture and the session clock are shared upstream; each
/// child owns an independent compositor subscription, audio mixer, H.264
/// encoder, AAC path, and media hub.
@MainActor
public final class ActiveDualProgramOutputSession {
  public let landscape: ActiveProgramOutputSession
  public let portrait: ActiveProgramOutputSession
  public let landscapeMediaHub: ProgramOutputMediaHub
  public let portraitMediaHub: ProgramOutputMediaHub

  private var portraitPreferences: ProgramPreferences
  private var portraitAudioDeviceIDsByInputKey: [String: String]
  private let runsLandscape: Bool
  private let runsPortrait: Bool

  public init(
    landscapeRuntime: ProgramRuntime,
    portraitRuntime: ProgramRuntime,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    landscapeMediaHub: ProgramOutputMediaHub = ProgramOutputMediaHub(),
    portraitMediaHub: ProgramOutputMediaHub = ProgramOutputMediaHub(),
    portraitPreferences: ProgramPreferences = ProgramPreferences(),
    portraitAudioDeviceIDsByInputKey: [String: String] = [:],
    runsLandscape: Bool = true,
    runsPortrait: Bool = true,
    programRuntimeTransitionStateHandler: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
  ) {
    self.landscapeMediaHub = landscapeMediaHub
    self.portraitMediaHub = portraitMediaHub
    self.portraitPreferences = portraitPreferences
    self.portraitAudioDeviceIDsByInputKey = portraitAudioDeviceIDsByInputKey
    self.runsLandscape = runsLandscape
    self.runsPortrait = runsPortrait
    let transition = DualTransitionState(handler: programRuntimeTransitionStateHandler)
    landscape = ActiveProgramOutputSession(
      currentProgramRuntime: landscapeRuntime,
      mediaHub: landscapeMediaHub,
      captureSessionCoordinator: captureSessionCoordinator,
      programRuntimeTransitionStateHandler: { transition.setLandscape($0) }
    )
    portrait = ActiveProgramOutputSession(
      currentProgramRuntime: portraitRuntime,
      mediaHub: portraitMediaHub,
      captureSessionCoordinator: captureSessionCoordinator,
      programRuntimeTransitionStateHandler: { transition.setPortrait($0) }
    )
  }

  public var isRunning: Bool {
    (!runsLandscape || landscape.isRunning) && (!runsPortrait || portrait.isRunning)
  }

  public func configurePortrait(
    preferences: ProgramPreferences,
    audioDeviceIDsByInputKey: [String: String]
  ) {
    portraitPreferences = preferences
    portraitAudioDeviceIDsByInputKey = audioDeviceIDsByInputKey
    if isRunning {
      _ = portrait.reconfigureAudio(
        programPreferences: preferences,
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey)
    }
  }

  public func start(
    programPreferences: ProgramPreferences,
    audioDeviceIDsByInputKey: [String: String],
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void,
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard !runsLandscape || landscape.hasConfiguredAudioMix,
      !runsPortrait || portrait.hasConfiguredAudioMix
    else {
      completionHandler(.failure(ActiveProgramOutputSessionError.emptyAudioMix))
      return
    }
    var landscapeResult: Result<Void, any Error>?
    var portraitResult: Result<Void, any Error>?
    func completeIfReady() {
      guard let landscapeResult, let portraitResult else { return }
      switch (landscapeResult, portraitResult) {
      case (.success, .success): completionHandler(.success(()))
      case (.failure(let error), _), (_, .failure(let error)):
        completionHandler(.failure(error))
      }
    }
    if runsLandscape {
      landscape.start(
        programPreferences: programPreferences,
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey,
        eventHandler: eventHandler,
        failureHandler: failureHandler,
        completionHandler: { result in
          landscapeResult = result
          completeIfReady()
        })
    } else {
      landscapeResult = .success(())
    }
    if runsPortrait {
      portrait.start(
        programPreferences: portraitPreferences,
        audioDeviceIDsByInputKey: portraitAudioDeviceIDsByInputKey,
        eventHandler: { _ in },
        failureHandler: failureHandler,
        completionHandler: { result in
          portraitResult = result
          completeIfReady()
        })
    } else {
      portraitResult = .success(())
    }
    completeIfReady()
  }

  public func stop(completionHandler: @escaping @MainActor @Sendable () -> Void = {}) {
    var remaining = (runsLandscape ? 1 : 0) + (runsPortrait ? 1 : 0)
    guard remaining > 0 else {
      completionHandler()
      return
    }
    func childStopped() {
      remaining -= 1
      if remaining == 0 { completionHandler() }
    }
    if runsLandscape { landscape.stop(completionHandler: childStopped) }
    if runsPortrait { portrait.stop(completionHandler: childStopped) }
  }

  public func requestVideoKeyFrame() {
    landscape.requestVideoKeyFrame()
    portrait.requestVideoKeyFrame()
  }

  public func beginVideoFrameHold() {
    landscape.beginVideoFrameHold()
    portrait.beginVideoFrameHold()
  }

  public func endVideoFrameHold() {
    landscape.endVideoFrameHold()
    portrait.endVideoFrameHold()
  }

  public func updateProgramPreferences(_ preferences: ProgramPreferences) {
    landscape.updateProgramPreferences(preferences)
  }

  public func updatePortraitProgramPreferences(_ preferences: ProgramPreferences) {
    portraitPreferences = preferences
    portrait.updateProgramPreferences(preferences)
  }

  @discardableResult
  public func switchProgramRuntimes(
    landscape landscapeRuntime: ProgramRuntime,
    portrait portraitRuntime: ProgramRuntime
  ) -> Bool {
    guard
      landscapeRuntime.programState.read({ $0 != nil }),
      portraitRuntime.programState.read({ $0 != nil })
    else { return false }
    let acceptedLandscape = landscape.switchProgramRuntime(to: landscapeRuntime)
    let acceptedPortrait = portrait.switchProgramRuntime(to: portraitRuntime)
    return acceptedLandscape && acceptedPortrait
  }
}

@MainActor
private final class DualTransitionState {
  private var landscape = false
  private var portrait = false
  private let handler: @MainActor @Sendable (Bool) -> Void

  init(handler: @escaping @MainActor @Sendable (Bool) -> Void) {
    self.handler = handler
  }

  func setLandscape(_ value: Bool) {
    landscape = value
    handler(landscape || portrait)
  }

  func setPortrait(_ value: Bool) {
    portrait = value
    handler(landscape || portrait)
  }
}
