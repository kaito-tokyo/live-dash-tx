<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Programs

A **Program** is a reusable output composition in a **Workspace**. Its responsibility is to choose and combine **Workspace resources**, specify the final screen composition, and manage audio-mixing settings. It is expressed as a collection of **Output Tracks**: one **Video Track**, one or more **Audio Tracks**, and future **Aux Tracks** such as timecode and captions. The selected **Program** is used for **Preview**, recording, and streaming. A **Workspace** can contain multiple **Programs**; selecting one does not change the **Program Definition** of the others.

Every **Program** has exactly one **Video Track**. A **Program** is therefore one final visual composition, not a collection of alternate video outputs. When a **Workspace** needs a different visual composition, it defines another **Program** and sets that **Program** as the **Active Program**.

## Active Program and Outputs

At any time, the application selects exactly one **Active Program**. Every **Output** adopts that same **Active Program**; **Outputs** do not choose independent **Programs**. Recording and streaming are both **Output** types and consume the **Active Program**'s final video and audio composition.

**Preview** displays a video spy of the **Active Program**'s **Video Track**. **Monitor** independently spies every audio device whose monitor setting is enabled and plays it with near-zero latency. Both are observation surfaces, not **Outputs**: neither creates an **Output** graph or changes the **Program** used by recording or streaming. Unlike **Preview**, **Monitor** does not necessarily depend on the **Active Program**.

To switch to a different visual composition during an **Output Session**, select a different **Program** as the **Active Program**.

## Output Tracks and Workspace Resources

**Output Tracks** express how a **Program** fulfills those responsibilities. A **Workspace** defines reusable resources; **Output Tracks** do not own duplicate source or appearance definitions. They refer to **Workspace resources** and apply **Program**-specific screen-composition and audio-mixing settings.

| **Output Track** | Role | Current resource examples |
| --- | --- | --- |
| **Video Track** | Composes the visual output in order. | **Video Components** |
| **Audio Tracks** | Mix one or more audio sources into **Program** output. | **Input Devices** and audio channels |
| **Aux Tracks** | Add non-primary output information. | Future timecode and caption resources |

The **Video Track** editor is named **Video Layers**. Each **Program** has exactly one **Video Track**. Physical output destination selection and placement are the responsibility of an **Output Service**, not of a **Program** or its **Video Track**.

## Program Definition, Workspace Definition, and Preferences

A loaded `.ldtxworkspace` is represented as `WorkspaceSnapshot`: a `WorkspaceDefinition` and its colocated `WorkspacePreferences`. They are one semantic document and must be loaded, validated, renamed, and migrated together.

**Program** state is deliberately split between the two halves.

A **Program Definition** is the source code for the **Program**'s render graph: its **Output Track** topology, selected reusable resources, and fixed composition structure. The application compiles it into the runtime pipeline. Changing a **Program Definition** can require that pipeline to be rebuilt, so it is intentionally not the surface for frequent operational changes. This boundary is a performance property, not merely a storage convention.

**Preferences** are the operational parameters supplied to that already-defined pipeline, such as **Video Layer** order and placement, audio gains, and mute state. They can change without redefining the pipeline's structure.

| State | Owner | Examples |
| --- | --- | --- |
| **Output Track** topology and reusable **Workspace resources** | **Program Definition** and **Workspace Definition** | **Program** name, **Canvas Size**, **Video Component** appearance, audio configuration |
| Per-**Program** arrangement and operational **Preferences** | **Preferences** | **Video Layer** order, X/Y/Scale, audio gains, mute state |

**Preferences** never define a new **Video Component**. They refer to an existing **Video Component** by name.

## Video Layers

A **Video Layer** adds one **Video Component** to the **Program**'s **Video Track** and defines its order and placement. A **Video Component** may be used by more than one **Program**, with a different placement in each **Program**.

- **Layer order** is compositing order.
- A **Program** cannot contain the same **Video Component** more than once.
- Removing a **Video Layer** removes that component from the **Program** only; it does not delete the **Video Component**.
- Renaming or deleting a **Video Component** updates or removes its **Video Layer** references in **Preferences**.

### Coordinates and Scale

