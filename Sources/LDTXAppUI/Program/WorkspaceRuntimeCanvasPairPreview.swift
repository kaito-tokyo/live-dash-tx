// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXProgram
import LDTXProgramRuntime
import SwiftUI

/// Displays a Landscape and Portrait pair backed by already-configured Program
/// runtimes. It does not require a Workspace persistence model.
public struct WorkspaceRuntimeCanvasPairPreview: View {
  private let landscapeRuntime: ProgramRuntime
  private let portraitRuntime: ProgramRuntime
  private let landscapeSize: CGSize
  private let portraitSize: CGSize

  public init(
    landscapeRuntime: ProgramRuntime,
    portraitRuntime: ProgramRuntime,
    landscapeSize: CGSize,
    portraitSize: CGSize
  ) {
    self.landscapeRuntime = landscapeRuntime
    self.portraitRuntime = portraitRuntime
    self.landscapeSize = landscapeSize
    self.portraitSize = portraitSize
  }

  public var body: some View {
    CanvasPairPreview(
      landscapeRuntime: landscapeRuntime,
      portraitRuntime: portraitRuntime,
      landscapeSize: landscapeSize,
      portraitSize: portraitSize
    )
  }
}
