/**
* IAudioEffect API.
*
* Copyright: Copyright Guillaume Piolat 2021.
* License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamemixer.effects;

import dplug.core;
import dplug.audio;

nothrow:
@nogc:

/// Inherit from `IEffect` to make a custom effect.
class IAudioEffect
{
nothrow:
@nogc:
    /// Called before the effect is used in playback.
    /// Initialize state here.
    abstract void prepareToPlay(float sampleRate, int maxFrames, int numChannels);

    /// Actual effect processing.
    abstract void processAudio(ref AudioBuffer!float inoutBuffer, EffectCallbackInfo info);

    /// Get all parameters in this effect.
    IParameter[] getParameters()
    {
        // default: no parameters.
        return [];
    }

    /// Get number of parameters.
    final int numParameters(int index)
    {
        return cast(int) getParameters().length;
    }

    /// Get a parameter by index.
    final parameter(int index)
    {
        return getParameters()[index];
    }
}

///
alias EffectCallbackFunction = void function(ref AudioBuffer!float inoutBuffer, EffectCallbackInfo info);

/// Effect callback info.
struct EffectCallbackInfo
{
    float sampleRate;
    long timeInFramesSincePlaybackStarted;
    void* userData; // only used for EffectCallback, null otherwise 
}


interface IParameter
{
nothrow:
@nogc:
    string getName();
    void setValue(float value);
    float getValue();
}

package:

/// You can create custom effect from a function with `EffectCallback`.
/// It's better to create your own IAudioEffect derivative though.
class EffectCallback : IAudioEffect
{
nothrow:
@nogc:
public:
    this(EffectCallbackFunction cb, void* userData)
    {
        _cb = cb;
        _userData = userData;
    }

    override void prepareToPlay(float sampleRate, int maxFrames, int numChannels)
    {
    }

    override void processAudio(ref AudioBuffer!float inoutBuffer, EffectCallbackInfo info)
    {
        info.userData = _userData;
        _cb(inoutBuffer, info);
    }

private:
    EffectCallbackFunction _cb;
    void* _userData;
}

/// You can create custom effect from a function with `EffectCallback`.
class EffectGain : IAudioEffect
{
nothrow:
@nogc:
public:
    this()
    {
        _params[0] = createLinearFloatParameter("Gain", 0.0f, 1.0f, 1.0f);
    }

    override void prepareToPlay(float sampleRate, int maxFrames, int numChannels)
    {
        _currentGain = 0.0;
        _expFactor = expDecayFactor(0.015, sampleRate);
    }

    override void processAudio(ref AudioBuffer!float inoutBuffer, EffectCallbackInfo info)
    {
        int numChans = inoutBuffer.channels();
        int frames = inoutBuffer.frames();

        float targetLevel = _params[0].getValue();
        for (int n = 0; n < frames; ++n)
        {
            _currentGain += (targetLevel - _currentGain) * _expFactor;
            for (int chan = 0; chan < numChans; ++chan)
            {
                inoutBuffer[chan][n] *= _currentGain;
            }
        }
    }

    override IParameter[] getParameters()
    {
        return _params[];
    }

private:
    EffectCallbackFunction _cb;
    double _expFactor;
    double _currentGain;
    IParameter[1] _params;
}

class LinearFloatParameter : IParameter
{
public:
nothrow:
@nogc:
    this(string name, float min, float max, float defaultValue)
    {
        _name = name;
        _min = min;
        _max = max;
        _value = defaultValue;
    }

    override string getName()
    {
        return _name;
    }

    override void setValue(float value)
    {
        if (value < _min) value = _min;
        if (value > _max) value = _max;
        _value = value;
    }

    override float getValue()
    {
        return _value;
    }

private:
    string _name;
    float _value;
    float _min, _max;
}

IParameter createLinearFloatParameter(string name, float min, float max, float defaultValue)
{
    return mallocNew!LinearFloatParameter(name, min, max, defaultValue);
}