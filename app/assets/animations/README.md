# Home-screen background animation

`3d_golden_lion.mp4` is the full-screen looping background of the home
dashboard (`GoldenLionBackground` renders it through `video_player`,
`FittedBox(BoxFit.cover)`, muted and looping).

## Shipped clip (current)

- Source: https://www.pexels.com/video/majestic-lion-walking-in-african-savannah-31150342
- License: Pexels License (free for commercial use, no attribution required)
- Processing: trimmed the first 1.5s, cross-faded the tail into the head so the
  walk cycle loops seamlessly, audio stripped, H.264 high profile, yuv420p,
  1080x1920 @ 30fps, ~11.7s, ~3.6 MB.

## Swapping in your own clip

Overwrite `3d_golden_lion.mp4` with any H.264 MP4 (ideally portrait, e.g.
1080x1920, ≤ ~5 MB, muted — the widget hard-mutes volume anyway). Keep the
same file name; nothing else needs to change. If the file is missing or the
platform cannot decode it, the app automatically falls back to the painterly
golden-jungle layer, so the screen never looks broken.
