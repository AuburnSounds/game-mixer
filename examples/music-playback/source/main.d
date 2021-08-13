import std.stdio;
import std.math;

import gamemixer;

void main()
{
    IMixer mixer = mixerCreate();

    IAudioSource music = mixer.createSourceFromFile("lits.xm");
    mixer.play(music);

    writeln("Press ENTER to end the playback...");
    readln();

    mixerDestroy(mixer);
}
