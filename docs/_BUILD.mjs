#!/usr/bin/env node

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const docsDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryDirectory = path.dirname(docsDirectory);
const [command] = process.argv.slice(2);

switch (command) {
  case "protos": {
    const result = spawnSync(
      "protoc",
      [
        "--proto_path=Protos",
        "--doc_out=docs/protos",
        "--doc_opt=docs/_lib/workspace.tmpl,workspace.html",
        "Protos/envelope.proto",
        "Protos/workspace_v4_definition.proto",
        "Protos/workspace_v4_input_device.proto",
        "Protos/workspace_v4_preferences.proto",
        "Protos/workspace_v4_video_component.proto",
        "Protos/workspace_v4_vfx.proto",
        "Protos/workspace_v4_vision.proto",
      ],
      { cwd: repositoryDirectory, stdio: "inherit" },
    );

    if (result.status !== 0) {
      process.exit(result.status ?? 1);
    }

    const outputPath = path.join(docsDirectory, "protos", "workspace.html");
    const output = readFileSync(outputPath, "utf8");
    writeFileSync(outputPath, output.replace(/[ \t]+$/gm, ""));

    break;
  }
  default:
    console.error("Usage: node docs/_BUILD.mjs protos");
    process.exit(1);
}
