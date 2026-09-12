// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public enum OutputSessionControlState: Equatable, Sendable {
  case idle
  case starting
  case running
  case pausing
  case readyToRestart
  case stopping
}
