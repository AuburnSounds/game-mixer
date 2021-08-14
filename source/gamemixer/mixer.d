module gamemixer.mixer;

import core.thread;
import core.atomic;
import dplug.core;
import soundio;

import gamemixer.effects;
import gamemixer.source;

nothrow:
@nogc:

// TODO call endPlaying for master effects

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

    /// Play a source on a channel.
    /// -1 for the first free unreserved channel.
    void play(IAudioSource source, float volume = 1.0f, int channel = -1);

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

    /// Returns: `true` if a playback error has been detected.
    ///          Your best bet is to recreate a `Mixer`.
    bool isErrored();

    /// Returns: An error message for the last error.
    /// Warning: only call this if `isErrored()` returns `true`.
    const(char)[] lastErrorString();
}

package:

/// Implementation of `IMixer`.
private final class Mixer : IMixer
{
nothrow:
@nogc:
public:
    this(MixerOptions options)
    {
        _channels.resize(options.numChannels);
        _channels.fill(ChannelStatus.init);
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
        _sampleRate = _outstream.sample_rate;

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
            IAudioSource s = mallocNew!AudioSource(inputData);
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
            IAudioSource s = mallocNew!AudioSource(path);
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

    override void play(IAudioSource source, float volume = 1.0f, int channel = -1)
    {
        if (channel == -1)
            channel = findFreeChannel();
        if (channel == -1)
            return; // no free channel
        ChannelStatus* cs = &_channels[channel];
        cs.sourcePlaying = source;
        cs.paused = false;
        cs.volume = volume;
        cs.frameOffset = 0;
    }

private:
    SoundIo* _soundio;
    SoundIoDevice* _device;
    SoundIoOutStream* _outstream;
    dplug.core.thread.Thread _eventThread;
    long _framesElapsed;
    float _sampleRate;

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

    float[][2] _sumBuf;

    shared(bool) _shouldReadEvents = true;


    static struct ChannelStatus
    {       
    nothrow:
    @nogc:
        IAudioSource sourcePlaying;
        bool paused;
        float volume;
        int frameOffset;

        bool isAvailable()
        {
            return sourcePlaying is null;
        }
    }
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

        _sumBuf[0].reallocBuffer(0);
        _sumBuf[1].reallocBuffer(0);

        // Destroy all effects
        foreach(fx; _allCreatedEffects)
        {
            destroyFree(fx);
        }
        _allCreatedEffects.clearContents();
    }

    void writeCallback(SoundIoOutStream* stream, int frames)
    {
        assert(stream.sample_rate == _sampleRate);

        SoundIoChannelArea* areas;

        if (frames > _sumBuf[0].length)
        {
            _sumBuf[0].reallocBuffer(frames);
            _sumBuf[1].reallocBuffer(frames);
        }

        // 1. Mix sources in stereo.
        _sumBuf[0][0..frames] = 0;
        _sumBuf[1][0..frames] = 0;

        _channelsMutex.lock(); // to protect from "play"
        for (int n = 0; n < _channels.length; ++n)
        {
            ChannelStatus* cs = &_channels[n];
            if (cs.sourcePlaying !is null)
            {
                bool terminated = false;
                float*[2] inoutBuffers;
                inoutBuffers[0] = _sumBuf[0].ptr;
                inoutBuffers[1] = _sumBuf[1].ptr;
                cs.sourcePlaying.mixIntoBuffer(inoutBuffers, frames, cs.frameOffset, cs.volume, terminated);
                cs.frameOffset += frames;
                if (terminated)
                    cs.sourcePlaying = null;
            }
        }
        _channelsMutex.unlock();

        // 2. Apply master effects
        _masterEffectsMutex.lock();
        int numMasterEffects = cast(int) _masterEffects.length;
        for (int numFx = 0; numFx < numMasterEffects; ++numFx)
        {            
            applyEffect(_masterEffectsContexts[numFx], _masterEffects[numFx], frames);
        }
        _masterEffectsMutex.unlock();

        // 3. Apply post gain effect
        applyEffect(_masterGainPostFxContext, _masterGainPostFx, frames);

        _framesElapsed += frames;

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

    void applyEffect(ref EffectContext ec, IAudioEffect effect, int frames)
    {
        enum int MAX_FRAMES_FOR_EFFECTS = 512;

        if (!ec.initialized)
        {
            effect.prepareToPlay(_sampleRate, MAX_FRAMES_FOR_EFFECTS, 2);
            ec.initialized = true;
        }

        float*[2] inoutBuffers;
        inoutBuffers[0] = _sumBuf[0].ptr;
        inoutBuffers[1] = _sumBuf[1].ptr;

        EffectCallbackInfo info;
        info.sampleRate                         = _sampleRate;
        info.userData                           = null;

        // Buffer-splitting! It is used so that effects experience a maximum buffer size at init point.
        {
            int framesDone = 0;
            while (framesDone + MAX_FRAMES_FOR_EFFECTS <= frames)
            {
                info.timeInFramesSincePlaybackStarted   = _framesElapsed + framesDone;

                effect.processAudio(inoutBuffers[0..2], MAX_FRAMES_FOR_EFFECTS, info); // apply effect
                framesDone += MAX_FRAMES_FOR_EFFECTS;
                inoutBuffers[0] += MAX_FRAMES_FOR_EFFECTS;
                inoutBuffers[1] += MAX_FRAMES_FOR_EFFECTS;
            }
            assert(framesDone <= frames);
            if (framesDone != frames)
            {
                int remain = frames - framesDone;
                info.timeInFramesSincePlaybackStarted   = _framesElapsed + framesDone;
                effect.processAudio(inoutBuffers[0..2], remain, info); // apply effect
            }
        }
    }
}


private:

extern(C) void mixerWriteCallback(SoundIoOutStream* stream, int frame_count_min, int frame_count_max)
{
    Mixer mixer = cast(Mixer)(stream.userdata);


    // Note: WASAPI can have 4 seconds buffers, so we return as frames as following:
    //   - the highest nearest valid frame count in [frame_count_min .. frame_count_max] that is below 1024.

    int frames = 1024;
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

