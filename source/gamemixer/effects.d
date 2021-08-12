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
    void prepareToPlay(float sampleRate);

    /// Actual effect processing.
    void processAudio(float*[] inoutBuffers, int frames, EffectCallbackInfo info);
}

///
alias EffectCallbackFunction = void function(float*[] inoutBuffer, int frames, EffectCallbackInfo info);

/// Effect callback info.
struct EffectCallbackInfo
{
    float sampleRate;
    long timeInFramesSincePlaybackStarted;
    long timeInFramesSinceThisEffectStarted;
    void* userData; // only used for EffectCallback, null otherwise 
}

class EffectCallback : IEffect
{
nothrow:
@nogc:
public:
    this(EffectCallbackFunction cb, void* userData)
    {
        _cb = cb;
    }

    override void prepareToPlay(float sampleRate)
    {
    }

    void processAudio(float*[] inoutBuffers, int frames, EffectCallbackInfo info)
    {
        _cb(inoutBuffers, frames, info);
    }

private:
    EffectCallbackFunction _cb;
}
