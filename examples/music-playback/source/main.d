import std.stdio;
import std.math;

import gamemixer;

void main()
{
    IMixer mixer = mixerCreate();
    
    IAudioSource music = mixer.createSourceFromFile("lits.xm");

    PlayOptions options;
    options.channel = 0;                 // force playing on channel zero
    options.crossFadeInSecs = 3.0;       // time for a new song to appear when crossfading
    options.crossFadeOutSecs = 3.0;      // time for an old song to disappear when crossfading
    options.fadeInSecs = 3.0;            // time for a new song to appear when no other song is playing
    mixer.play(music, options);

    writeln("Press ENTER to fade to another song...");
    readln();

    IAudioSource music2 = mixer.createSourceFromFile("first_last.mod");
    options.pan = 0.2f;
    mixer.play(music2, options);


    writeln("Press ENTER to halt music...");
    readln();

    mixerDestroy(mixer);
}
