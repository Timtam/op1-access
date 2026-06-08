# OP1Access — custom radar cue sounds

Drop your own sounds in this folder to replace the built-in beeps for each radar
category. They play at the radar's distance-driven ping rate and are spatialized in
3D (direction + distance) — only the *sound* changes, the behavior stays the same.

## Filenames (one per category, pick an extension below)

    chest      treasure chests
    exit       area exits / transitions
    npc        NPCs
    building   building entrances
    shop       shops
    wall       wall radar (the obstacle ahead or to the side)

## Formats (the extension)

    .flac   lossless, compressed, small   (recommended)
    .mp3    lossy, smallest
    .wav    uncompressed, large

If several exist for one category, the first found wins (flac, then mp3, then wav).
Example: `chest.flac`, `npc.mp3`, `wall.wav`.

## Tips

- Keep them SHORT: a blip ~50–300 ms. Long sounds get cut off at fast (close-range) ping rates.
- Make categories sound DISTINCT (different timbre/pitch) so they're easy to tell apart.
- Mono or stereo both work (downmixed to mono, then spatialized). Normalize the level.
- Files are loaded once at startup. After adding or changing files, restart the game.
