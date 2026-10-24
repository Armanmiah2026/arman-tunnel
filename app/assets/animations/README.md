# Home-screen background animation

`3d_golden_lion.mp4` is the full-screen looping background of the home
dashboard (`GoldenLionBackground` renders it through `video_player`,
`FittedBox(BoxFit.cover)`, looping **with its sound** — volume 1.0).

## Shipped clip (current)

- Source: the app owner's own clip (`gold.mp4` from the device's
  VidMate downloads) — golden 3D lion on a cliff, golden galaxy sky,
  roaring a beam of light, with music.
- Processing: first 1.5s trimmed, video tail cross-faded into the head
  (1.5s dissolve) so the loop has no visible jump, audio cross-faded
  the same way (`acrossfade`) so the music never clicks at the seam,
  H.264 high profile + yuv420p + faststart, AAC 128k stereo,
  1080x1920 @ 30fps, 13.8s, ~5.8 MB.

## Swapping in your own clip

Overwrite `3d_golden_lion.mp4` with any H.264 MP4 + AAC audio (ideally
portrait, e.g. 1080x1920, ≤ ~6 MB). Keep the same file name; nothing
else needs to change — video and audio both play, looped. If the file
is missing or the platform cannot decode it, the app automatically
falls back to the painterly golden-jungle layer, so the screen never
looks broken.
