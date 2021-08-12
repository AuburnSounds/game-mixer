import std.stdio;
import std.math;

import gamemixer;

void main()
{
    // The whole API is available through `IMixer` and the interfaces it may return.
    IMixer mixer = mixerCreate(); // Create with defaults (48000Hz, 512 or 1024 samples of software latency).

    mixer.addMasterEffect( mixer.createEffectCustom(&addSinusoid) );

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
            float FREQ = (chan % 2) ? 52.0f : 62.0f;
            double phase = ((info.timeInFramesSincePlaybackStarted + n) * invSR) * 2 * PI * FREQ;
            buf[n] += 0.25f * sin(phase);
        }
    }
}