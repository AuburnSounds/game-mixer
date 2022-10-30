/**
* IAudioSource API.
*
* Copyright: Copyright Guillaume Piolat 2021.
* License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamemixer.source;

import dplug.core;
import gamemixer.bufferedstream;
import gamemixer.resampler;
import gamemixer.chunkedvec;
import gamemixer.mixer;

nothrow:
@nogc:


/// Represent a music or a sample.
/// This isn't meant for public consumption.
interface IAudioSource
{
nothrow:
@nogc:
    /// Decode all stream, and wait until the whole stream is decoded and resampled.
    /// This normally happens in playback, but this call lets you do that decoding work ahead
    /// of time.
    /// Normally, you don't need to call this at all, and shouldn't.
    /// Warning: THIS CAN ONLY BE CALLED BEFORE THE SOURCE HAS BEEN PLAYED. You will get
    ///          a crash else.
    /// Returns: true if fully decoded.
    bool fullDecode();

    /// True if the source has a known length.
    /// You can ensure its length is known by full decoding it with `fullDecode()`.
    bool hasKnownLength();

    /// Returns: Length of resampled source in frames, in terms of the mixer samplerate.
    ///          -1 if unknown.
    /// Note: call `hasKnownLength()` or `fullDecode()` if you really need that information.
    ///       Or wait until it plays completely.
    int lengthInFrames();

    /// Returns: Length of source in seconds.
    ///          -1.0 if unknown
    /// Note: call `hasKnownLength()` or `fullDecode()` if you really need that information.
    ///       Or wait until it plays completely.
    double lengthInSeconds();

    /// Returns: Length of original source in seconds.
    ///          -1 if unknown
    /// Note: call `hasKnownLength()` or `fullDecode()` if you really need that information.
    ///       Or wait until it plays completely.
    int originalLengthInFrames();

    /// Returns: Original sample rate from the source. The source buffer contains resampled audio.
    float sampleRate();
}

package:

interface IAudioSourceInternal
{
nothrow @nogc:
    /// Called before an IAudioSource is played on a mixer channel.
    /// Note: after this call, for thread safety you're not allowed to call `fullDecode()`.
    void prepareToPlay();

    /// Add output of the source to this buffer, with volume as gain.
    /// TODO: this call is actually internal to game-mixer, remove.
    void mixIntoBuffer(float*[] inoutChannels, 
                       int frames, 
                       ref int frameOffset, 
                       ref uint loopCount,
                       float* volumeRamp, // multiply L by volumeRamp[n] * volume[0] 
                       float[2] volume);  // and multiply R by volumeRamp[n] * volume[1]
}

enum chunkFramesDecoder = 128; // PERF: tune that, while decoding a long MP3.

/// Concrete implementation of `IAudioSource`.
final class AudioSource : IAudioSource, IAudioSourceInternal
{
@nogc:
public:
    /// Create a source from file.
    this(IMixerInternal mixer, const(char)[] path)
    {
        assert(mixer);
        _mixer = mixer;
        _decodedStream.initializeFromFile(path);
    }

    /// Create a source from memory data.
    this(IMixerInternal mixer, const(ubyte)[] inputData)
    {
        assert(mixer);
        _mixer = mixer;
        _decodedStream.initializeFromMemory(inputData);
    }

    override void prepareToPlay()
    {
        _sampleRate = _mixer.getSampleRate();
        _disallowFullDecode = true;
    }

    override void mixIntoBuffer(float*[] inoutChannels, 
                                int frames,
                                ref int frameOffset,
                                ref uint loopCount,
                                float* volumeRamp,
                                float[2] volume)
    {
        assert(inoutChannels.length == 2);
        assert(frameOffset >= 0);

        _decodedStream.mixIntoBuffer(inoutChannels, frames, frameOffset, loopCount, volumeRamp, volume, _sampleRate);
    }

    override bool fullDecode()
    {
        if (_decodedStream.fullyDecoded())
            return true;

        // If you fail here, you have called fullDecode() after play(); this is disallowed.
        assert(!_disallowFullDecode);

        if (_disallowFullDecode)
        {
            return false; // should do it before playing, to avoid races.
        }
        
        _decodedStream.fullDecode(_mixer.getSampleRate());
        return true; // decoding may encounter erorrs, but thisis "fully decoded"
    }
    
    override bool hasKnownLength()
    {
        // Could have known length without being fully decoded.
        // BUG: RACE here, the length is set by audio thread possibly.
        return _decodedStream.lengthIsKnown();
    }

    override int lengthInFrames()
    {
        if (_decodedStream.lengthIsKnown())
        {
            // BUG: RACE here too, ditto
            return _decodedStream.lengthInFrames();
        }
        else
            return -1;
    }

    double lengthInSeconds()
    {
        if (_decodedStream.lengthIsKnown())
        {
            // BUG: RACE here too, ditto
            return cast(double)(_decodedStream.lengthInFrames()) / _mixer.getSampleRate();
        }
        else
            return -1.0;
    }

    int originalLengthInFrames() nothrow
    {
        return _decodedStream.originalLengthInFrames();
    }

    float sampleRate() nothrow
    {
        return _decodedStream.originalSampleRate();
    }

private:   
    IMixerInternal _mixer;
    DecodedStream _decodedStream;
    float _sampleRate;
    bool _disallowFullDecode = false;
}

private:


bool isChannelCountValid(int channels)
{
    return channels == 1 || channels == 2;
}

// 128kb is approx 300ms of stereo 44100Hz audio float data
// This wasn't tuned.
// The internet says `malloc`/`free` of 128kb should take ~10µs.
// That should be pretty affordable.
enum int CHUNK_SIZE_DECODED = 128 * 1024; 

/// Decode a stream, keeps it in a buffer so that multiple playback are possible.
struct DecodedStream
{
@nogc:
    void initializeFromFile(const(char)[] path)
    {
        _stream = mallocNew!BufferedStream(path);
        commonInitialization();
    }

    void initializeFromMemory(const(ubyte)[] inputData)
    {
        _stream = mallocNew!BufferedStream(inputData);
        commonInitialization();
    }

    ~this()
    {
        destroyFree(_stream);
    }

    void fullDecode(float sampleRate) nothrow
    {
        // Simulated normal decoding.
        // Because this is done is the command-thread, and the audio thread may play this, this is not thread-safe.
        float[64] dummySamples = void;
        float[32] volumeRamp = void;
        dummySamples[] = 0.0f;
        volumeRamp[] = 1.0f;
        float*[2] inoutBuffers;
        inoutBuffers[0] = &dummySamples[0];
        inoutBuffers[1] = &dummySamples[32];
        int frameOffset = 0;
        uint loopCount = 1;
        float[2] volume = [0.01f, 0.01f];
        while(!fullyDecoded)
        {            
            mixIntoBuffer(inoutBuffers, 32, frameOffset, loopCount, volumeRamp.ptr, volume, sampleRate);
        }
    }

    // Mix source[frameOffset..frames+frameOffset] into inoutChannels[0..frames] with volume `volume`,
    // decoding more stream if needed. Also extending source virtually if looping.
    void mixIntoBuffer(float*[] inoutChannels, 
                       int frames,
                       ref int frameOffset,
                       ref uint loopCount,
                       float* volumeRamp,
                       float[2] volume, 
                       float sampleRate, // will not change across calls
                       ) nothrow
    {
        // Initialize resamplers lazily
        if (!_resamplersInitialized)
        {
            for (int chan = 0; chan < 2; ++chan)
                _resamplers[chan].initialize(_stream.getSamplerate(), sampleRate, AudioResampler.Quality.Cubic);
            _resamplersInitialized = true;
        }

        while (frames != 0)
        {
            assert(frames >= 0);

            int framesEnd = frames + frameOffset;

            // need to decoder further?
            if (_framesDecodedAndResampled < framesEnd)
            {
                bool finished;
                decodeMoreSamples(framesEnd - _framesDecodedAndResampled, sampleRate, finished);
                if (!finished)
                {
                    assert(_framesDecodedAndResampled >= framesEnd);
                }
            }

            if (_lengthIsKnown)
            {
                // limit mixing to existing samples.
                if (framesEnd > _sourceLengthInFrames)
                    framesEnd = _sourceLengthInFrames;
            }

        
            int framesToCopy = framesEnd - frameOffset;
            if (framesToCopy > 0)
            {
                // mix into target buffer, upmix mono if needed
                for (int chan = 0; chan < 2; ++chan)
                {
                    int sourceChan = chan < _channels ? chan : 0; // only works for mono and stereo sources
                    _decodedBuffers[sourceChan].mixIntoBuffer(inoutChannels[chan], framesToCopy, frameOffset, volumeRamp, volume[chan]);
                }
            }

            frames -= framesToCopy;
            frameOffset += framesToCopy;

            if (frames != 0)
            {
                assert(_lengthIsKnown);
                if (frameOffset >= _sourceLengthInFrames) 
                {
                    frameOffset -= _sourceLengthInFrames; // loop
                    loopCount -= 1;
                    if (loopCount == 0)
                        return;
                }
            }
        }
    }

    // Decode in the stream buffers at least `frames` more frames.
    // Can possibly decode more than that.
    void decodeMoreSamples(int frames, float sampleRate, out bool terminated) nothrow
    {        
        int framesDone = 0;
        while (framesDone < frames)
        {
            bool terminatedResampling = false;

            // Decode any number of frames.
            // Return those in _decodedBuffers.
            int framesRead = readFromStreamAndResample(sampleRate, terminatedResampling);
            _framesDecodedAndResampled += framesRead;

            terminated = terminatedResampling;

            if (terminated)
            {
                _lengthIsKnown = true;
                _sourceLengthInFrames = _framesDecodedAndResampled;
                assert(fullyDecoded());

                // Fills with zeroes the rest of the buffers, if any output needed.
                if (frames > framesDone)
                {
                    int remain = frames - framesDone;
                    for (int chan = 0; chan < _channels; ++chan)
                    {
                        for (int n = 0; n < remain; ++n)
                        {
                            _decodedBuffers[chan].pushBack(0.0f);
                        }
                    }
                    framesDone += remain;
                }
                break;
            }
            framesDone += framesRead;
        }

        assert(framesDone >= frames);
    }

    bool lengthIsKnown() nothrow
    {
        return _lengthIsKnown;
    }

    int lengthInFrames() nothrow
    {
        assert(lengthIsKnown());
        return _sourceLengthInFrames;
    }

    bool fullyDecoded() nothrow
    {
        return lengthIsKnown() && (_framesDecodedAndResampled == _sourceLengthInFrames);
    }

    /// Read from stream. Can return any number of frames.
    /// Note that "terminated" is not the stream being terminated, but the _resampling output_ being terminated.
    /// That happens a few samples later.
    int readFromStreamAndResample(float sampleRate, out bool terminated) nothrow
    {
        // Get more input
        int framesDecoded;
        if (!_streamIsTerminated)
        {
            // Read input   
            try
            {
                framesDecoded = _stream.readSamplesFloat(_rawDecodeSamples.ptr, chunkFramesDecoder);
                _streamIsTerminated = framesDecoded != chunkFramesDecoder;
                if (_streamIsTerminated)
                    _flushResamplingOutput = true; // small state machine
            }
            catch(Exception e)
            {
                framesDecoded = 0;
                _streamIsTerminated = true;
                destroyFree(e);
            }

            // Deinterleave
            for (int n = 0; n < framesDecoded; ++n)
            {
                for (int chan = 0; chan < _channels; ++chan)
                {
                    _rawDecodeSamplesDeinterleaved[chan][n] = _rawDecodeSamples[_channels * n + chan];
                }
            }
        }
        else if (_flushResamplingOutput)
        {
            _flushResamplingOutput = false;

            // Fills with a few empty samples in order to flush the resampler output.
            framesDecoded = 128;

            for (int chan = 0; chan < _channels; ++chan)
            {
                for (int n = 0; n < framesDecoded; ++n)
                {
                    _rawDecodeSamplesDeinterleaved[chan][n] = 0;
                }
            }
        }
        else
        {
            // This is really terminated. No more output form the resampler.
            terminated = true;
            return 0;
        }

        size_t before = _decodedBuffers[0].length;
        for (int chan = 0; chan < _channels; ++chan)
        {
            _resamplers[chan].nextBufferPushMode(_rawDecodeSamplesDeinterleaved[chan].ptr, framesDecoded, _decodedBuffers[chan]);
        }
        size_t after = _decodedBuffers[0].length;

        // should return same amount of samples for all channels
        if (_channels > 1)
        {
            assert(_decodedBuffers[0].length == _decodedBuffers[1].length);
        }
        return cast(int) (after - before);
    }

private:
    int _channels;
    int _framesDecodedAndResampled; // Current number of decoded and resampled frames in _decodedBuffers.
    int _sourceLengthInFrames;      // Length of the resampled source in frames.
    bool _lengthIsKnown;            // true if _sourceLengthInFrames is known.
    bool _streamIsTerminated;       // Whether the stream has finished decoding.
    bool _flushResamplingOutput;    // Add a few silent sample at the end of decoder output.
    bool _resamplersInitialized;    // true if resampler initialized.

    BufferedStream _stream;         // using a BufferedStream to avoid blocking I/O
    AudioResampler[2] _resamplers;
    ChunkedVec!float[2] _decodedBuffers; // decoded and resampled _whole_ audio (this can be slow on resize)

    float[chunkFramesDecoder*2] _rawDecodeSamples; // interleaved samples from decoder
    float[chunkFramesDecoder][2] _rawDecodeSamplesDeinterleaved; // deinterleaved samples from decoder

    void commonInitialization()
    {
        _lengthIsKnown = false;
        _framesDecodedAndResampled = 0;
        _sourceLengthInFrames = -1;
        _streamIsTerminated = false;
        _channels = _stream.getNumChannels();
        _resamplersInitialized = false;
        for(int chan = 0; chan < _channels; ++chan)
            _decodedBuffers[chan] = makeChunkedVec!float(CHUNK_SIZE_DECODED);
        assert( isChannelCountValid(_stream.getNumChannels()) );
    }

    int originalLengthInFrames() nothrow
    {
        long len = _stream.getLengthInFrames();
        assert(len >= -1);
       
        if (len > int.max)
            return int.max; // longer lengths not supported by game-mixer

        return cast(int) len;
    }

    float originalSampleRate() nothrow
    {
        return _stream.getSamplerate();
    }
}

package:

/// A bit faster than a dynamic cast.
/// This is to avoid TypeInfo look-up.
T unsafeObjectCast(T)(Object obj)
{
    return cast(T)(cast(void*)(obj));
}