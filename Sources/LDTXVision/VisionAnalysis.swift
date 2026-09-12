// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The result of one OCR analysis, independent of Workspace persistence.
public struct VisionAnalysis: Equatable, Sendable {
  public var output: String
  public var elapsedSeconds: TimeInterval

  public init(output: String, elapsedSeconds: TimeInterval) {
    self.output = output
    self.elapsedSeconds = elapsedSeconds
  }
}
