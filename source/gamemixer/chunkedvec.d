/**
Defines `ChunkedVec`, a grow-only buffer that allocates fixed chunks of memory,
so as to avoid costly `realloc` calls with large sizes.

Copyright: Guillaume Piolat 2015-2016.
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors:   Guillaume Piolat
*/
module gamemixer.chunkedvec;

import core.stdc.stdlib : malloc, free;

import dplug.core.vec;
import dplug.core.math;

nothrow:
@nogc:

/// Returns: A newly created `ChunkedVec`.
/// Params:
///     chunkLength number of T elements in a chunk.
ChunkedVec!T makeChunkedVec(T)(int chunkLength) nothrow @nogc
{
    return ChunkedVec!T(chunkLength);
}

/// `ChunkedVec` can only grow.
/// `ChunkedVec` has one indirection when indexing.
/// `ChunkedVec` has a fixed-sized allocations list.
struct ChunkedVec(T)
{
nothrow:
@nogc:
public:

    this(int chunkLength)
    {
        assert(isPowerOfTwo(chunkLength));
        _chunkLength = chunkLength;
        _chunkMask = chunkLength - 1;
        _shift = iFloorLog2(_chunkLength);
        _currentIndex = 0;
        _currentChunk = -1;
        _len = 0;
        assert(1 << _shift == _chunkLength);
    }

    ~this()
    {
        foreach(c; _chunks[])
        {
            free(c);
        }
    }

    @disable this(this);

    ref inout(T) opIndex(size_t n) pure inout
    {
        size_t chunkIndex = n >>> _shift;
        return _chunks[chunkIndex][n & _chunkMask];
    }

    void pushBack(T x)
    {
        if (_currentIndex == 0)
        {
            _chunks.pushBack( cast(T*) malloc( T.sizeof * _chunkLength ) );
            _currentChunk += 1;
        }
        _chunks[_currentChunk][_currentIndex] = x;
        _currentIndex = (_currentIndex + 1) & _chunkMask;
        _len++;
    }

    size_t length() pure const
    {
        return _len;
    }

private:
    int _chunkLength;
    int _chunkMask;
    int _shift;
    int _currentIndex;
    int _currentChunk;
    size_t _len;
    Vec!(T*) _chunks; 
}