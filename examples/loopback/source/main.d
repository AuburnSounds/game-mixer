import std.stdio;
import std.math;

import gamemixer;

void main()
{
    // In loopback mode, the IMixer can only be called manually to mix its stereo output.
    // It does no I/O itself.
    MixerOptions options;
    options.isLoopback = true;
    IMixer mixer = mixerCreate(options);
    IAudioSource music = mixer.createSourceFromFile("lits.xm");
    mixer.play(music);

    // Read 128 first samples
    enum int N = 128;
    float[N][2] samples;
    float*[2] outBuf = [ samples[0].ptr, samples[1].ptr ];

    mixer.loopbackGenerate(outBuf, N);

    for (int n = 0; n < 100; ++n)
    {
        writeln("Mixed left samples: ", samples[0]);
        writeln("Mixed right samples: ", samples[1]);
    }

    mixerDestroy(mixer);
}
