import std.stdio;
import std.math;

import gamemixer;

void main()
{
    IMixer mixer = mixerCreate();
    
    for (int n = 0; n < 10; ++n)
    {
        IAudioSource music = mixer.createSourceFromFile("lits.xm");
        mixer.play(music, 0.01f);
    }

    writeln("Press ENTER to end the playback...");
    readln();

    mixerDestroy(mixer);
}
