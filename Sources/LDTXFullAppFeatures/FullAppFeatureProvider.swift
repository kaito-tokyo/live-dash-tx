// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppCore
import LDTXAppUI
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXVision
import LDTXWorkspace
import LDTXYouTubeAuth
import SwiftUI

@MainActor
public final class FullAppFeatureProvider: AppFeatureProvider {
  public let configuration = AppConfiguration(
    bundleIdentifier: "tokyo.kaito.ldtx.LDTX",
    youtubeOAuthKeychainService: "tokyo.kaito.ldtx.youtube-auth",
    mcpServerName: "tokyo.kaito.ldtx.recording",
    xpcServiceName: "tokyo.kaito.ldtx.LDTX.YouTubeOutputServiceProcess",
    uiFeatures: [.vision, .backgroundSegmentation])
  public let workspaceFeatureAvailability = WorkspaceFeatureAvailability.all
  public let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = {
    device, textureCache in
    BackgroundRemovalVideoInputPreprocessor(
      device: device,
      textureCache: textureCache,
      modelBundle: .module
    )
  }

  public init() {}

  public func makeYouTubeClientService() -> YouTubeClientService {
    YouTubeClientService(
      authorizationService: YouTubeAuthorizationService(
        authorizationStore: YouTubeAuthorizationStore(service: "tokyo.kaito.ldtx.youtube-auth"),
        oauthClientStore: OAuthClientConfigurationStore(service: "tokyo.kaito.ldtx.oauth-client")
      )
    )
  }

  public func makeProgramRuntime(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    programPreferencesState: ProgramPreferencesState,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  ) -> ProgramRuntime {
    ProgramRuntime(
      captureSessionCoordinator: captureSessionCoordinator,
      backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
      programPreferencesState: programPreferencesState,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
    )
  }

  public func makeV4VisionFeature() -> any WorkspaceV4VisionFeatureProviding {
    FullWorkspaceV4VisionFeature()
  }

}
