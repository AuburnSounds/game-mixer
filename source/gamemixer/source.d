module gamemixer.source;

import dplug.core;
import audioformats;

nothrow:
@nogc:

// TODO: right sample rate and do not block on files...     

/// Represent a music or a sample.
interface IAudioSource
{
nothrow:
@nogc:
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

    void mixIntoBuffer(float*[] inoutChannels, 
                       int frames,
                       int frameOffset,
                       float volume, 
                       out bool terminated)
    {
        assert(inoutChannels.length == 2);
        try
        {
            _decodedStream.mixIntoBuffer(inoutChannels, frames, frameOffset, volume, terminated); 
        }
        catch(Exception e)
        {
            // decoding error => silently doesn't play
        }
    }

private:   
    DecodedStream _decodedStream;

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
                       out bool terminated)
    {
        int framesEnd = frames + frameOffset;

        if (_framesDecoded < framesEnd)
        {
            bool finished;
            decodeMoreSamples(framesEnd - _framesDecoded, finished);
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

    void decodeMoreSamples(int frames, out bool terminated) nothrow
    {
        int framesDone = 0;
        while (framesDone < frames)
        {
            int chunk = 128;
            if (frames - framesDone < 128)
            {
                chunk = frames - framesDone;
            }

            int framesRead = 0;
            try
            {
                framesRead = _stream.readSamplesFloat(_readBuffer.ptr, chunk);
            }
            catch(Exception e)
            {
                framesRead = 0;
                destroyFree(e);
            }

            for (int n = 0; n < framesRead; ++n)
            {
                _decodedBuffers[0].pushBack( _readBuffer[2 * n + 0] );
                _decodedBuffers[1].pushBack( _readBuffer[2 * n + 1] );
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

private:
    bool _lengthIsKnown;
    int _framesDecoded;
    int _lengthInFrames;
    float[2 * 128] _readBuffer;
    AudioStream _stream;
    Vec!float[2] _decodedBuffers;
}