**Video Layer** positions use a fixed logical coordinate space of **1920 × 1080**. The X and Y values displayed in the editor always use this space; changing a **Program** **Canvas Size** does not change their meaning or rewrite saved positions.

X and Y are logical coordinates, not **Canvas Size** pixels. At runtime, the placement is normalized from the **1920 × 1080** space and mapped to the active canvas. For example, X=960 and Y=540 remain the center position for a **1280 × 720** canvas. This identical coordinate contract applies to every layer type that supports placement, including **VFX Source** and **Clock**.

Scale is the only layer sizing control. Width and height are intentionally not independent layer settings. **VFX Source** and **Clock** layers support X, Y, and Scale. Full-canvas components such as fills, gradients, and test patterns do not expose placement controls.

## Video Components

**Video Components** hold reusable appearance and source configuration. They are configured from the **Workspace** sidebar, rather than from a **Program**'s **Video Layers** list. A **Program**'s layer resolves the component definition and then applies that **Program**'s placement preference.

This separation means that changing a component's appearance updates every **Program** which contains a layer for it, while moving or scaling a layer affects only that **Program**.

## Persistence and External Conversion

**Video Track** placement is stored in `ProgramPreferences.videoLayersByProgramName`, not in the **Program Definition** or **Video Component Definition**. Other **Output Track** types may use settings that are appropriate to their own semantics; **Video Layer** placement is not a generic **Output Track**-settings abstraction.

Workspace v4 is the target persistence format. Its package contract and CLI
workflow are described in [Workspace v4](workspace-v4.md); application runtime
adoption is in progress.

## Saving and Output

**Program Definition** edits are saved as part of the **Workspace**. Changes to **Preferences** are persisted with the **Workspace**. Starting **Output** saves the current **Workspace** and creates the runtime configuration from the selected **Program** plus its resolved **Output Tracks**, including **Video Layers**.

Every newly created Workspace stores concrete local-recording and YouTube-streaming
enablement values in its Output Destination. There is no application-wide default
for these flags. A missing persisted Output Destination is a legacy or malformed-data
recovery case; its fallback behavior is not a compatibility contract.

Selecting an existing YouTube broadcast is intentionally limited to the current
Workspace window session. LDTX does not persist the broadcast ID in the Workspace or
application preferences because a later session could otherwise reconnect to a stale
or unintended broadcast. The user selects again, or the application recommends from
the broadcasts currently available.

The running **Output Session** uses that runtime configuration; editing is locked while **Output** is active. Returning to Edit mode restores the editable **Workspace** model.

## Terminology

- **Active Program:** The single **Program** currently selected by the application. Every **Output** uses it.
- **Audio Track:** An **Output Track** that contributes one or more audio sources to the **Program** mix. A **Program** can have multiple audio tracks.
- **Aux Track:** A future non-primary **Output Track** type, such as one for timecode or captions. `Aux` is the formal name, not an abbreviation expanded in the UI or documentation.
- **Monitor:** An audio observation surface that spies, with near-zero latency, on every audio device whose monitor setting is enabled. It is not an **Output** and does not necessarily depend on the **Active Program**.
- **Output:** A consumer of the **Active Program**'s final composition, such as recording or streaming.
- **Output Service:** The service that selects and places physical output destinations for an **Output**.
- **Output Track:** A **Program**-owned structure that defines how the **Program** uses **Workspace resources** and contributes directly to an **Output**.
- **Preferences:** Colocated persisted settings for per-**Program** arrangement and operation.
- **Preview:** A video observation surface that spies on the **Active Program**'s **Video Track**. It is not an **Output**.
- **Program Definition:** The persisted **Program** structure, including its **Output Track** topology.
- **Video Component:** A reusable visual resource whose appearance and source configuration are defined by the **Workspace**.
- **Video Layer:** An ordered reference to a **Video Component** in the **Video Track**, with per-**Program** X, Y, and Scale.
- **Video Track:** The exactly-one visual-composition **Output Track** in a **Program**. Its editor is **Video Layers**.
- **Workspace:** A saved `.ldtxworkspace` bundle containing reusable resources, **Programs**, and their **Preferences**.
- **Workspace Definition:** The persisted structure of reusable resources in a **Workspace**.
