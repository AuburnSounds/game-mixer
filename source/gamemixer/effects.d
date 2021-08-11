module gamemixer.effects;

import dplug.core;

nothrow:
@nogc:

/// Inherit from `IEffect` to make a custom effect.
interface IEffect
{
nothrow:
@nogc:

    /// Called before the effect is used in playback.
    /// Initialize state here.
    void beginPlaying(float sampleRate);

    /// Called when the effect has stopped being used.
    void endPlaying();

    /// Actual effect processing.
    void processAudio(float*[] inoutBuffers, int frames, long time);
}


