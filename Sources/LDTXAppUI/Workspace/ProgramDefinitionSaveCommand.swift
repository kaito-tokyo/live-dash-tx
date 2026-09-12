// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public struct ProgramDefinitionSaveCommand {
  public var isEnabled: Bool
  public var perform: () -> Void

  public init(isEnabled: Bool, perform: @escaping () -> Void) {
    self.isEnabled = isEnabled
    self.perform = perform
  }
}
