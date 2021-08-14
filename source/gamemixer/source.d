module gamemixer.source;

import dplug.core;
import audioformats;

nothrow:
@nogc:


/// Represent a music or a sample.
interface IAudioSource
{
nothrow:
@nogc:
    /// Add output of the source to this buffer, with volume as gain.
    void mixIntoBuffer(float*[] inoutChannels, int frames, float volume, out bool terminated);
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
        stream.openFromFile(path);
        assert( isChannelCountValid(stream.getNumChannels()) );
    }

    /// Create a source from memory data.
    this(const(ubyte)[] inputData)
    {
        stream.openFromMemory(inputData);
        assert( isChannelCountValid(stream.getNumChannels()) );
    }

    void mixIntoBuffer(float*[] inoutChannels, int frames, float volume, out bool terminated)
    {
        assert(inoutChannels.length == 2);

        // TODO: right sample rate and do not block on files...

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
                framesRead = stream.readSamplesFloat(_readBuffer.ptr, chunk);
            }
            catch(Exception e)
            {
                destroyFree(e);
            }

            for (int n = 0; n < framesRead; ++n)
            {
                inoutChannels[0][framesDone + n] += _readBuffer[2 * n + 0] * volume;
                inoutChannels[1][framesDone + n] += _readBuffer[2 * n + 1] * volume;
            }

            terminated = (framesRead != chunk);
            if (terminated) 
                break;

            framesDone += chunk;
        }
    }

private:
    AudioStream stream;

    float[2 * 128] _readBuffer;

    bool isChannelCountValid(int channels)
    {
        return channels == 1 || channels == 2;
    }
}


// Responsibility: decode a stream, but in the target a 
struct DecodedStream
{

}