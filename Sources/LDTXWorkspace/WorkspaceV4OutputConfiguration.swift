// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

/// Runtime defaults for Version 4 output configuration.
extension Ldtx_Workspace_V4_OutputConfiguration {
  /// The YouTube ingest mode to use at runtime. The protobuf zero value keeps
  /// older or manually authored documents valid and defaults to Landscape
  /// RTMPS, which is the Version 4 default output mode.
  public var resolvedYouTubeIngestMode: Ldtx_Workspace_V4_YouTubeIngestMode {
    youtubeIngestMode == .unspecified ? .landscapeRtmps : youtubeIngestMode
  }
}
