# game-mixer

A simple-to-use library for emitting sounds in your game.
It was thought of as a replacement of SDL2_mixer.

Current features:
- playback MP3 / OGG / WAV / FLAC / XM / MOD
- integrated resampling and threaded decoding
- looping, fade-in/fade-out
- progressive buffering of played audio for playing in any number of channels
- master effects
- based upon `libsoundio-d`: https://code.dlang.org/packages/libsoundio-d
- `nothrow @nogc`
