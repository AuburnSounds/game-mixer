module gamemixer.bufferedstream;

import core.atomic;
import core.stdc.string: memcpy;

import dplug.core;
import gamemixer.delayline;
import audioformats;

package:

// Warning: the sequence of buffering, sample rate change, threading... is pretty complicated to follow.

// A `BufferedStream` has optional threaded decoding, activated for streams that perform file IO.
class BufferedStream
{
public:
@nogc:

    enum streamingDecodingIncrement = 0.1f; // No more than 100ms in decoded at once. TODO tune
    enum streamingBufferDuration = 1.0f; // Seems to be the default buffer size in foobar TODO tune

    this(const(char)[] path)
    {
        _bufMutex = makeMutex();
        _stream.openFromFile(path);
        _channels = _stream.getNumChannels();
        startDecodingThreadIfNeeded();
    }

    this(const(ubyte)[] data)
    {
        _bufMutex = makeMutex();
        _stream.openFromMemory(data);
        _channels = _stream.getNumChannels();
        startDecodingThreadIfNeeded();
    }  

    ~this()
    {
        if (_threaded)
        {
            atomicStore(_decodeThreadShouldDie, true);
            _decodeThread.join();
            _decodeBuffer.reallocBuffer(0);
        }
    }

    int getNumChannels() nothrow
    {
        return _stream.getNumChannels();
    }

    float getSamplerate() nothrow
    {
        return _stream.getSamplerate();
    }

    int readSamplesFloat(float* outData, int frames)
    {
        if (!_threaded)
        {
            // Non-threaded version
            return _stream.readSamplesFloat(outData, frames);
        }

        // <CONSUMER>
        int decodedFrames = 0;

        while(true)
        {
            if (decodedFrames == frames)
                break;

            assert(decodedFrames < frames);

            // Get number of frames in ring buffer.
            _bufMutex.lock();

        loop:

            int bufFrames = _bufferLength / _channels;
            if (bufFrames == 0)
            {
                if (atomicLoad(_streamIsFinished))
                {
                    _bufMutex.unlock();
                    break;
                }
                _bufferIsEmpty.wait(&_bufMutex);
                goto loop; // maybe it is filled now,w ait for data
            }
            int framesNeeded = frames - decodedFrames;
            if (bufFrames > framesNeeded)
                bufFrames = framesNeeded;

            // PERF: why not read newbufFrames instead of bufFrames ?
            int newbufFrames = _bufferLength / _channels; // re-read length to get oldest frame location
            const(float)* readPointerOldest = _streamingBuffer.readPointer() - (_bufferLength - 1);
            size_t bytes = float.sizeof * bufFrames * _channels; 
            memcpy(&outData[decodedFrames * _channels], readPointerOldest, bytes);
            _bufferLength -= bufFrames * _channels;
            assert(_bufferLength >= 0);
            
            decodedFrames += bufFrames;

            _bufMutex.unlock();
            _bufferIsFull.notifyOne(); // Buffer is probably not full anymore.

            // stream buffer is probably not full anymore
        }

        return decodedFrames;

        // </CONSUMER>
    }

private:
    Thread _decodeThread;
    AudioStream _stream;
    bool _threaded = false;
    int _channels;
    shared(bool) _decodeThreadShouldDie = false;
    shared(bool) _streamIsFinished = false;


    UncheckedMutex _bufMutex;
    ConditionVariable _bufferIsFull;
    ConditionVariable _bufferIsEmpty;

    // all protected by _bufMutex too
    int _bufferLength;   // is counted in individual samples, not frames
    int _bufferCapacity; // is counted in individual samples, not frames
    Delayline!float _streamingBuffer;

    int _decodeIncrement; // max number of samples to decode at once, to avoid longer mutex hold
    float[] _decodeBuffer; // producer-only buffer before-pushgin

    void startDecodingThreadIfNeeded()
    {
        if (!_stream.realtimeSafe())
        {
            _threaded = true;

            _bufferIsEmpty = makeConditionVariable();
            _bufferIsFull = makeConditionVariable();

            // compute amount of buffer we want
            int streamingBufferSamples = cast(int)(streamingBufferDuration * _stream.getSamplerate() * _channels);
            
            _streamingBuffer.initialize(streamingBufferSamples);
            _bufferLength = 0;
            _bufferCapacity = streamingBufferSamples;

            _decodeIncrement = cast(int)(streamingDecodingIncrement * _stream.getSamplerate());
            _decodeBuffer.reallocBuffer(_decodeIncrement * _channels);

            // start event thread
            _decodeThread = makeThread(&decodeStream);
            _decodeThread.start();
        }
    }

    void decodeStream() nothrow
    {
        // <PRODUCER>

        loop:
        while(!atomicLoad(_decodeThreadShouldDie))
        {            
            // Get available room in the delayline.
            _bufMutex.lock();
            
            // How much room there is in the streaming buffer?
            int roomFrames = ( _bufferCapacity - _bufferLength) / _stream.getNumChannels();

            assert(roomFrames >= 0);
            if (roomFrames > _decodeIncrement)
                roomFrames = _decodeIncrement;

            if (roomFrames == 0)
            {
                // buffer is full, wait on condition
                _bufferIsFull.wait(&_bufMutex);
                _bufMutex.unlock();
                goto loop;                    
            }
            _bufMutex.unlock();

            assert(roomFrames != 0);

            // Decode that much frames, but without holding the mutex.
            int framesRead;
            try
            {
                framesRead = _stream.readSamplesFloat(_decodeBuffer.ptr, roomFrames);
            }
            catch(Exception e)
            {
                // decode error, stop decoding
                framesRead = 0;
            }

            bool streamIsFinished = (framesRead != roomFrames);
            if (streamIsFinished)
            {
                atomicStore(_streamIsFinished, true);
            }

            if (framesRead)
            {
                // Re-lock the mutex in order to fill the buffer
                _bufMutex.lock();
                int samples = framesRead * _channels;
                _streamingBuffer.feedBuffer( _decodeBuffer[0..samples] );
                _bufferLength += samples;
                assert(_bufferLength <= _bufferCapacity);
                _bufMutex.unlock();
                _bufferIsEmpty.notifyOne(); // stream buffer is probably not empty anymore
            }
            
            if (streamIsFinished)
                return;
        }
        // <PRODUCER>
    }
}