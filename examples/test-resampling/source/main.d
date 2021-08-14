module main;

import std.stdio;
import std.file;

import dplug.core;
import audioformats;

// Note: resampling is NOT part of the public API, do not depend on it
import gamemixer.resampler;

// Stretch a sound by 64x using sinc resampling.
void main(string[] args)
{
    string inputPath = "snare.wav";
    string outputPath = "snare-resampled.wav";
    
    AudioStream input, output;

    input.openFromFile(inputPath);
    float sampleRate = input.getSamplerate();
    int channels = input.getNumChannels();
    long lengthFrames = input.getLengthInFrames();

    writefln("Opening %s:", inputPath);
    writefln("  * format     = %s", convertAudioFileFormatToString(input.getFormat()) );
    writefln("  * samplerate = %s Hz", sampleRate);
    writefln("  * channels   = %s", channels);
    if (lengthFrames == audiostreamUnknownLength)
    {
        writefln("  * length     = unknown");
    }
    else
    {
        double seconds = lengthFrames / cast(double) sampleRate;
        writefln("  * length     = %.3g seconds (%s samples)", seconds, lengthFrames);
    }

    assert(channels == 1);

    float outputSampleRate = sampleRate * 64;
    Vec!float outBuf;
    float[] buf = new float[1024 * channels];
    output.openToFile(outputPath, AudioFileFormat.wav, sampleRate /* this creates a stretch */, channels);

    AudioResampler resampler;
    resampler.initialize(sampleRate, outputSampleRate, AudioResampler.Quality.Sinc);

    // Chunked encode/decode
    int totalFrames = 0;
    int framesRead;
    do
    {
        framesRead = input.readSamplesFloat(buf);
        resampler.nextBufferPushMode(buf.ptr, framesRead*channels, outBuf); // no deinterleave needed since 1 channels            
        totalFrames += framesRead;
    } while(framesRead > 0);

    output.writeSamplesFloat(outBuf[]);
    output.destroy();
        
    writefln("=> %s frames decoded and %s frames encoded to %s", totalFrames, outBuf[].length, outputPath);
}