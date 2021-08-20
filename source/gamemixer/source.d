module gamemixer.source;

import dplug.core;
import gamemixer.bufferedstream;
import gamemixer.resampler;
import gamemixer.chunkedvec;

nothrow:
@nogc:


/// Represent a music or a sample.
interface IAudioSource
{
nothrow:
@nogc:
    /// Called before an IAudioSource is played on a mixer channel.
    void prepareToPlay(float sampleRate);

    /// Add output of the source to this buffer, with volume as gain.
    void mixIntoBuffer(float*[] inoutChannels, 
                       int frames, 
                       ref int frameOffset, 
                       ref uint loopCount,
                       float* volumeRamp, // multiply L by volumeRamp[n] * volume[0] 
                       float[2] volume);  // and multiply R by volumeRamp[n] * volume[1] 
}

package:

enum chunkFramesDecoder = 128; // PERF: tune that, while decoding a long MP3.

/// Concrete implementation of `IAudioSource`.
final class AudioSource : IAudioSource
{
@nogc:
public:
    /// Create a source from file.
    this(const(char)[] path)
    {
        _decodedStream.initializeFromFile(path);
    }

    /// Create a source from memory data.
    this(const(ubyte)[] inputData)
    {
        _decodedStream.initializeFromMemory(inputData);
    }

    override void prepareToPlay(float sampleRate)
    {
        _sampleRate = sampleRate;
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

private:   
    DecodedStream _decodedStream;
    float _sampleRate;
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
}

