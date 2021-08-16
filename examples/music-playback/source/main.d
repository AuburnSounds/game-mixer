import std.stdio;
import std.math;

import gamemixer;

void main()
{
    // Decode 8x th same MP3 to send in 80 playback channels, in order to create problems.
    MixerOptions options;
    options.numChannels = 80;
    IMixer mixer = mixerCreate(options);
    
    foreach(n; 0..10)
    {
        IAudioSource music = mixer.createSourceFromFile("Malicorne - Vive la lune.mp3");
        mixer.play(music, 0.1f);
        mixer.play(music, 0.1f);
        mixer.play(music, 0.1f);
        mixer.play(music, 0.1f);
        mixer.play(music, 0.1f);
        mixer.play(music, 0.1f);
        mixer.play(music, 0.1f);
        mixer.play(music, 0.1f);
    }

    writeln("Press ENTER to end the playback...");
    readln();

    mixerDestroy(mixer);
}
