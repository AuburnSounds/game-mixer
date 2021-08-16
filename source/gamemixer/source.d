module gamemixer.source;

import dplug.core;
import gamemixer.bufferedstream;
import gamemixer.resampler;

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
    void mixIntoBuffer(float*[] inoutChannels, int frames, int frameOffset, float volume, out bool terminated);
}

package:

/// Concrete implementation of `IAudioSource`.
class AudioSource : IAudioSource
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
                                int frameOffset,
                                float volume, 
                                out bool terminated)
    {
        assert(inoutChannels.length == 2);
        _decodedStream.mixIntoBuffer(inoutChannels, frames, frameOffset, volume, _sampleRate, terminated);         
    }

private:   
    DecodedStream _decodedStream;
    float _sampleRate;
}

private:


bool isChannelCountValid(int channels)
{
    return /*channels == 1 ||*/ channels == 2;
}


/// Decode a stream, keeps it in a buffer so that multiple playback are possible.
struct DecodedStream
{
@nogc:
    void initializeFromFile(const(char)[] path)
    {
        _lengthIsKnown = false;
        _framesDecodedAndResampled = 0;
        _sourceLengthInFrames = -1;
        _streamIsTerminated = false;
        _stream = mallocNew!BufferedStream(path);
        _resamplersInitialized = false;
        assert( isChannelCountValid(_stream.getNumChannels()) );
    }

    void initializeFromMemory(const(ubyte)[] inputData)
    {
        _lengthIsKnown = false;
        _framesDecodedAndResampled = 0;
        _sourceLengthInFrames = -1;
        _streamIsTerminated = false;
        _stream = mallocNew!BufferedStream(inputData);
        _resamplersInitialized = false;
        assert( isChannelCountValid(_stream.getNumChannels()) );
    }

    ~this()
    {
        destroyFree(_stream);
    }

    void mixIntoBuffer(float*[] inoutChannels, 
                       int frames,
                       int frameOffset,
                       float volume, 
                       float sampleRate, // will not change across calls
                       out bool terminated) nothrow
    {
        // Initialize resamplers lazily
        if (!_resamplersInitialized)
        {
            _resamplers[0].initialize(_stream.getSamplerate(), sampleRate);
            _resamplers[1].initialize(_stream.getSamplerate(), sampleRate);
            _resamplersInitialized = true;
        }

        int framesEnd = frames + frameOffset;

        // need to decoder further?
        if (_framesDecodedAndResampled < framesEnd)
        {
            bool finished;
            decodeMoreSamples(framesEnd - _framesDecodedAndResampled, sampleRate, finished);
        }

        if (_lengthIsKnown)
        {
            if (frames >= _sourceLengthInFrames) 
            {
                // if we are asking for samples past starting point, 
                // this means we have finished mixing this source
                terminated = true;
                return; // nothing to mix
            }

            // limit mixing to existing samples.
            if (framesEnd > lengthInFrames())
                framesEnd = lengthInFrames();
        }

        int framesToCopy = framesEnd - frameOffset;

        if (framesToCopy > 0)
        {
            // mix into target buffer
            float* decodedL = _decodedBuffers[0].ptr;
            float* decodedR = _decodedBuffers[1].ptr;
            inoutChannels[0][0..framesToCopy] += decodedL[frameOffset..framesEnd] * volume;
            inoutChannels[1][0..framesToCopy] += decodedR[frameOffset..framesEnd] * volume;
        }
        
        // fills the rest with zeroes
        inoutChannels[0][framesToCopy..frames] = 0.0f; 
        inoutChannels[1][framesToCopy..frames] = 0.0f;

        if (_lengthIsKnown)
            terminated = (framesEnd == lengthInFrames());
        else
            terminated = false;
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
            // Return those in _resampledBuffer.   
            int framesRead = readFromStreamAndResample(sampleRate, terminatedResampling);
           
            // Store these new frames in _decodedBuffers.
            for (int n = 0; n < framesRead; ++n)
            {
                // PERF: could as well push resampled audio directly in _decodedBuffers
                _decodedBuffers[0].pushBack( _resampledBuffer[0][n] ); 
                _decodedBuffers[1].pushBack( _resampledBuffer[1][n] );
            }

            _framesDecodedAndResampled += framesRead;

            terminated = terminatedResampling;

            if (terminated)
            {
                _lengthIsKnown = true;
                _sourceLengthInFrames = _framesDecodedAndResampled;
                assert(fullyDecoded());
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
        _resampledBuffer[0].clearContents();
        _resampledBuffer[1].clearContents();

        // Get more input
        int framesDecoded;
        if (!_streamIsTerminated)
        {
            // Read input   
            try
            {
                framesDecoded = _stream.readSamplesFloat(_rawDecodeSamples.ptr, CHUNK_FRAMES_DECODER);
                _streamIsTerminated = framesDecoded != CHUNK_FRAMES_DECODER;
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
                _rawDecodeSamplesDeinterleaved[0][n] = _rawDecodeSamples[2 * n];
                _rawDecodeSamplesDeinterleaved[1][n] = _rawDecodeSamples[2 * n + 1];
            }
        }
        else if (_flushResamplingOutput)
        {
            _flushResamplingOutput = false;

            // Fills with a few empty samples in order to flush the resampler output.
            framesDecoded = 128;
            for (int n = 0; n < framesDecoded; ++n)
            {
                _rawDecodeSamplesDeinterleaved[0][n] = 0;
                _rawDecodeSamplesDeinterleaved[1][n] = 0;
            }
        }
        else
        {
            // This is really terminated. No more output form the resampler.
            terminated = true;
            return 0;
        }

        _resamplers[0].nextBufferPushMode(_rawDecodeSamplesDeinterleaved[0].ptr, framesDecoded, _resampledBuffer[0]);
        _resamplers[1].nextBufferPushMode(_rawDecodeSamplesDeinterleaved[1].ptr, framesDecoded, _resampledBuffer[1]);

        // should return same amount of samples
        assert(_resampledBuffer[0].length == _resampledBuffer[1].length);
        return cast(int) _resampledBuffer[0].length;
    }

private:
    bool _lengthIsKnown;            // true if _sourceLengthInFrames is known.
    int _framesDecodedAndResampled; // Current number of decoded and resampled frames in _decodedBuffers.
    int _sourceLengthInFrames;      // Length of the resampled source in frames.
    bool _streamIsTerminated;       // Whether the stream has finished decoding.
    bool _flushResamplingOutput;    // Add a few silent sample at the end of decoder output.
    bool _resamplersInitialized;    // true if resampler initialized.

    enum CHUNK_FRAMES_DECODER = 128; // PERF: tune that, while decoding a long MP3.
    
    BufferedStream _stream;         // using a BufferedStream to avoid blocking I/O
    AudioResampler[2] _resamplers;
    Vec!float[2] _decodedBuffers; // decoded and resampled whole audio    
    float[CHUNK_FRAMES_DECODER*2] _rawDecodeSamples; // interleaved samples from decoder
    float[CHUNK_FRAMES_DECODER][2] _rawDecodeSamplesDeinterleaved; // deinterleaved samples from decoder
    Vec!float[2] _resampledBuffer; // resampled scratch buffer
}

