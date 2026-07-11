# Rebasing the pixel-scroll patch onto future Ghostty releases

This fork is a short series of commits on the `pixel-scroll` branch, applied on
top of the `v1.3.1` tag: smooth sub-cell scrolling, Option-click cursor movement
(`src/Surface.zig` only: `maybeAltClickMoveCursor` + its hook in
`mouseButtonCallback`), no snap-on-settle, edge-row rendering (partial lines
at both viewport edges while resting between lines), and hard-wrapped link
matching (⌘-click opens URLs split across rows by tmux/TUI-side wrapping).

## Steps

```sh
git fetch origin --tags
git rebase vX.Y.Z pixel-scroll      # the new release tag
```

Then rebuild (see "Build" below). If the rebase conflicts, re-apply the intent
rather than the exact lines. The patch touches these areas:

| File | What the patch does there |
|---|---|
| `src/Surface.zig` | `scrollCallback`: keep the sub-cell remainder (`@trunc` the row amount instead of discarding the fraction), snap-to-line on momentum `.ended`/`.cancelled`, mirror `pending_scroll_y` into `renderer_state.mouse` under the mutex. `posToViewport`: subtract `renderer_state.mouse.applied_scroll_y`. `keyCallback` + `performBindingAction`: reset pending scroll. Hard-wrapped links: `linkAtPin` joins up to `link_hard_wrap_max_join` neighboring full-width rows (`rowLooksHardWrapped`) and searches a break-stripped string map (`joinHardWrappedMap`); `mouseRefreshLinks` strips the breaks from the opened URL (`stripHardWrapBreaks`). |
| `src/renderer/State.zig` | `Mouse.pending_scroll_y` / `Mouse.applied_scroll_y` fields and `scrollOffset()` (the gating logic: mouse-reporting, alt screen, scrollback edges). |
| `src/renderer/generic.zig` | `updateFrame`: call `state.scrollOffset()` in the critical section, write back `applied_scroll_y`, set `self.uniforms.grid_offset_y` under the draw mutex. Plus `grid_offset_y = 0` in the init literal. |
| `src/renderer/metal/shaders.zig`, `src/renderer/opengl/shaders.zig` | `grid_offset_y: f32` and `grid_extra_rows` (bitmask: below/below2/above) added to `Uniforms` after `min_contrast` — keep field positions identical in the Zig struct, the MSL struct, and the GLSL block. |
| `src/renderer/shaders/shaders.metal`, `src/renderer/shaders/glsl/*` | `cell_text_vertex`/`image_vertex` add `grid_offset_y` to the y position (above-row at `grid_size.y + 2` remaps to one row above the grid); `cell_bg_fragment` subtracts the offset from the pixel coord and admits the extra rows per `grid_extra_rows`. |
| `src/terminal/PageList.zig` | `pinIsActive` made `pub` (one-word change). |
| `src/terminal/render.zig` | `row_data` has `rows + 3` entries: index `rows` = row below the viewport, `rows + 1` = second row below, `rows + 2` = row above (`extra_below`/`extra_below2`/`extra_above` validity flags, built by `updateExtraRow`). Two below rows because the bottom must cover the window slack band plus the scroll gap (up to two rows); the top has no slack. Full-row iterations (`string`, `linkCells`, `updateHighlightsFlattened`, selection pass) bounded to viewport rows. `string` also joins rows that look hard-wrapped, so link regexes match across them (tests: "string joins hard-wrapped rows"). |
| `src/renderer/link.zig` | Test coverage only: `renderCellMap` matching across hard-wrapped rows. |
| `src/renderer/cell.zig` | `Contents` allocates 3 internal slack rows; cursor layers at `size.rows + 4`; `add`/`clear` accept `y < size.rows + 3`. |
| `src/renderer/Overlay.zig` | Inspector overlay loops bounded to `state.rows`. |
| `macos/.../SurfaceView_AppKit.swift` | `scrollWheel`: report gesture phase end as momentum end when no momentum follows (currently unused by core — snap was removed — but kept for future use). |

Upstream tracking: the feature request is
https://github.com/ghostty-org/ghostty/discussions/3206. If upstream lands
native smooth scrolling, drop this patch entirely.

## Build

Build requirements as of June 2026 (Xcode 26.5, macOS 26):

- **Zig**: exactly the `minimum_zig_version` from `build.zig.zon` (0.15.2 for
  v1.3.1), and it must be **Homebrew's** `zig@0.15`. The ziglang.org tarball
  cannot link against Xcode ≥26.4 SDKs (arm64 missing from the libSystem.tbd
  umbrella, ghostty-org/ghostty#11991). Fixed upstream in Zig 0.16.
- **libtool**: Apple's Xcode 26.5 libtool drops Zig-built archive members that
  aren't 8-byte aligned (causes "undefined symbol" walls for sentry, libintl,
  …). `tools/bin/libtool` shims to `llvm-libtool-darwin` from `brew`'s
  `llvm@20`. Keep it first in PATH. If a future Xcode fixes this, the shim can
  go.
- **Metal Toolchain**: `xcodebuild -downloadComponent MetalToolchain` (one-time).
- Full Xcode 26+ selected (`xcode-select -p`), not just CLT.

```sh
PATH="$PWD/tools/bin:/opt/homebrew/opt/zig@0.15/bin:$PATH" \
  zig build -Doptimize=ReleaseFast -Dsentry=false -Dxcframework-target=native
open macos/build/ReleaseLocal/Ghostty.app
```

To run the fork side-by-side with the official app, copy the built bundle under a
distinct name, e.g. `~/Applications/Ghostty Smooth.app`, and refresh it after
each rebuild:

```sh
rm -rf ~/Applications/"Ghostty Smooth.app" && \
  cp -R macos/build/ReleaseLocal/Ghostty.app ~/Applications/"Ghostty Smooth.app"
```

- `-Dsentry=false`: no crash reporting needed in a personal fork (and sentry
  was one of the libtool-mangled archives).
- `-Dxcframework-target=native`: arm64-only. The x86_64 half of the universal
  build hits the same libtool problem and isn't needed locally.
- Debug builds land in `macos/build/Debug/`, ReleaseFast in
  `macos/build/ReleaseLocal/`.
- If a build fails with mass "undefined symbol" errors after toolchain
  changes, clear caches first: `rm -rf .zig-cache ~/.cache/zig macos/build`.
