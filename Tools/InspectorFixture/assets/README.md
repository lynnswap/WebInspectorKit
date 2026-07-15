# Self-authored media fixture

`fixture.ts` is a one-second H.264/AAC MPEG-TS segment generated from FFmpeg's
solid-color and sine-wave sources. It contains no external footage, audio, or
metadata and is served by the finite VOD playlist at `/media/fixture.m3u8`.

Regenerate it with:

```sh
ffmpeg -f lavfi -i 'color=c=0x5066d8:s=160x90:r=15:d=1' \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=1' \
  -c:v libx264 -profile:v baseline -pix_fmt yuv420p -preset veryslow \
  -c:a aac -b:a 32k -shortest -f mpegts fixture.ts
```
