/**
* `IMixer` API and definition. This is the API entrypoint.
*
* Copyright: Copyright Guillaume Piolat 2021.
* License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamemixer.mixer;

import core.thread;
import core.atomic;
import std.math: SQRT2, PI_4;

import dplug.core;
import dplug.audio;
import soundio;

import gamemixer.effects;
import gamemixer.source;

nothrow:
@nogc:

/// Create a `Mixer` and start playback.
IMixer mixerCreate(MixerOptions options = MixerOptions.init)
{
    return mallocNew!Mixer(options);
}

/// Stops `playback`.
void mixerDestroy(IMixer mixer)
{
    destroyFree(mixer);
}

/// Options to create the mixer with.
/// You can customize sample-rate or the number of internal tracks.
/// Always stereo.
struct MixerOptions
{
    float sampleRate = 48000.0f;
    int numChannels = 16; /// Number of possible sounds to play simultaneously.
}

/// Chooses any mixer channel.
enum anyMixerChannel = -1;

/// Loop the source forever.
enum uint loopForever = uint.max;

/// Options when playing a source.
struct PlayOptions
{
    /// The channel where to play the source.
    /// `anyMixerChannel` for the first free unreserved channel.
    int channel = anyMixerChannel;

    /// The volume to play the source with.
    float volume = 1.0f;

    /// The angle pan to play the source with.
    /// -1 = full left
    ///  1 = full right
    float pan = 0.0f;

    /// The delay in seconds before which to play.
    /// The time reference is the time given by `playbackTimeInSeconds()`.
    /// The source starts playing when `playbackTimeInSeconds` has increased by `delayBeforePlay`.
    /// Note that it still occupies the channel.
    /// Warning: can't use both `delayBeforePlay` and `startTimeSecs` at the same time.
    float delayBeforePlay = 0.0f;

    /// Play the sound immediately, starting at a given time in the sample (in mixer time).
    /// Warning: can't use both `delayBeforePlay` and `startTimeSecs` at the same time.
    float startTimeSecs = 0.0f;

    /// Number of times the source is looped.
    uint loopCount = 1;

    /// The time it takes to start the sound if the channel is already busy.
    /// If the channel isn't busy, `faceInSecs` is used.
    /// Default: 14ms transition.
    float crossFadeInSecs = 0.000f; // Default was tuned on drum machine example

    /// The time it takes to halt the existing sound if the channel is already busy.
    /// If the channel isn't busy, there is nothing to halt.
    /// Default: 40ms transition out.
    float crossFadeOutSecs = 0.040f; // Default was tuned on drum machine example.

    /// Fade in time when the channel is free. This can be used to "dull" percussive samples and give them an attack time.
    /// Default: no fade in for maximum punch.
    float fadeInSecs = 0.0f;
}

/// Public API for the `Mixer` object.
interface IMixer
{
nothrow:
@nogc:

    /// Create a source from file or memory.
    /// (All sources get destroyed automatically when the IMixer is destroyed).
    /// Returns: `null` if loading failed
    IAudioSource createSourceFromMemory(const(ubyte[]) inputData);

    ///ditto
    IAudioSource createSourceFromFile(const(char[]) path);

    /// Play a source.
    /// This locks the audio thread for a short while.
    void play(IAudioSource source, PlayOptions options);
    void play(IAudioSource source, float volume = 1.0f);

    /// Play several source simulatenously, these will be synchronized down to sample accuracy.
    /// This locks the audio thread for a short while.
    void playSimultaneously(IAudioSource[] sources, PlayOptions[] options);

    /// Stop sound playing on a given channel.
    void stopChannel(int channel, float fadeOutSecs = 0.040f);
    void stopAllChannels(float fadeOutSecs = 0.040f);

    /// Sets the volume of the master bus (volume should typically be between 0 and 1).
    void setMasterVolume(float volume);

    /// Adds an effect on the master channel (all sounds mixed together).
    void addMasterEffect(IAudioEffect effect);

    /// Creates an effect with a custom callback processing function.
    /// (All effects get destroyed automatically when the IMixer is destroyed).
    IAudioEffect createEffectCustom(EffectCallbackFunction callback, void* userData = null);

    /// Creates an effect with a custom callback processing function.
    /// (All effects get destroyed automatically when the IMixer is destroyed).
    IAudioEffect createEffectGain();

    /// Returns: Time in seconds since the beginning of playback. 
    /// This is equal to `getTimeInFrames() / getSampleRate() - latency`.
    /// Warning: Because this subtract known latency, this can return a negative value.
    /// BUG: latency reported of libsoundio is too high for WASAPI, so we have an incorrect value here.
    double playbackTimeInSeconds();

    /// Returns: Playback sample rate.
    /// Once created, this is guaranteed to never change.
    float getSampleRate();

    /// Returns: `true` if a playback error has been detected.
    ///          Your best bet is to recreate a `Mixer`.
    bool isErrored();

    /// Returns: An error message for the last error.
    /// Warning: only call this if `isErrored()` returns `true`.
    const(char)[] lastErrorString();
}

package:


/// Package API for the `Mixer` object.
interface IMixerInternal
{
nothrow:
@nogc:
    float getSampleRate();
}


/// Implementation of `IMixer`.
private final class Mixer : IMixer, IMixerInternal
{
nothrow:
@nogc:
public:
    this(MixerOptions options)
    {
        _channels.resize(options.numChannels);
        for (int n = 0; n < options.numChannels; ++n)
            _channels[n] = mallocNew!ChannelStatus(n);
        _soundio = soundio_create();
        assert(_soundio !is null);

        int err = soundio_connect(_soundio);
        if (err != 0)
        {
            setErrored("Out of memory");
            _lastError = "Out of memory";
            return;
        }

        soundio_flush_events(_soundio);

        int default_out_device_index = soundio_default_output_device_index(_soundio);
        if (default_out_device_index < 0) 
        {
            setErrored("No output device found");
            return;
        }

        _device = soundio_get_output_device(_soundio, default_out_device_index);
        if (!_device) 
        {
            setErrored("Out of memory");
            return;
        }

        if (!soundio_device_supports_format(_device, SoundIoFormatFloat32NE))
        {
            setErrored("Must support 32-bit float output");
            return;
        }

        _masterEffectsMutex = makeMutex();
        _channelsMutex = makeMutex();

        _outstream = soundio_outstream_create(_device);
        _outstream.format = SoundIoFormatFloat32NE; // little endian floats
        _outstream.write_callback = &mixerWriteCallback;
        _outstream.userdata = cast(void*)this;
        _outstream.sample_rate = cast(int) options.sampleRate;
        _outstream.software_latency = 0.010; // 10ms

        err = soundio_outstream_open(_outstream);

        if (err != 0)
        {
            setErrored("Unable to open device");
            return;
        }

        if (_outstream.layout_error)
        {
            setErrored("Unable to set channel layout");
            return;
        }

        _framesElapsed = 0;
        _timeSincePlaybackBegan = 0;
        _sampleRate = _outstream.sample_rate;

        // TODO: do something better in WASAPI
        //       do something better when latency reporting works
        _softwareLatency = (maxInternalBuffering / _sampleRate);

        // The very last effect of the master chain is a global gain.
        _masterGainPostFx = createEffectGain();
        _masterGainPostFxContext.initialized = false;

        err = soundio_outstream_start(_outstream);
        if (err != 0)
        {
            setErrored("Unable to start device");
            return;
        }

        // start event thread
        _eventThread = makeThread(&waitEvents);
        _eventThread.start();    
    }

    ~this()
    {
        setMasterVolume(0);

        core.thread.Thread.sleep( dur!("msecs")( 200 ) );

        cleanUp();
    }

    /// Returns: Time in seconds since the beginning of playback. 
    /// This is equal to `getTimeInFrames() / getSampleRate() - softwareLatency()`.
    /// Warning: This is returned with some amount of latency.
    override double playbackTimeInSeconds()
    {
        double sr = getSampleRate();
        long t = playbackTimeInFrames();
        return t / sr - _softwareLatency;
    }

    /// Returns: Playback sample rate.
    override float getSampleRate()
    {
        return _sampleRate;
    }

    override bool isErrored()
    {
        return _errored;
    }

    override const(char)[] lastErrorString()
    {
        assert(isErrored);
        return _lastError;
    }

    override void addMasterEffect(IAudioEffect effect)
    {
        _masterEffectsMutex.lock();
        _masterEffects.pushBack(effect);
        _masterEffectsContexts.pushBack(EffectContext(false));
        _masterEffectsMutex.unlock();
    }

    override IAudioEffect createEffectCustom(EffectCallbackFunction callback, void* userData)
    {
        IAudioEffect fx = mallocNew!EffectCallback(callback, userData);
        _allCreatedEffects.pushBack(fx);
        return fx;
    }

    override IAudioEffect createEffectGain()
    {
        IAudioEffect fx = mallocNew!EffectGain();
        _allCreatedEffects.pushBack(fx);
        return fx;
    }

    override IAudioSource createSourceFromMemory(const(ubyte[]) inputData)
    {
        try
        {
            IAudioSource s = mallocNew!AudioSource(this, inputData);
            _allCreatedSource.pushBack(s);
            return s;
        }
        catch(Exception e)
        {
            destroyFree(e); // TODO maybe leaks
            return null;
        }
    }

    override IAudioSource createSourceFromFile(const(char[]) path)
    {
        try
        {
            IAudioSource s = mallocNew!AudioSource(this, path);
            _allCreatedSource.pushBack(s);
            return s;
        }
        catch(Exception e)
        {
            destroyFree(e); // TODO maybe leaks
            return null;
        }
    }

    override void setMasterVolume(float volume)
    {
        _masterGainPostFx.parameter(0).setValue(volume);
    }

    override void play(IAudioSource source, float volume)
    {
        PlayOptions opt;
        opt.volume = volume;
        play(source, opt);
    }

    override void play(IAudioSource source, PlayOptions options)
    {
        _channelsMutex.lock();
        _channelsMutex.unlock();
        playInternal(source, options);
    }

    override void playSimultaneously(IAudioSource[] sources, PlayOptions[] options)
    {
        _channelsMutex.lock();
        _channelsMutex.unlock();
        assert(sources.length == options.length);
        for (int n = 0; n < sources.length; ++n)
            playInternal(sources[n], options[n]);
    }

    override void stopChannel(int channel, float fadeOutSecs)
    {
        _channels[channel].stop(fadeOutSecs);
    }

    override void stopAllChannels(float fadeOutSecs)
    {
        for (int chan = 0; chan < _channels.length; ++chan)
            _channels[chan].stop(fadeOutSecs);
    }

    long playbackTimeInFrames()
    {
        return atomicLoad(_timeSincePlaybackBegan);
    }

private:
    SoundIo* _soundio;
    SoundIoDevice* _device;
    SoundIoOutStream* _outstream;
    dplug.core.thread.Thread _eventThread;
    long _framesElapsed;
    shared(long) _timeSincePlaybackBegan;
    float _sampleRate;
    double _softwareLatency;

    static struct EffectContext
    {        
        bool initialized;
    }
    Vec!EffectContext _masterEffectsContexts; // sync by _masterEffectsMutex
    Vec!IAudioEffect _masterEffects;
    UncheckedMutex _masterEffectsMutex;

    Vec!IAudioEffect _allCreatedEffects;
    Vec!IAudioSource _allCreatedSource;

    IAudioEffect _masterGainPostFx;
    EffectContext _masterGainPostFxContext;

    bool _errored;
    const(char)[] _lastError;

    AudioBuffer!float _sumBuf;

    shared(bool) _shouldReadEvents = true;


    Vec!ChannelStatus _channels;
    UncheckedMutex _channelsMutex;

    int findFreeChannel()
    {
        for (int c = 0; c < _channels.length; ++c)
            if (_channels[c].isAvailable())
                return c;
        return -1;
    }

    void waitEvents()
    {
        // This function calls ::soundio_flush_events then blocks until another event is ready
        // or you call ::soundio_wakeup. Be ready for spurious wakeups.
        while (true)
        {
            bool shouldReadEvents = atomicLoad(_shouldReadEvents);
            if (!shouldReadEvents) 
                break;
            soundio_wait_events(_soundio);
        }
    }

    void setErrored(const(char)[] msg)
    {
        _errored = true;
        _lastError = msg;
    }

    void playInternal(IAudioSource source, PlayOptions options)
    {
        int chan = options.channel;
        if (chan == -1)
            chan = findFreeChannel();
        if (chan == -1)
            return; // no free channel

        if (chan >= _channels.length)
        {
            assert(false); // specified non-existing channel index
        }

        float pan = options.pan;
        if (pan < -1) pan = -1;
        if (pan > 1) pan = 1;

        float volumeL = options.volume * fast_cos((pan + 1) * PI_4) * SQRT2;
        float volumeR = options.volume * fast_sin((pan + 1) * PI_4) * SQRT2;

        int delayBeforePlayFrames = cast(int)(0.5 + options.delayBeforePlay * _sampleRate);
        int frameOffset = -delayBeforePlayFrames;

        int startTimeFrames = cast(int)(0.5 + options.startTimeSecs * _sampleRate);
        if (startTimeFrames != 0)
            frameOffset = startTimeFrames;

        // API wrong usage, can't use both delayBeforePlayFrames and startTimeSecs.
        assert ((startTimeFrames == 0 || delayBeforePlayFrames == 0));

        double crossFadeInSecs = options.crossFadeInSecs;
        double crossFadeOutSecs = options.crossFadeOutSecs;
        double fadeInSecs = options.fadeInSecs;
        _channels[chan].startPlaying(source, volumeL, volumeR, frameOffset, options.loopCount, 
                                     crossFadeInSecs, crossFadeOutSecs, fadeInSecs);

        IAudioSourceInternal isource = cast(IAudioSourceInternal) source;
        assert(isource);
        isource.prepareToPlay();
    }


    void cleanUp()
    {    
        // remove effects
        _masterEffectsMutex.lock();
        _masterEffects.clearContents();
        _masterEffectsMutex.unlock();

        if (_outstream !is null)
        {
            soundio_outstream_destroy(_outstream);
            _outstream = null;
        }

        if (_eventThread.getThreadID() !is null)
        {
            atomicStore(_shouldReadEvents, false);
            soundio_wakeup(_soundio);
            _eventThread.join();
            destroyNoGC(_eventThread);
        }

        if (_device !is null)
        {
            soundio_device_unref(_device);
            _device = null;
        }

        if (_soundio !is null)
        {
            soundio_destroy(_soundio);
            _soundio = null;
        }

        // Destroy all effects
        foreach(fx; _allCreatedEffects)
        {
            destroyFree(fx);
        }
        _allCreatedEffects.clearContents();

        for (int c = 0; c < _channels.length; ++c)
            _channels[c].destroyFree();
    }

    void writeCallback(SoundIoOutStream* stream, int frames)
    {
        assert(stream.sample_rate == _sampleRate);

        SoundIoChannelArea* areas;

        // Extend storage if need be.
        if (frames > _sumBuf.frames())
        {
            _sumBuf.resize(2, frames); 
        }

        // Take the fisrt `frames` frames as current buf.
        AudioBuffer!float masterBuf = _sumBuf.sliceFrames(0, frames);

        // 1. Mix sources in stereo.
        masterBuf.fillWithZeroes();

        float*[2] inoutBuffers;
        inoutBuffers[0] = masterBuf.getChannelPointer(0);
        inoutBuffers[1] = masterBuf.getChannelPointer(1);

        _channelsMutex.lock(); // to protect from "play"
        for (int n = 0; n < _channels.length; ++n)
        {
            ChannelStatus* cs = &_channels[n];
            cs.produceSound(inoutBuffers, masterBuf.frames(), _sampleRate);
        }
        _channelsMutex.unlock();

        // 2. Apply master effects
        _masterEffectsMutex.lock();
        int numMasterEffects = cast(int) _masterEffects.length;
        for (int numFx = 0; numFx < numMasterEffects; ++numFx)
        {            
            applyEffect(masterBuf, _masterEffectsContexts[numFx], _masterEffects[numFx], frames);
        }
        _masterEffectsMutex.unlock();

        // 3. Apply post gain effect
        applyEffect(masterBuf, _masterGainPostFxContext, _masterGainPostFx, frames);

        _framesElapsed += frames;

        atomicStore(_timeSincePlaybackBegan, _framesElapsed);

        // 2. Pass the audio to libsoundio

        int frames_left = frames;

        for (;;) 
        {
            int frame_count = frames_left;
            if (auto err = soundio_outstream_begin_write(_outstream, &areas, &frame_count)) 
            {
                assert(false, "unrecoverable stream error");
            }

            if (!frame_count)
                break;

            const(SoundIoChannelLayout)* layout = &stream.layout;

            for (int frame = 0; frame < frame_count; frame += 1) 
            {
                for (int channel = 0; channel < layout.channel_count; channel += 1) 
                {
                    float sample = _sumBuf[channel][frame];
                    write_sample_float32ne(areas[channel].ptr, sample);
                    areas[channel].ptr += areas[channel].step;
                }
            }

            if (auto err = soundio_outstream_end_write(stream)) 
            {
                if (err == SoundIoError.Underflow)
                    return;

                setErrored("Unrecoverable stream error");
                return;
            }

            frames_left -= frame_count;
            if (frames_left <= 0)
                break;
        }
    }

    void applyEffect(ref AudioBuffer!float inoutBuf, ref EffectContext ec, IAudioEffect effect, int frames)
    {
        enum int MAX_FRAMES_FOR_EFFECTS = 512; // TODO: should disappear in favor of maxInternalBuffering

        if (!ec.initialized)
        {
            effect.prepareToPlay(_sampleRate, MAX_FRAMES_FOR_EFFECTS, 2);
            ec.initialized = true;
        }

        EffectCallbackInfo info;
        info.sampleRate                         = _sampleRate;
        info.userData                           = null;

        // Buffer-splitting! It is used so that effects can be given a maximum buffer size at init point.

        int framesDone = 0;
        foreach( block; inoutBuf.chunkBy(MAX_FRAMES_FOR_EFFECTS))
        {
            info.timeInFramesSincePlaybackStarted   = _framesElapsed + framesDone;
            effect.processAudio(block, info); // apply effect
            framesDone += block.frames();
            assert(framesDone <= inoutBuf.frames());
        }
    }
}

private:

enum int maxInternalBuffering = 1024; // Allows to lower latency with WASAPI

extern(C) void mixerWriteCallback(SoundIoOutStream* stream, int frame_count_min, int frame_count_max)
{
    Mixer mixer = cast(Mixer)(stream.userdata);

    // Note: WASAPI can have 4 seconds buffers, so we return as frames as following:
    //   - the highest nearest valid frame count in [frame_count_min .. frame_count_max] that is below 1024.

    int frames = maxInternalBuffering;
    if (frames < frame_count_min) frames = frame_count_min; 
    if (frames > frame_count_max) frames = frame_count_max;

    mixer.writeCallback(stream, frames);    
}

static void write_sample_s16ne(char* ptr, double sample) {
    short* buf = cast(short*)ptr;
    double range = cast(double)short.max - cast(double)short.min;
    double val = sample * range / 2.0;
    *buf = cast(short) val;
}

static void write_sample_s32ne(char* ptr, double sample) {
    int* buf = cast(int*)ptr;
    double range = cast(double)int.max - cast(double)int.min;
    double val = sample * range / 2.0;
    *buf = cast(int) val;
}

static void write_sample_float32ne(char* ptr, double sample) {
    float* buf = cast(float*)ptr;
    *buf = sample;
}

static void write_sample_float64ne(char* ptr, double sample) {
    double* buf = cast(double*)ptr;
    *buf = sample;
}


// A channel can be in one of four states:
enum ChannelState
{
    idle,
    fadingIn,
    normalPlay,
    fadingOut
}

/// Internal status of single channel.
/// In reality, a channel support multiple sounds playing at once, in order to support cross-fades.
final class ChannelStatus
{   
nothrow:
@nogc:
public:

    this(int channelIndex)
    {
    }

    /// Returns: true if no sound is playing or scheduled to play on this channel
    bool isAvailable()
    {
        for (int nsound = 0; nsound < MAX_SOUND_PER_CHANNEL; ++nsound)
        {
            if (_sounds[nsound].isPlayingOrPending())
                return false;
        }
        return true;
    }

    ~this()
    {
        _volumeRamp.reallocBuffer(0);
    }

    // Change the currently playing source in this channel.
    void startPlaying(IAudioSource source, 
                      float volumeL, 
                      float volumeR, 
                      int frameOffset, 
                      uint loopCount,
                      float crossFadeInSecs,
                      float crossFadeOutSecs,
                      float fadeInSecs)
    {
        // shift sound to keep most recently played
        for (int n = MAX_SOUND_PER_CHANNEL - 1; n > 0; --n)
        {
            _sounds[n] = _sounds[n-1];
        }

        VolumeState _state;
        float _currentFadeVolume = 1.0f;
        float _fadeInDuration = 0.0f;
        float _fadeOutDuration = 0.0f;


        // Note: _sounds[0] is here to replace _sounds[1]. _sounds[2] and later, if playing, were already fadeouting.

        with (_sounds[0])
        {
            _sourcePlaying = source;
            _volume[0] = volumeL;
            _volume[1] = volumeR;
            _frameOffset = frameOffset;
            _loopCount = loopCount;
             
            if (_sounds[1].isPlaying())
            {
                // There is another sound already playing, AND it has started
                _sounds[1].stopPlayingFadeOut(crossFadeOutSecs);
                startFadeIn(crossFadeInSecs);
            }
            else if (_sounds[1].isPlayingOrPending())
            {
                startFadeIn(fadeInSecs);
                _sounds[1].stopPlayingImmediately();
            }
            else
            {
                startFadeIn(fadeInSecs);
            }
        }
    }

    void stop(float fadeOutSecs)
    {
        for (int n = 0; n < MAX_SOUND_PER_CHANNEL; ++n)
        {
            _sounds[n].stopPlayingFadeOut(fadeOutSecs);
        }
    }

    void produceSound(float*[2] inoutBuffers, int frames, float sampleRate)
    {
        for (int nsound = 0; nsound < MAX_SOUND_PER_CHANNEL; ++nsound)
        {
            SoundPlaying* sp = &_sounds[nsound];
            if (sp._loopCount != 0)
            {
                // deals with negative frameOffset
                if (sp._frameOffset + frames <= 0)
                {
                    sp._frameOffset += frames;
                }
                else
                {
                    if (sp._frameOffset < 0)
                    {
                        // Adjust to only a smaller subpart of the beginning of the source.
                        int skip = -sp._frameOffset;
                        frames -= skip;
                        sp._frameOffset = 0;
                        for (int chan = 0; chan < 2; ++chan)
                            inoutBuffers[chan] += skip;
                    }

                    if (_volumeRamp.length < frames)
                        _volumeRamp.reallocBuffer(frames);

                    bool fadeOutFinished = false;

                    final switch(sp._state) with (VolumeState)
                    {
                        case VolumeState.fadeIn:
                            float fadeInIncrement = 1.0 / (sampleRate * sp._fadeInDuration);
                            for (int n = 0; n < frames; ++n)
                            {
                                _volumeRamp[n] = sp._currentFadeVolume;
                                sp._currentFadeVolume += fadeInIncrement;
                                if (sp._currentFadeVolume > 1.0f)
                                {
                                    sp._currentFadeVolume = 1.0f;
                                    sp._state = VolumeState.constant;
                                }
                            }
                            break;

                        case VolumeState.fadeOut:
                            float fadeOutIncrement = 1.0 / (sampleRate * sp._fadeOutDuration);
                            for (int n = 0; n < frames; ++n)
                            {
                                _volumeRamp[n] = sp._currentFadeVolume;
                                sp._currentFadeVolume -= fadeOutIncrement;
                                if (sp._currentFadeVolume < 0.0f)
                                {
                                    fadeOutFinished = true;
                                    sp._currentFadeVolume = 0.0f;
                                }
                            }
                            break;

                        case VolumeState.constant:
                            _volumeRamp[0..frames] = 1.0f;
                    }

                    assert(sp._frameOffset >= 0);

                    // Calling this will modify _frameOffset and _loopCount so as to give the newer play position.
                    // When loopCount falls to zero, the source has terminated playing.
                    IAudioSourceInternal isource = cast(IAudioSourceInternal)(sp._sourcePlaying);
                    assert(isource);
                    isource.mixIntoBuffer(inoutBuffers, frames, sp._frameOffset, sp._loopCount, _volumeRamp.ptr, sp._volume);

                    // End of fadeout, stop playing immediately.
                    if (fadeOutFinished)
                        sp.stopPlayingImmediately();

                    if (sp._loopCount == 0)
                    {
                        sp._sourcePlaying = null;
                    }
                }
            }
        }
    }

private:
    // 2 Sounds max since the initial use case was cross-fading music on the same channel.
    enum MAX_SOUND_PER_CHANNEL = 2; 

    SoundPlaying[MAX_SOUND_PER_CHANNEL] _sounds; // item 0 is the currently playing sound, the other ones are the fading out sounds
    float[] _volumeRamp = null;

    enum VolumeState
    {
        fadeIn,
        fadeOut,
        constant,
    }

    static struct SoundPlaying
    {
    nothrow:
    @nogc:
        IAudioSource _sourcePlaying;
        float[2] _volume;
        int _frameOffset; // where in the source we are playing, can be negative (for zeroes)
        uint _loopCount;

        VolumeState _state;
        float _currentFadeVolume = 1.0f;
        float _fadeInDuration = 0.0f;
        float _fadeOutDuration = 0.0f;

        // true if playing
        bool isPlayingOrPending()
        {
            return _loopCount != 0;
        }

        // true if playing, or scheduled to play
        bool isPlaying()
        {
            return isPlayingOrPending() && (_frameOffset >= 0);
        }

        void startVolumeStateConstant()
        {
            _state = VolumeState.constant;
            _currentFadeVolume = 1.0f;
        }

        void startFadeIn(float duration)
        {
            if (duration == 0)
                startVolumeStateConstant();
            else
            {
                _state = VolumeState.fadeIn;
                _fadeInDuration = duration;
                _currentFadeVolume = 0.0f;
            }
        }

        void stopPlayingFadeOut(float duration)
        {
            if (duration == 0)
            {
                stopPlayingImmediately();
            }
            else
            {
                _state = VolumeState.fadeOut;
                _fadeOutDuration = duration;
            }
        }

        void stopPlayingImmediately()
        {
            _loopCount = 0;
        }
    }
}
