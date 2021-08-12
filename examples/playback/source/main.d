import std.stdio;
import std.math;

import gamemixer;

void main()
{
    // Note: the whole API is available through `IMixer`.
    IMixer mixer = mixerCreate();

    mixer.addMasterEffect( mixer.createEffectCustom(&addSinusoid) );

    // Wait until keypress
    writeln("Press ENTER to end the playback...");
    readln();
    mixerDestroy(mixer); // this cleans up everything created through `mixer`.
}

nothrow:
@nogc:

void addSinusoid(float*[] inoutBuffer, int frames, EffectCallbackInfo info)
{
    double invSR = 1.0f / info.sampleRate;
    for (int chan = 0; chan < inoutBuffer.length; ++chan)
    {
        float* buf = inoutBuffer[chan];
        for (int n = 0; n < frames; ++n)
        {
            float FREQ = 110.0f;
            double phase = ((info.timeInFramesSinceThisEffectStarted + n) * invSR) * 2 * PI * FREQ;
            buf[n] += 0.25f * sin(phase);
        }
    }
}