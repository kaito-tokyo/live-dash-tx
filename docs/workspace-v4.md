<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Workspace v4

Workspace v4 persists exactly two protobuf documents in each
`.ldtxworkspace` package: `workspace.pb` and `preferences.pb`. JSON mirrors
are not part of the package format. `Assets` and `Extensions` remain package
resources and are preserved when the documents are saved.

The application selects the V4 runtime from this protobuf-only layout before
decoding either document. A package containing either legacy JSON mirror is
treated as a non-V4 package, including when its protobuf documents are also
present; it is not partially opened as V4.

Each document is wrapped in its corresponding envelope, which records its
UUIDv7 `external_id` and a `WorkspaceDefinitionV4` or `WorkspacePreferencesV4`
payload. The protobuf message comments are the normative format specification;
the rendered reference is [workspace.html](protos/workspace.html).

The CLI does not convert Workspace v3 packages. Convert one outside LDTX, then
create a v4 package from protobuf JSON when needed:

```sh
ldtx workspace create Unite-20260910.ldtxworkspace --json definition.json \
  --preferences-json preferences.json
```

`ldtx workspace dump` prints the stored v4 Program layer references, and
`ldtx workspace validate` verifies that both persisted documents are valid v4
envelopes. The application opens v4 packages through its dedicated V4 runtime
session, without converting them to a v3 Workspace model. It persists the
Workspace definition and mutable preferences directly through the two v4
envelopes.
