import std.stdio;
import std.math;

import gamemixer;

void main()
{
    IMixer mixer = mixerCreate();

    mixer.addMasterEffect( mixer.createEffectCustom(&generateSine) );

    // Wait until keypress
    writeln("Press ENTER to end the playback...");
    readln();
    mixerDestroy(mixer);
}

nothrow:
@nogc:

void generateSine(float*[] inoutBuffer, int frames, EffectCallbackInfo info)
{
    float invSR = 1.0f / info.sampleRate;
    for (int chan = 0; chan < inoutBuffer.length; ++chan)
    {
        float* buf = inoutBuffer[chan];
        for (int n = 0; n < frames; ++n)
        {
            float FREQ = 110.0f;
            double phase = (info.timeInFramesSinceThisEffectStarted + n) * 2 * PI * FREQ;
            buf[n] += 0.25f * sin(phase);
        }
    }
}