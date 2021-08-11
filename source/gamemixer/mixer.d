module gamemixer.mixer;

import core.atomic;
import dplug.core;
import soundio;

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
    int tracks = 16;
}

/// Public API for the `Mixer` object.
interface IMixer
{
    /// Returns: `true` if a playback error has been detected.
    ///          Your best bet is to recreate a `Mixer`.
    bool isErrored();

    /// Returns: An error message for the last error.
    /// Warning: only call this if `isErrored()` returns `true`.
    const(char)[] lastErrorString();
}

/// Implementation of `IMixer`.
class Mixer : IMixer
{
nothrow:
@nogc:

    this(MixerOptions options)
    {
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

        _outstream = soundio_outstream_create(_device);
        _outstream.format = SoundIoFormatFloat32NE; // little endian floats
        _outstream.write_callback = &mixerWriteCallback;
        _outstream.userdata = cast(void*)this;
        _outstream.sample_rate = cast(int) options.sampleRate;

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

private:
    SoundIo* _soundio;
    SoundIoDevice* _device;
    SoundIoOutStream* _outstream;
    Thread _eventThread;

    bool _errored;
    const(char)[] _lastError;

    float[][2] _sumBuf;

    shared(bool) _shouldReadEvents = true;

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
    }

    void writeCallback(SoundIoOutStream* stream, int frames)
    {
        enum sineAmplitude = 0.25f;
        double float_sample_rate = stream.sample_rate;
        double seconds_per_frame = 1.0 / float_sample_rate;
        SoundIoChannelArea* areas;

        if (frames > _sumBuf[0].length)
        {
            _sumBuf[0].reallocBuffer(frames);
            _sumBuf[1].reallocBuffer(frames);
        }

        // 1. Mix sources in stereo.
        _sumBuf[0][0..frames] = 0;
        _sumBuf[1][0..frames] = 0;

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
                    float sample = channel >= 2 ? 0.0f : _sumBuf[channel][frame];
                    int outChan = channel % 2;
                    write_sample_float32ne(areas[channel].ptr, 0);
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
}


private:

extern(C) void mixerWriteCallback(SoundIoOutStream* stream, int frame_count_min, int frame_count_max)
{
    Mixer mixer = cast(Mixer)(stream.userdata);
    mixer.writeCallback(stream, frame_count_max);    
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

