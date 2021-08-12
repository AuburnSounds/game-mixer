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
    }

    /// Create a source from memory data.
    this(const(ubyte)[] inputData)
    {
        stream.openFromMemory(inputData);
    }

private:
    AudioStream stream;

}