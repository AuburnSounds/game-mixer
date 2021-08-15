module gamemixer.source;

import dplug.core;
import audioformats;

import gamemixer.resampler;

nothrow:
@nogc:

// TODO: right sample rate and do not block on files...     

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

    void mixIntoBuffer(float*[] inoutChannels, 
                       int frames,
                       int frameOffset,
                       float volume, 
                       out bool terminated)
    {
        assert(inoutChannels.length == 2);
        try
        {
            _decodedStream.mixIntoBuffer(inoutChannels, frames, frameOffset, volume, _sampleRate, terminated); 
        }
        catch(Exception e)
        {
            // decoding error => silently doesn't play
        }
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
        _framesDecoded = 0;
        _lengthInFrames = -1;
        _stream.openFromFile(path);
        assert( isChannelCountValid(_stream.getNumChannels()) );
    }

    void initializeFromMemory(const(ubyte)[] inputData)
    {
        _lengthIsKnown = false;
        _framesDecoded = 0;
        _lengthInFrames = -1;
        _stream.openFromMemory(inputData);
        assert( isChannelCountValid(_stream.getNumChannels()) );
    }

    void mixIntoBuffer(float*[] inoutChannels, 
                       int frames,
                       int frameOffset,
                       float volume, 
                       float sampleRate, // will not change across calls
                       out bool terminated)
    {
        int framesEnd = frames + frameOffset;

        if (_framesDecoded < framesEnd)
        {
            bool finished;
            decodeMoreSamples(framesEnd - _framesDecoded, sampleRate, finished);
        }

        if (_lengthIsKnown)
        {
            if (frames >= _lengthInFrames)
            {
                terminated = true;
                return;
            }

            if (framesEnd > lengthInFrames())
                framesEnd = lengthInFrames();
        }

        int framesToCopy = framesEnd - frameOffset;

        if (framesToCopy > 0)
        {
            float* decodedL = _decodedBuffers[0].ptr;
            float* decodedR = _decodedBuffers[1].ptr;
            inoutChannels[0][0..framesToCopy] += decodedL[frameOffset..framesEnd];
            inoutChannels[1][0..framesToCopy] += decodedR[frameOffset..framesEnd];
        }
        inoutChannels[0][framesToCopy..frames] = 0.0f; 
        inoutChannels[1][framesToCopy..frames] = 0.0f;

        if (_lengthIsKnown)
            terminated = (framesEnd == lengthInFrames());
        else
            terminated = false;
    }

    void decodeMoreSamples(int frames, float sampleRate, out bool terminated) nothrow
    {
        int framesDone = 0;
        while (framesDone < frames)
        {
            int chunk = CHUNK_FRAMES_RESAMPLED;
            if (frames - framesDone < CHUNK_FRAMES_RESAMPLED)
            {
                chunk = frames - framesDone;
            }

            int framesRead = 0;
            try
            {
                framesRead = readFromStreamAndResample(chunk, sampleRate);
            }
            catch(Exception e)
            {
                framesRead = 0;
                destroyFree(e);
            }

            for (int n = 0; n < framesRead; ++n)
            {
                _decodedBuffers[0].pushBack( _resampledBuffer[0][n] );
                _decodedBuffers[1].pushBack( _resampledBuffer[0][n] );
            }

            _framesDecoded += framesRead;

            terminated = (framesRead != chunk);
            if (terminated)
            {
                _lengthIsKnown = true;
                assert(fullyDecoded());
                break;
            }
            framesDone += chunk;
        }
    }

    bool lengthIsKnown() nothrow
    {
        return _lengthIsKnown;
    }

    int lengthInFrames() nothrow
    {
        assert(lengthIsKnown());
        return _lengthInFrames;
    }

    bool fullyDecoded() nothrow
    {
        return lengthIsKnown() && (_framesDecoded == _lengthInFrames);
    }

    /// Read from stream. Return as much frames as possible. 
    /// Return less than `requestedFrames` if stream is finished.
    int readFromStreamAndResample(int requestedFrames, float sampleRate)
    {

        // TODO
        // this needs multi-channel resampler...
        assert(false);
    }

private:
    bool _lengthIsKnown;
    int _framesDecoded;
    int _lengthInFrames;

    enum CHUNK_FRAMES_RESAMPLED = 128; // PERF: tune that, while decoding a long MP3.

    float[CHUNK_FRAMES_RESAMPLED][2] _resampledBuffer;
    AudioStream _stream;
    Vec!float[2] _decodedBuffers;

    AudioResampler[2] _resamplers;
}