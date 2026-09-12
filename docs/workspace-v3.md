<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Workspace v3

Workspace v3 is a historical format being replaced by Workspace v4; a Workspace
package has two canonical protobuf files:

- `workspace.pb` contains shared resources and Programs.
- `preferences.pb` contains machine-local assignments and per-Canvas editing state.

`workspace.json` and `preferences.json` are protobuf JSON mirrors for conversion,
review, and auditing. LDTX never falls back to JSON while opening a Workspace.

## Invariants

- `formatVersion` is exactly `3` in both documents.
- Every Program has exactly one `landscape` Canvas and one `portrait` Canvas.
- Landscape uses profile `sdr-landscape-1080p60` (1920x1080 at 60 fps).
- Portrait uses profile `sdr-portrait-1080p60` (1080x1920 at 60 fps).
- Canvas Program messages and preferences are independent. Copying is explicit.
- Audio synchronization is one-way from Landscape to Portrait. Disabling it
  preserves the last Portrait snapshot.
- Starting output is a hard validation boundary: the selected Program must have a
  non-empty Landscape Audio Mix and a non-empty Portrait Audio Mix, even when
  the selected local-recording destination writes only one Canvas. An empty
  Mix rejects the Start action with an error dialog; Start remains actionable.
- Use **Dummy Audio Source (Silence)** when a Canvas intentionally has no
  audible source. It emits host-clock-based zero-valued PCM.
- Physical device identifiers occur only in `preferences.json`/`preferences.pb`.

The JSON Schema is [workspace-v3.schema.json](schemas/workspace-v3.schema.json).
It describes the conversion document pair. The protobuf declarations remain the
authoritative field contract.

## Minimal protobuf JSON pair

`workspace.json`:

```json
{
  "formatVersion": 3,
  "lineageId": "01234567-89ab-cdef-0123-456789abcdef",
  "name": "Converted Workspace",
  "programs": [
    {
      "name": "Main",
      "landscape": {
        "profileId": "sdr-landscape-1080p60",
        "program": {
          "components": [],
          "audioChannels": [{ "silentAudio": {} }]
        }
      },
      "portrait": {
        "profileId": "sdr-portrait-1080p60",
        "program": {
          "components": [],
          "audioChannels": [{ "silentAudio": {} }]
        }
      }
    }
  ],
  "inputDevices": [],
  "audioChannels": [],
  "visions": [],
  "videoComponents": [],
  "outputConfiguration": {
    "landscapeProfileId": "sdr-landscape-1080p60",
    "portraitProfileId": "sdr-portrait-1080p60",
    "frameRate": 60,
    "landscapeVideoBitRate": 6000000,
    "portraitVideoBitRate": 6000000
  }
}
```

`preferences.json`:

```json
{
  "formatVersion": 3,
  "landscapeProgram": {},
  "portraitProgram": {},
  "physicalDeviceIdsByInputDeviceId": {},
  "inputCameraDeviceMappings": {},
  "inputAudioDeviceMappings": {},
  "inputAudioMonitorChannelKeys": [],
  "selectedProgramName": "Main",
  "outputDestination": {
    "recordsLandscape": true,
    "recordsPortrait": false,
    "streamsToYoutube": false,
    "youtubeIngestMode": 0
  },
  "syncsLandscapeMixToPortraitByProgramName": {}
}
```

Unknown protobuf fields must not be invented. To obtain a field-complete example
for a particular build, create and save a v3 Workspace and run `ldtx workspace
emit-json` on it.

## Converting Workspace v1 to v3

LDTX deliberately has no in-app migration layer. Back up the entire old package,
then create a new directory for the converted package and author both v3 JSON
documents.

| v1 value | v3 destination |
| --- | --- |
| Workspace name, resources, inputs, visions | Same shared field in `workspace.json` |
| Program | `programs[].landscape.program` |
| Program canvas size/frame rate | Replace with Landscape fixed profile |
| No v1 equivalent | Empty `programs[].portrait.program` with Portrait fixed profile |
| Program video placement/order/mute | `landscapeProgram` preferences |
| Audio topology/gain/mute | Landscape Program and `landscapeProgram` preferences |
| No v1 equivalent | Portrait `silentAudio` channel and default `portraitProgram` preferences |
| Physical capture device IDs | common v3 Preferences maps |
| Local recording enabled | `recordsLandscape: true`; leave `recordsPortrait: false` |

For every old Program:

1. Copy its components and audio channels into `landscape.program`. If the old
   Program has no audio channels, add a `silentAudio` channel.
2. Set the Landscape profile ID to `sdr-landscape-1080p60`.
3. Create `portrait` with profile `sdr-portrait-1080p60`, empty video components,
   and a `silentAudio` channel. Both Canvas Audio Mixes are required at Start,
   regardless of which Canvas recording destinations are enabled.
4. Move its video-layer preferences to `landscapeProgram` under the same Program
   name. Create an empty corresponding Portrait entry.
5. Leave audio sync disabled unless the operator explicitly wants LC to control PC.

Then run:

```sh
cp -a Old.ldtxworkspace Old.ldtxworkspace.backup
test -r Old.ldtxworkspace.backup/workspace.pb
test -r Old.ldtxworkspace.backup/preferences.pb
ldtx workspace compile Converted.ldtxworkspace
ldtx workspace validate Converted.ldtxworkspace
```

`compile` validates both JSON documents before atomically replacing either pb
file. It never interprets v1 JSON. `validate` checks the pb pair, references,
fixed profiles, required LC/PC fields, and mirror equality. `emit-json` discards
the existing mirrors and regenerates them from the canonical pb pair.
