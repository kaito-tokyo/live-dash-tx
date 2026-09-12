<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Clock Video Component

**Clock** is a **Video Component** that renders the current time as a Metal overlay. Its appearance belongs to the **Video Component**; its inclusion, order, position, and Scale belong to each **Program**'s **Video Layer**.

## Appearance

**Clock** has the following appearance settings.

- **Time Format:** 24-hour or AM/PM.
- **Show Seconds:** include or omit seconds.
- **Show Date:** show `yyyy/MM/dd` on the first line and time on the second line.
- **Use System Time Zone:** use the host **System Time Zone**. When disabled, use a supplied **Fixed UTC offset** in ISO 8601 form, such as `+09:00` or `-05:00`.
- **Text Color:** an RGBA color.
- **Background:** a supported CSS-like color or linear gradient.
- **Outline:** zero, one, or two outlines; each has a thickness and color.

**Clock** deliberately does not localize date or time strings. The supported format options above are the complete customization surface.

## Time Zones

With **Use System Time Zone** enabled, **Clock** uses the **System Time Zone** of the running system. With it disabled, **Clock** uses the entered **Fixed UTC offset**. Valid offsets range from `-14:00` through `+14:00`; `+14:00` and `-14:00` cannot have a minute component.

The time zone name is not displayed.

## Background Values

The **Background** field accepts the subset needed for solid backgrounds and two-stop linear gradients:

- `transparent`
- Hex colors: `#RGB`, `#RGBA`, `#RRGGBB`, and `#RRGGBBAA`
- Numeric `rgb(...)` and `rgba(...)` colors, with channels from 0 through 255 and alpha from 0 through 1
- `linear-gradient(<angle>deg, <color>, <color>)`

For example:

```text
#202124cc
rgba(0, 0, 0, 0.65)
linear-gradient(135deg, #152238, #5c2d91)
```

An empty **Background** is transparent. An unsupported value is visibly marked as invalid in the editor and renders as a fully transparent background. The editor does not provide a separate CSS syntax guide.

## Typography and Rendering

**Clock** always uses the bundled upright Noto Sans font. Font selection and font import are intentionally not supported.

The renderer creates an **SDF atlas** for the fixed **Clock** glyph set (digits, separators, space, and AM/PM). Metal renders the fill and up to two outlines from that atlas.

**Clock** text is fitted within the **Clock layer**'s own rendered canvas while preserving its aspect ratio. When the **Clock layer** is partly outside the **Output**, the renderer keeps the same texture and clips it at composition time; placement must not cause the text to be regenerated at a different size.

## Layer Placement

**Clock** uses the selected Canvas's **Program Video Layer** X, Y, and uniform Scale. X and Y are in that Canvas's logical coordinate space: **1920 × 1080** for Landscape and **1080 × 1920** for Portrait. The **Clock** component definition does not persist width, height, or placement.

Changing **Clock appearance** updates every **Program** that uses it. Changing a **Clock layer**'s position, scale, or order affects only that **Program**.

## Migration

Workspace v4 is the target persistence format. Its package contract and CLI
workflow are described in [Workspace v4](../workspace-v4.md); application
runtime adoption is in progress.

## Terminology

- **Active Program:** The single **Program** currently selected by the application; every **Output** uses its resolved **Clock layers**.
- **Clock:** A **Video Component** that renders the current time.
- **Clock appearance:** **Clock** settings stored with the **Video Component**, including format, time zone, colors, background, and outlines.
- **Clock layer:** A **Video Layer** that refers to a **Clock** component and supplies that **Program**'s X, Y, Scale, and order.
- **Fixed UTC offset:** A time-zone offset supplied as `+HH:MM` or `-HH:MM`, without displaying a time-zone name.
- **Monitor:** An audio observation surface that spies, with near-zero latency, on every audio device whose monitor setting is enabled. It is not an **Output** and does not necessarily depend on the **Active Program**.
- **Output:** A consumer of the **Active Program**'s final composition, such as recording or streaming.
- **Preview:** A video observation surface that spies on the **Active Program**'s **Video Track**. It is not an **Output**.
- **SDF atlas:** The signed-distance-field glyph texture used by Metal to render **Clock** fill and outlines.
- **System Time Zone:** The time zone reported by the running host system.
- **Video Component:** A reusable visual resource whose appearance and source configuration are defined by the **Workspace**.
- **Video Layer:** An ordered reference to a **Video Component** in a **Program**'s exactly-one **Video Track**.
