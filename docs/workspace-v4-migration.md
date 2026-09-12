<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Workspace V4 runtime migration

## Current boundary

Version 4 packages are protobuf-only and contain `workspace.pb` and
`preferences.pb`. `WorkspaceV4PackageService`, `WorkspaceV4PersistenceCoordinator`,
`WorkspaceV4RuntimeSession`, and `WorkspaceV4RenderGraph` form the V4 persistence
and runtime boundary. They do not project through the Version 3 domain model.

The application routes a package to V4 when both protobuf documents are present
and neither legacy JSON mirror is present. Version 3 packages are rejected by
the V4 package service rather than being opened through a legacy window.

The application no longer registers or opens that legacy path; all Workspace
open requests now enter `WorkspaceV4WindowController`. The V4 protobuf
comments and the V4 UI structure are co-authoritative descriptions of the
Workspace model: changes to either must keep the other aligned. The legacy
domain and UI model files remain only as transitional source dependencies for older
AppUI views and must be removed after those views are converted.

The V3 package, persistence, Store, rename, and input-device test suites have
been removed. The remaining test suites exercise V4 behavior or shared media
and application infrastructure.

## Removal gates for the legacy path

The Version 3 path must not be removed until each gate has direct evidence:

1. Every supported Workspace resource and output operation has an equivalent
   V4 definition, preference, or local-state representation.
2. Every supported editor action has a V4 store mutation and a runtime
   projection test.
3. Opening, saving, locking, closing, and restoring a V4 package have system
   coverage using the signed application build.
4. Existing V3 packages have an explicit conversion or retirement policy.
5. No application entry point routes a supported package or recording through
   the legacy Workspace model.

Until these gates are evidenced, the V3 implementation is intentionally kept
as a migration-period compatibility path.
