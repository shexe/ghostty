# Ghostty: smooth pixel scrolling (personal fork)

A personal fork of [Ghostty](https://ghostty.org) that adds **continuous,
sub-cell trackpad scrolling** on macOS. Mainline Ghostty scrolls the scrollback
one whole row at a time. This fork keeps the fractional part of each trackpad
delta, so the scrollback glides between lines the way native macOS apps do and
comes to rest between rows wherever you stop, with no snap back to a row
boundary.

It also adds **Option-click to move the cursor** in the prompt, with no shell
integration required.

Built on Ghostty **v1.3.1**. This is an unofficial personal fork and is not
affiliated with the Ghostty project.

> **The fork lives on the [`pixel-scroll`](../../tree/pixel-scroll) branch.**
> The [**full diff against v1.3.1**](../../compare/v1.3.1...pixel-scroll) shows
> everything it changes, about 640 lines across 15 files.

## What it does

- Trackpad scrolling moves the viewport by sub-cell amounts and rests between
  lines instead of jumping row to row.
- Partial rows render at the top and bottom of the viewport while the view is
  parked between lines, so there is no blank sliver or missing line at the
  window edge.
- Mouse hit-testing accounts for the sub-cell offset, so clicks and text
  selections land on the row you actually see.
- Pixel scrolling turns itself off where line-stepping is the correct behavior.
  Mouse-reporting and alternate-screen apps (vim, less, htop, an editor running
  in Claude Code), and the top and bottom of the scrollback, are unaffected.
- Option-click positions the cursor in the prompt, with no shell integration
  required.

## How it works

macOS trackpad events already carry precise pixel deltas. Stock Ghostty
accumulates them into whole-cell steps and discards the remainder. The patch
keeps that remainder as a viewport offset and threads it through the renderer:

- `scrollCallback` (`src/Surface.zig`) preserves the sub-cell remainder and
  mirrors it into renderer state under the mutex.
- Every frame, the renderer **gates** the offset (`State.scrollOffset`), forcing
  it to zero in mouse-reporting apps, on the alternate screen, and at the
  scrollback edges. The gated value drives a new `grid_offset_y` uniform.
- The **Metal and OpenGL shaders** translate cell text, cell backgrounds, and
  images vertically by that offset.
- To avoid a gap at the window edges, the renderer builds a few extra rows
  beyond the viewport (`src/terminal/render.zig`, `src/renderer/cell.zig`) and
  the shaders admit them via a `grid_extra_rows` bitmask. The bottom needs two
  extra rows, since it has to cover the window's slack band as well as the
  scroll gap. The top needs one.
- `posToViewport` subtracts the applied offset so selection math matches what's
  on screen.

The full design notes and per-file map live in
[`REBASING.md`](REBASING.md).

## Building (macOS, Apple Silicon)

This fork builds with Ghostty's normal toolchain, plus two workarounds for
recent Xcode SDK breakage discovered on Xcode 26.5 and macOS 26.

**Requirements**

- Full **Xcode 26+** selected (`xcode-select -p` should point into Xcode, not
  just the Command Line Tools).
- **Homebrew `zig@0.15`**, not the ziglang.org tarball. Xcode 26.4+ SDKs drop
  `arm64-macos` from the `libSystem.tbd` umbrella, which makes the stock Zig
  0.15 linker resolve zero libc symbols
  ([ghostty#11991](https://github.com/ghostty-org/ghostty/issues/11991),
  [ziglang#31658](https://codeberg.org/ziglang/zig/issues/31658)). Homebrew
  backported the Zig 0.16 fix into its 0.15 bottle.
- **Homebrew `llvm@20`**, which provides `llvm-libtool-darwin`. Xcode 26.5's
  `libtool` drops Zig-built archive members that aren't 8-byte aligned, causing
  spurious "undefined symbol" link failures.
  [`tools/bin/libtool`](tools/bin/libtool) shims around it. Keep `tools/bin`
  first in `PATH`.
- The **Metal Toolchain**, installed once with
  `xcodebuild -downloadComponent MetalToolchain`.

```sh
brew install zig@0.15 llvm@20

PATH="$PWD/tools/bin:/opt/homebrew/opt/zig@0.15/bin:$PATH" \
  zig build -Doptimize=ReleaseFast -Dsentry=false -Dxcframework-target=native

open macos/build/ReleaseLocal/Ghostty.app
```

- `-Dsentry=false`: no crash reporting in a personal build (and Sentry was one of
  the libtool-mangled archives).
- `-Dxcframework-target=native`: arm64-only. The x86_64 half hits the same
  libtool issue and isn't needed locally.

If a build fails with a wall of "undefined symbol" errors after a toolchain
change, clear the caches first: `rm -rf .zig-cache ~/.cache/zig macos/build`.

## Rebasing onto a newer Ghostty release

The patch is a short, rebase-friendly series of commits. To carry it onto a new
release:

```sh
git fetch origin --tags
git rebase vX.Y.Z pixel-scroll
```

[`REBASING.md`](REBASING.md) lists every file the patch touches and what it does
there, so conflicts can be re-applied by intent. If upstream lands native smooth
scrolling ([discussion #3206](https://github.com/ghostty-org/ghostty/discussions/3206)),
this fork can be dropped entirely.

## Credits

- [**Ghostty**](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and
  contributors, the terminal this builds on. Its original README is preserved as
  [`README-upstream.md`](README-upstream.md).
- The scrolling approach adapts a proof-of-concept by
  [**@pfgithub**](https://github.com/pfgithub) in
  [discussion #3206](https://github.com/ghostty-org/ghostty/discussions/3206),
  reworked to integrate with the renderer directly.
- Developed by Ian Kahn, with [Claude Code](https://claude.com/claude-code).

## License

MIT, inherited from upstream Ghostty. See [`LICENSE`](LICENSE).
