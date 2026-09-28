# Ghostty with smooth scrolling and seamless resize

An unofficial fork of [Ghostty](https://ghostty.org) for macOS that follows
Ghostty's `main` branch, rebased onto it daily.
[`ghostty-main`](../../tree/ghostty-main) is the Ghostty commit it currently
sits on. It is not affiliated with the Ghostty project.

It combines three sets of changes, each kept on its own branch and merged into
`main`:

| Branch | Base | What it adds |
| --- | --- | --- |
| [`pixel-scroll`](../../compare/ghostty-main...pixel-scroll) | Ghostty `main` | Smooth sub-cell trackpad scrolling, Option-click to move the cursor, ⌘-click on wrapped URLs and a compose box, by [Ian Kahn](https://github.com/lemur1905/ghostty-pixel-scroll), rebased onto current Ghostty. |
| [`scroll-fixes`](../../compare/pixel-scroll...scroll-fixes) | `pixel-scroll` | Fixes to pixel scrolling, and a slide to the bottom when you type. |
| [`seamless-resize`](../../compare/pixel-scroll...seamless-resize) | `pixel-scroll` | Keeps the picture in step with a live window resize. |
| [`kitty-streaming`](../../compare/ghostty-main...kitty-streaming) | Ghostty `main` | Faster Kitty graphics for programs that stream video. |

## Smooth scrolling

Trackpad scrolling moves the scrollback by fractions of a row and comes to rest
between rows, the way native macOS apps scroll. The rows just beyond the
viewport come from Ghostty's own render-state overscan. The `pixel-scroll`
branch also adds Option-click to move the cursor, ⌘-click on hard-wrapped URLs,
and a compose box for Claude Code. Its
[README](../../blob/pixel-scroll/README.md) describes them.
[`REBASING.md`](REBASING.md) lists the files it changes.

`scroll-fixes` corrects two things in it:

- After a failed cell rebuild, the scroll offset still matches the cells that
  were built.
- If you type while a trackpad fling glides, the fling stops, so it does not
  fight the jump to the bottom.

When you type while scrolled back, the view slides down to the bottom in 150 ms
with an ease-out. It does not jump there in one frame. If the view is more than
one screen up, the slide starts one screen above the bottom. A longer slide in
the same 150 ms moves too fast to follow.

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

Ghostty reflows shell text itself, so shell text keeps up with the window. A
full-screen program (vim, htop, a video player) still has to redraw for the new
size, so on very fast drags its new area can trail by that program's redraw
time.

The embedding API gains three calls for hosts: `ghostty_surface_set_live_resizing`,
`ghostty_surface_set_resize_lead` (a longer lead for a fast drag), and
`ghostty_surface_last_presented_pixel_size` (the size of the frame actually on
screen).

## Kitty graphics streaming

Programs such as `mpv --vo=kitty` play video by sending a new image every
frame. `kitty-streaming` keeps the texture of each replaced image. When the GPU
no longer reads it, the next image of the same size goes into that texture. So
no new texture is made for each frame.

## Link hover color

`link-hover-color` colors a highlighted link: a URL or OSC 8 hyperlink under
the mouse while ⌘ is held, or a `link` whose highlight condition matches.
By default the option is not set, and a link only gets an underline, as in
Ghostty. When you set it, the link text and underline use this color instead of
the link's own foreground color, so inverse video and `minimum-contrast` still
apply to it. Selected text and search matches keep their own colors.

```ini
link-hover-color = #0a84ff
```

## Ephemeral mode

Set `GHOSTTY_EPHEMERAL=1` in the environment before libghostty starts, and it
writes none of its own files to disk. An embedder can use this for a private
window. When the mode is on:

- Crash reporting does not start. No per-run folder goes into the cache
  directory, and no crash report goes into the state directory.
- No template config file is written when none exists.
  `ghostty_config_open_path` gives the path of the config file, but it does
  not create the file or its directory.
- `write_screen_file`, `write_scrollback_file` and `write_selection_file` do
  nothing, because each one only writes a file to the temporary directory.

libghostty reads the variable at init, like `GHOSTTY_LOG`, because crash
reporting starts before any config loads. It is off when the variable is unset
(the default), empty, `0` or `false`.

## Key bindings for host menus

A host app with its own menu can give a key to a menu item only when the
terminal would do the same action. Then the item runs once, and a key that the
user binds to a different action stays with the terminal.
`ghostty_surface_key_binding_matches` takes a key event and an action string,
such as `new_tab` or `increase_font_size:1`. It is true when the binding that
the key triggers now is that action. Nothing runs.

It finds the binding the same way as a key press: the active key sequence,
then the active key tables, then the root set, with physical keys before
characters. So it is correct in cases where `ghostty_config_trigger`, which
gives one shortcut for each action, is not: a second binding for an action,
⌘+ on a layout with its own + key, and a physical key binding such as
`super+key_t=text:example`. A key sequence leader and a chained binding never
match, because only the terminal can run them.

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
runs [`.github/sync-upstream.sh`](.github/sync-upstream.sh). The script:

1. Replays `pixel-scroll` and `kitty-streaming` onto the latest Ghostty `main`.
2. Replays `scroll-fixes`, `seamless-resize` and `main` onto the new
   `pixel-scroll`.
3. Does the merges again, with the conflict resolutions of the old merges.

Commits keep their authors and dates. The workflow pushes only when the replay
has no conflicts, the tests pass and every branch builds. If not, it pushes
nothing and opens an issue, and you rebase the branches by hand. Each replaced
`main` stays under `refs/archive/`, so a commit pinned elsewhere stays
fetchable. The push needs a `SYNC_TOKEN` secret: a fine-grained token for this
repository with Contents and Workflows write access.

This fork does not follow Ian Kahn's repository. We copy new commits from it
by hand.

`.githooks/pre-push` on `main` refuses pushes to anything but this repository.
Run `git config core.hooksPath .githooks` once after cloning. The feature
branches don't carry the hook, so push them while `main` is checked out.

## Credits

- [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and
  contributors. Its README is kept as [`README-upstream.md`](README-upstream.md).
- Smooth scrolling, Option-click, wrapped links and the compose box
  (`pixel-scroll`) by [Ian Kahn](https://github.com/lemur1905), adapting a
  proof of concept by [@pfgithub](https://github.com/pfgithub).
- Scroll fixes, seamless resize, Kitty streaming, the link hover color,
  ephemeral mode and the key binding check for host menus by
  [shexe](https://github.com/shexe).

## License

MIT, inherited from Ghostty. See [`LICENSE`](LICENSE).
