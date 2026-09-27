# Ghostty, with smooth scrolling and seamless resize

An unofficial fork of [Ghostty](https://ghostty.org) for macOS that follows
Ghostty's `main` branch, rebased onto it daily.
[`ghostty-main`](../../tree/ghostty-main) is the Ghostty commit it currently
sits on. It is not affiliated with the Ghostty project.

It combines three sets of changes, each kept on its own branch and merged into
`main`:

| Branch | Base | What it adds |
| --- | --- | --- |
| [`pixel-scroll`](../../compare/ghostty-main...pixel-scroll) | Ghostty `main` | Smooth, sub-cell trackpad scrolling and more, by [Ian Kahn](https://github.com/lemur1905/ghostty-pixel-scroll), rebased onto current Ghostty. |
| [`scroll-fixes`](../../compare/pixel-scroll...scroll-fixes) | `pixel-scroll` | Two fixes to pixel scrolling. |
| [`seamless-resize`](../../compare/pixel-scroll...seamless-resize) | `pixel-scroll` | Keeps the picture in step with a live window resize. |
| [`kitty-streaming`](../../compare/ghostty-main...kitty-streaming) | Ghostty `main` | Faster Kitty graphics for programs that stream video. |

## Smooth scrolling

Trackpad scrolling moves the scrollback by fractions of a row and comes to rest
between rows, the way native macOS apps scroll. The rows just beyond the
viewport come from Ghostty's own render-state overscan. The `pixel-scroll`
branch also adds Option-click to move the cursor, ⌘-click on hard-wrapped URLs,
and a compose box for Claude Code; its
[README](../../blob/pixel-scroll/README.md) describes them, and
[`REBASING.md`](REBASING.md) maps the files it touches.

`scroll-fixes` corrects two things in it:

- A failed cell rebuild no longer leaves the scroll offset describing cells
  that were never built.
- Typing while a trackpad fling is still gliding no longer fights the jump to
  the bottom: the rest of the fling is dropped.

## Seamless resize

In stock Ghostty the window edge runs ahead of the terminal during a fast
resize, and the newly exposed area stays empty until the next frame. This
branch changes how frames reach the screen:

- Frames are presented through `CAMetalLayer` drawables instead of IOSurface
  layer contents.
- During a live resize, the GPU draw of each frame happens in AppKit's display
  callback, so it lands in the same Core Animation transaction as the window's
  new size.
- While a resize runs, the terminal draws a little beyond the window edge (80 pt
  by default), so the area the window grows into is already painted.
- Sizes are applied to the terminal and its PTY as they arrive, without a 25 ms
  coalescing delay, and synchronized output stays on across a resize.
- The alternate screen is full-bleed, and it keeps its top row fixed when it
  shrinks.

Shell text never waits for the program running in the terminal. A full-screen
program (vim, htop, a video player) still has to redraw for the new size, so on
very fast drags its new area can trail by that program's redraw time.

The embedding API gains three calls for hosts: `ghostty_surface_set_live_resizing`,
`ghostty_surface_set_resize_lead` (a longer lead for a fast drag), and
`ghostty_surface_last_presented_pixel_size` (the size of the frame actually on
screen).

## Kitty graphics streaming

Programs such as `mpv --vo=kitty` play video by sending a new image every
frame. `kitty-streaming` uploads each frame into the texture a replaced image
of the same size used, once the GPU is done with it, instead of allocating a
new texture every frame.

## Building

Requires full Xcode, [Zig](https://ziglang.org) 0.16 and the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

```sh
# Ghostty.app
zig build -Doptimize=ReleaseFast

# GhosttyKit.xcframework only, for embedding
zig build -Doptimize=ReleaseFast -Demit-xcframework=true \
  -Demit-macos-app=false -Dxcframework-target=native
```

## Updating

A daily workflow ([`sync-upstream.yml`](.github/workflows/sync-upstream.yml))
runs [`.github/sync-upstream.sh`](.github/sync-upstream.sh), which replays
`pixel-scroll` and `kitty-streaming` onto the latest Ghostty `main`, then
`scroll-fixes`, `seamless-resize` and `main` onto the new `pixel-scroll`,
redoing the merges with the conflict resolutions they already had. Commits keep
their authors and dates. The workflow pushes only when the replay is
conflict-free, the tests pass and every branch builds. Each replaced `main` is
kept under `refs/archive/`, so a commit pinned elsewhere stays fetchable.
Otherwise nothing is pushed and an issue is opened, and the branches are
rebased by hand. The push needs a `SYNC_TOKEN` secret: a fine-grained token for
this repository with Contents and Workflows write access.

Ian Kahn's repository is not followed; new commits there are brought over by
hand.

`.githooks/pre-push` on `main` refuses pushes to anything but this repository.
Run `git config core.hooksPath .githooks` once after cloning. The feature
branches don't carry the hook, so push them while `main` is checked out.

## Credits

- [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and
  contributors. Its README is kept as [`README-upstream.md`](README-upstream.md).
- Smooth scrolling, Option-click, wrapped links and the compose box
  (`pixel-scroll`) by [Ian Kahn](https://github.com/lemur1905), adapting a
  proof of concept by [@pfgithub](https://github.com/pfgithub).
- Scroll fixes, seamless resize and Kitty streaming by
  [shexe](https://github.com/shexe).

## License

MIT, inherited from Ghostty. See [`LICENSE`](LICENSE).
