# Liquify Lab Agent Guide

Liquify Lab is an iPad interaction prototype for non-destructive, timeline capturing image deformation. It features: UIKit composition, custom controls, Apple Pencil input, and a real time Metal pipeline.

## Project structure

- `LiquifyEditorViewController` owns editor composition, actions, playback, import, and performance metrics.
- `LiquifyCanvasView` translates coalesced Pencil or touch input into pressure-adjusted, evenly spaced brush stamps.
- `LiquifyRenderer` owns Metal resources, operation history, timeline reconstruction, and GPU command encoding.
- `LiquifyShaders.metal` contains the render, brush-compute, and field-clearing functions.
- `LiquifyConfiguration` is the source of truth for shared interaction and performance tuning values.

Keep UIKit concerns out of the renderer and Metal resource management out of the view controller. Prefer small, explicit types over introducing a framework or generalized editing architecture for this prototype.

## Build and run

- Open `ProcreateLiquify/ProcreateLiquify.xcodeproj` and use the `MyApp` scheme.
- The deployment target is iPadOS 18 and the supported device family is iPad.
- Run on a physical iPad with Metal read-write texture support. Core Simulator may report `.tierNone` for capabilities available on physical hardware.
- The app requests up to 120 Hz on ProMotion hardware, but rendering must remain correct at variable frame rates.
- For Xcode build, test, run, scheme, device, simulator, issue, and log operations, prefer the Xcode MCP server configured in `.cursor/mcp.json` over direct commands such as `xcodebuild`.
- Use direct shell commands for Xcode operations only when MCP cannot perform the required action, and report the fallback.

After substantive Swift or Metal changes, build the `MyApp` scheme and inspect Xcode warnings. After shader, texture-format, or command-encoding changes, also launch on a physical iPad and check runtime Metal validation output.

## Metal invariants

- The displacement field is intentionally fixed at 320×320 to bound memory use and history-rebuild cost.
- Tier 2 GPUs use one `rgba16Float` displacement texture; tier 1 GPUs use two `r32Float` textures. Maintain both paths unless the hardware requirement is deliberately changed.
- Compute dispatches use uniform threadgroups with shader boundary checks. Do not replace them with unsupported non-uniform dispatch behavior.
- Avoid explicit texture memory barriers unsupported by lower Metal feature tiers; command-encoder boundaries establish pass ordering.
- `LiquifyBrushStamp` in Swift and `BrushStamp` in Metal are copied through an `MTLBuffer`. Their field order, scalar widths, and alignment must remain synchronized.
- Keep edits non-destructive: history stores brush operations and reconstructs displacement instead of rewriting source pixels.
- Forward timeline playback should encode only newly reached stamps; backward seeking clears and replays the field.

## Project changes

- Add new source files through Xcode so target membership remains correct.
- Do not edit `project.pbxproj` directly unless Xcode tooling cannot complete the change; call out any such fallback.
- Keep tuning constants centralized rather than duplicating values across controls, input handling, and rendering.
- Add comments for non-obvious intent, invariants, or tradeoffs—not comments that restate syntax.
- Do not commit credentials, signing material, derived data, or user-specific Xcode state.
