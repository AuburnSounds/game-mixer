import std.stdio;
import std.math;

import gamemixer;

void main()
{
    // The whole API is available through `IMixer` and the interfaces it may return.
    IMixer mixer = mixerCreate(); // Create with defaults (48000Hz, 512 or 1024 samples of software latency).

    IAudioSource music = mixer.createSourceFromFile("lits.xm");
    mixer.play(music);

    writeln("Press ENTER to end the playback...");
    readln();
    mixerDestroy(mixer); // this cleans up everything created through `mixer`.
}
