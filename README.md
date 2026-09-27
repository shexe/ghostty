# Ghostty, with smooth scrolling and seamless resize

An unofficial fork of [Ghostty](https://ghostty.org) for macOS that follows
Ghostty's `main` branch, rebased onto it daily.
[`ghostty-main`](../../tree/ghostty-main) is the Ghostty commit it currently
sits on. It is not affiliated with the Ghostty project.

It combines these changes, each kept on its own branch and merged into `main`:

| Branch | Base | What it adds |
| --- | --- | --- |
| [`pixel-scroll`](../../compare/ghostty-main...pixel-scroll) | Ghostty `main` | Smooth, sub-cell trackpad scrolling and more, by [Ian Kahn](https://github.com/lemur1905/ghostty-pixel-scroll), rebased onto current Ghostty. |
| [`scroll-fixes`](../../compare/pixel-scroll...scroll-fixes) | `pixel-scroll` | Fixes to pixel scrolling, and a slide to the bottom when you type. |
| [`seamless-resize`](../../compare/pixel-scroll...seamless-resize) | `pixel-scroll` | Keeps the picture in step with a live window resize. |
| [`region-scroll`](../../compare/pixel-scroll...region-scroll) | `pixel-scroll` | Animates scroll-region scrolls in full-screen apps, by [Ethan Lee](https://github.com/thdxg/ghostty) (thdxg). |
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

It also makes typing while scrolled back slide the view down to the bottom over
150 ms, easing out, instead of jumping there in one frame. From more than a
screen up the slide starts a screen above the bottom, so it never takes longer.

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

## Region scroll animation

Full-screen programs draw on the alternate screen, which has no scrollback for
pixel scrolling to move. Some of them scroll by asking the terminal to shift a
region of rows with its scroll margins (DECSTBM and DECSLRM with SU/SD, or a
line feed at the bottom margin); Claude Code's full-screen view and `less` do.
`region-scroll` animates those shifts: the region's new content starts where
the old content was and eases into place in about a quarter second, and the
rows that scrolled out slide away with it, clipped to the region. A trackpad
swipe, which sends many one-row scrolls, reads as one motion.

Programs that repaint every cell instead, such as Codex's full-screen view,
look the same as before, and the scrollback's pixel scrolling is unaffected.
The motion follows each scroll rather than the fingers, since the program only
draws the next row once it has scrolled.

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
`scroll-fixes`, `seamless-resize`, `region-scroll` and `main` onto the new
`pixel-scroll`, redoing the merges with the conflict resolutions they already
had. Commits keep
their authors and dates. The workflow pushes only when the replay is
conflict-free, the tests pass and every branch builds. Each replaced `main` is
kept under `refs/archive/`, so a commit pinned elsewhere stays fetchable.
Otherwise nothing is pushed and an issue is opened, and the branches are
rebased by hand. The push needs a `SYNC_TOKEN` secret: a fine-grained token for
this repository with Contents and Workflows write access.

Ian Kahn's and Ethan Lee's repositories are not followed; new commits there are
brought over by hand.

`.githooks/pre-push` on `main` refuses pushes to anything but this repository.
Run `git config core.hooksPath .githooks` once after cloning. The feature
branches don't carry the hook, so push them while `main` is checked out.

## Credits

- [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and
  contributors. Its README is kept as [`README-upstream.md`](README-upstream.md).
- Smooth scrolling, Option-click, wrapped links and the compose box
  (`pixel-scroll`) by [Ian Kahn](https://github.com/lemur1905), adapting a
  proof of concept by [@pfgithub](https://github.com/pfgithub).
- Region scroll animation (`region-scroll`) by [Ethan Lee](https://github.com/thdxg),
  from his [Ghostty fork](https://github.com/thdxg/ghostty).
- Scroll fixes, seamless resize and Kitty streaming by
  [shexe](https://github.com/shexe).

## License

MIT, inherited from Ghostty. See [`LICENSE`](LICENSE).
