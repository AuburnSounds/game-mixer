import std.stdio;
import std.math;

import gamemixer;

void main()
{
    IMixer mixer = mixerCreate();
    
    IAudioSource music = mixer.createSourceFromFile("lits.xm");

    float volume = 0.7f;
    mixer.play(music, volume);

    writeln("Press ENTER to end the playback...");
    readln();

    mixerDestroy(mixer);
}
