module gamemixer.resampler;

/* simple resampler with variety of algorithms
* based on the code by Christopher Snowhill
*
* Permission to use, copy, modify, and/or distribute this software for any
* purpose with or without fee is hereby granted, provided that the above
* copyright notice and this permission notice appear in all copies.
*
* THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
* WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
* MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
* ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
* WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
* ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
* OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
*/
// AFAIK this was translated to D by Ketmar

import core.stdc.string : memcpy;
import core.stdc.math : sin, cos, fmod;
import std.math : PI;
import dplug.core.math : fast_fabs;
import dplug.core.vec;

nothrow:
@nogc:
    
/// Audio resampler.
// MAYDO: this might as well use dplug's Delayline
struct AudioResampler
{
nothrow:
@nogc:
public:

    enum Quality 
    {
        Zoh,
        Blep,
        Linear,
        Blam,
        Cubic,
        Sinc,
    }

    void initialize(double srcRate, double destRate, Quality quality = Quality.Sinc)
    {
        buildAudioResamplerTables(); // no synchronization for this
        this = this.init;
        rate(srcRate / destRate);
        setQuality(quality);
    }

    // Feed input samples, get back as much output samples as possible.
    // Note: output `Vec` isn't cleared, samples are pushed back. This can reallocate.
    void nextBufferPushMode(float* input, int inputFrames, ref Vec!float output)
    {
        int framesPushed = 0;

        while (framesPushed < inputFrames)
        {
            // feed resampler
            while ((framesPushed < inputFrames) && freeCount() > 0) 
            {
                writeSample(input[framesPushed++]);
            }

            // get data out of resampler
            while (sampleCount() > 0) 
            {
                output.pushBack(sampleFloat());
                removeSample();
            }
        }
    }

    // Must feed zeroes if no more input.
    alias PullModeGetSamplesCallback = void delegate(float* buf, int frames);

    void nextBufferPullMode(scope PullModeGetSamplesCallback getSamples, float* output, int frames)
    {
        float[BufferSize] pulled;

        int framesPulled = 0;
        while (framesPulled < frames)
        {
            int N = freeCount();

            getSamples(pulled.ptr, N);

            // feed resampler
            for(int n = 0; n < N; ++n)
            {
                writeSample(pulled[n]);
            }

            // get data out of resampler
            while (sampleCount() > 0) 
            {
                float s = sampleFloat();
                if (framesPulled < frames)
                    output[framesPulled++] = s;
                removeSample();
            }
        }
    }

private:

    int writePos = SincWidth - 1;
    int writeFilled = 0;
    int readPos = 0;
    int readFilled = 0;
    float phase = 0;
    float phaseInc = 0;
    float invPhase = 0;
    float invPhaseInc = 0;
    Quality xquality = Quality.max;
    byte delayAdded = -1;
    byte delayRemoved = -1;
    float lastAmp = 0;
    float accum = 0;
    float[BufferSize*2] bufferIn =
    [ 0.0f, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ];
    float[BufferSize+SincWidth*2-1] bufferOut =
    [ 0.0f, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ];


    // return number of samples that resampler is able to accept before overflowing
    int freeCount () 
    {
        return BufferSize-writeFilled;
    }

    // return number of samples that resampler is able to emit now
    int sampleCount () 
    {
        if (readFilled < 1 && ((xquality != Quality.Blep && xquality != Quality.Blam) || invPhaseInc)) 
            doFillAndRemoveDelay();
        return readFilled;
    }

    /// Set quality of the resampling (default = sinc).
    void setQuality(Quality quality) 
    {
        if (xquality != quality) 
        {
            if (quality == Quality.Blep || quality == Quality.Blep ||
                quality == Quality.Blam || quality == Quality.Blam)
            {
                readPos = 0;
                readFilled = 0;
                lastAmp = 0;
                accum = 0;
                bufferOut[] = 0;
            }
            delayAdded = -1;
            delayRemoved = -1;
        }
        xquality = quality;
    }

    // Get processed sample out of resampler/
    float sampleFloat() 
    {
        if (readFilled < 1 && phaseInc) 
            doFillAndRemoveDelay();
        if (readFilled < 1) 
            return 0;
        if (xquality == Quality.Blep || xquality == Quality.Blam) 
        {
            return bufferOut.ptr[readPos] + accum;
        } else {
            return bufferOut.ptr[readPos];
        }
    }

    // you should remove sample after getting it's value
    // "normal" resampling should decay accum
    void removeSample (bool decay=true) {
        if (readFilled > 0) {
            if (xquality == Quality.Blep || xquality == Quality.Blam) {
                accum += bufferOut.ptr[readPos];
                bufferOut.ptr[readPos] = 0;
                if (decay) {
                    accum -= accum*(1.0f/8192.0f);
                    if (fast_fabs(accum) < 1e-20f) accum = 0;
                }
            }
            --readFilled;
            readPos = (readPos+1)%BufferSize;
        }
    }

    // is resampler ready to emiting output samples?
    // note that buffer can contain unread samples, it is ok
    bool ready () 
    {
        return (writeFilled > minFilled());
    }

    // set resampling rate (srate/drate)
    void rate (double aRateFactor) 
    {
        phaseInc = aRateFactor;
        aRateFactor = 1.0/aRateFactor;
        invPhaseInc = aRateFactor;
    }

    // feed resampler
    void writeSample (float s) 
    {
        if (delayAdded < 0) 
        {
            delayAdded = 0;
            writeFilled = inputDelay();
        }
        if (writeFilled < BufferSize) 
        {
            float s32 = s;
            s32 *= 256.0;
            bufferIn.ptr[writePos] = s;
            bufferIn.ptr[writePos+BufferSize] = s;
            ++writeFilled;
            writePos = (writePos+1)%BufferSize;
        }
    }

    enum paddingSize = SincWidth-1;

    // ////////////////////////////////////////////////////////////////////// //
private:
    int minFilled () {
        switch (xquality) {
            default:
            case Quality.Zoh:
            case Quality.Blep:
                return 1;
            case Quality.Linear:
            case Quality.Blam:
                return 2;
            case Quality.Cubic:
                return 4;
            case Quality.Sinc:
                return SincWidth*2;
        }
    }

    int inputDelay () 
    {
        switch (xquality) {
            default:
            case Quality.Zoh:
            case Quality.Blep:
            case Quality.Linear:
            case Quality.Blam:
                return 0;
            case Quality.Cubic:
                return 1;
            case Quality.Sinc:
                return SincWidth-1;
        }
    }

    int outputDelay () 
    {
        switch (xquality) {
            default:
            case Quality.Zoh:
            case Quality.Linear:
            case Quality.Cubic:
            case Quality.Sinc:
                return 0;
            case Quality.Blep:
            case Quality.Blam:
                return SincWidth-1;
        }
    }

    int doZoh (float** outbuf, float* outbufend) {
        int ccinsize = writeFilled;
        const(float)* inbuf = bufferIn.ptr+BufferSize+writePos-writeFilled;
        int used = 0;
        ccinsize -= 1;
        if (ccinsize > 0) {
            float* ccoutbuf = *outbuf;
            const(float)* ccinbuf = inbuf;
            const(float)* ccinbufend = ccinbuf+ccinsize;
            float ccPhase = phase;
            float ccPhaseInc = phaseInc;
            do {
                if (ccoutbuf >= outbufend) break;
                float sample = *ccinbuf;
                *ccoutbuf++ = sample;
                ccPhase += ccPhaseInc;
                ccinbuf += cast(int)ccPhase;
                assert(ccPhase >= 0);
                ccPhase = ccPhase - cast(int)ccPhase;
            } while (ccinbuf < ccinbufend);
            phase = ccPhase;
            *outbuf = ccoutbuf;
            used = cast(int)(ccinbuf-inbuf);
            writeFilled -= used;
        }
        return used;
    }

    int doBlep (float** outbuf, float* outbufend) {
        int ccinsize = writeFilled;
        const(float)* inbuf = bufferIn.ptr+BufferSize+writePos-writeFilled;
        int used = 0;
        ccinsize -= 1;
        if (ccinsize > 0) {
            float* ccoutbuf = *outbuf;
            const(float)* ccinbuf = inbuf;
            const(float)* ccinbufend = ccinbuf+ccinsize;
            float ccLastAmp = lastAmp;
            float ccInvPhase = invPhase;
            float ccInvPhaseInc = invPhaseInc;
            enum int step = cast(int)(BlepCutoff*Resolution);
            enum int winstep = Resolution;
            do {
                if (ccoutbuf+SincWidth*2 > outbufend) break;
                float sample = (*ccinbuf++)-ccLastAmp;
                if (sample) {
                    float[SincWidth*2] kernel = void;
                    float kernelSum = 0.0f;
                    int phaseReduced = cast(int)(ccInvPhase*Resolution);
                    int phaseAdj = phaseReduced*step/Resolution;
                    int i = SincWidth;
                    for (; i >= -SincWidth+1; --i) {
                        int pos = i*step;
                        int winpos = i*winstep;
                        kernelSum += kernel.ptr[i+SincWidth-1] = sincLut[abs(phaseAdj-pos)]*windowLut[abs(phaseReduced-winpos)];
                    }
                    ccLastAmp += sample;
                    sample /= kernelSum;
                    for (i = 0; i < SincWidth*2; ++i) ccoutbuf[i] += sample*kernel.ptr[i];
                }
                ccInvPhase += ccInvPhaseInc;
                ccoutbuf += cast(int)ccInvPhase;
                ccInvPhase = fmod(ccInvPhase, 1.0f);
            } while (ccinbuf < ccinbufend);
            invPhase = ccInvPhase;
            lastAmp = ccLastAmp;
            *outbuf = ccoutbuf;
            used = cast(int)(ccinbuf-inbuf);
            writeFilled -= used;
        }
        return used;
    }

    int doLinear (float** outbuf, float* outbufend) {
        int ccinsize = writeFilled;
        const(float)* inbuf = bufferIn.ptr+BufferSize+writePos-writeFilled;
        int used = 0;
        ccinsize -= 2;
        if (ccinsize > 0) {
            float* ccoutbuf = *outbuf;
            const(float)* ccinbuf = inbuf;
            const(float)* ccinbufend = ccinbuf+ccinsize;
            float ccPhase = phase;
            float ccPhaseInc = phaseInc;
            do {
                if (ccoutbuf >= outbufend) break;
                float sample = ccinbuf[0]+(ccinbuf[1]-ccinbuf[0])*ccPhase;
                *ccoutbuf++ = sample;
                ccPhase += ccPhaseInc;
                ccinbuf += cast(int)ccPhase;
                assert(ccPhase >= 0);
                ccPhase = ccPhase - cast(int)ccPhase;
            } while (ccinbuf < ccinbufend);
            phase = ccPhase;
            *outbuf = ccoutbuf;
            used = cast(int)(ccinbuf-inbuf);
            writeFilled -= used;
        }
        return used;
    }

    int doBlam (float** outbuf, float* outbufend) {
        int ccinsize = writeFilled;
        const(float)*inbuf = bufferIn.ptr+BufferSize+writePos-writeFilled;
        int used = 0;
        ccinsize -= 2;
        if (ccinsize > 0) {
            float* ccoutbuf = *outbuf;
            const(float)* ccinbuf = inbuf;
            const(float)* ccinbufend = ccinbuf+ccinsize;
            float ccLastAmp = lastAmp;
            float ccPhase = phase;
            float ccPhaseInc = phaseInc;
            float ccInvPhase = invPhase;
            float ccInvPhaseInc = invPhaseInc;
            enum int step = cast(int)(BlamCutoff*Resolution);
            enum int winstep = Resolution;
            do {
                if (ccoutbuf+SincWidth*2 > outbufend) break;
                float sample = ccinbuf[0];
                if (ccPhaseInc < 1.0f) sample += (ccinbuf[1]-ccinbuf[0])*ccPhase;
                sample -= ccLastAmp;
                if (sample) {
                    float[SincWidth*2] kernel = void;
                    float kernelSum = 0.0f;
                    int phaseReduced = cast(int)(ccInvPhase*Resolution);
                    int phaseAdj = phaseReduced*step/Resolution;
                    int i = SincWidth;
                    for (; i >= -SincWidth+1; --i) {
                        int pos = i*step;
                        int winpos = i*winstep;
                        kernelSum += kernel.ptr[i+SincWidth-1] = sincLut[abs(phaseAdj-pos)]*windowLut[abs(phaseReduced-winpos)];
                    }
                    ccLastAmp += sample;
                    sample /= kernelSum;
                    for (i = 0; i < SincWidth*2; ++i) ccoutbuf[i] += sample*kernel.ptr[i];
                }
                if (ccInvPhaseInc < 1.0f) {
                    ++ccinbuf;
                    ccInvPhase += ccInvPhaseInc;
                    ccoutbuf += cast(int)ccInvPhase;
                    ccInvPhase = fmod(ccInvPhase, 1.0f);
                } else {
                    ccPhase += ccPhaseInc;
                    ++ccoutbuf;
                    ccinbuf += cast(int)ccPhase;
                    ccPhase = fmod(ccPhase, 1.0f);
                }
            } while (ccinbuf < ccinbufend);
            phase = ccPhase;
            invPhase = ccInvPhase;
            lastAmp = ccLastAmp;
            *outbuf = ccoutbuf;
            used = cast(int)(ccinbuf-inbuf);
            writeFilled -= used;
        }
        return used;
    }

    int doCubic (float** outbuf, float* outbufend) {
        int ccinsize = writeFilled;
        const(float)*inbuf = bufferIn.ptr+BufferSize+writePos-writeFilled;
        int used = 0;
        ccinsize -= 4;
        if (ccinsize > 0) {
            float* ccoutbuf = *outbuf;
            const(float)* ccinbuf = inbuf;
            const(float)* ccinbufend = ccinbuf+ccinsize;
            float ccPhase = phase;
            float ccPhaseInc = phaseInc;
            
            do {
                int i;
                float sample;
                if (ccoutbuf >= outbufend) break;
                float* kernel = cubicLut.ptr+cast(int)(ccPhase*Resolution)*4;
                for (sample = 0, i = 0; i < 4; ++i) sample += ccinbuf[i]*kernel[i];
                *ccoutbuf++ = sample;
                ccPhase += ccPhaseInc;
                ccinbuf += cast(int)ccPhase;
                assert(ccPhase >= 0);
                ccPhase = ccPhase - cast(int)ccPhase;
            } while (ccinbuf < ccinbufend);
            phase = ccPhase;
            *outbuf = ccoutbuf;
            used = cast(int)(ccinbuf-inbuf);
            writeFilled -= used;
        }
        return used;
    }

    int doSinc (float** outbuf, float* outbufend) {
        int ccinsize = writeFilled;
        const(float)*inbuf = bufferIn.ptr+BufferSize+writePos-writeFilled;
        int used = 0;
        ccinsize -= SincWidth*2;
        if (ccinsize > 0) {
            float* ccoutbuf = *outbuf;
            const(float)* ccinbuf = inbuf;
            const(float)* ccinbufend = ccinbuf+ccinsize;
            float ccPhase = phase;
            float ccPhaseInc = phaseInc;
            immutable int step = (ccPhaseInc > 1.0f ? cast(int)(Resolution/ccPhaseInc*SincCutoff) : cast(int)(Resolution*SincCutoff));
            enum int winstep = Resolution;
            do {
                float[SincWidth*2] kernel = void;
                float kernelSum = 0.0;
                int i = SincWidth;
                int phaseReduced = cast(int)(ccPhase*Resolution);
                int phaseAdj = phaseReduced*step/Resolution;
                float sample;
                if (ccoutbuf >= outbufend) break;
                for (; i >= -SincWidth+1; --i) {
                    int pos = i*step;
                    int winpos = i*winstep;
                    kernelSum += kernel.ptr[i+SincWidth-1] = sincLut[abs(phaseAdj-pos)]*windowLut[abs(phaseReduced-winpos)];
                }
                for (sample = 0, i = 0; i < SincWidth*2; ++i) sample += ccinbuf[i]*kernel.ptr[i];
                *ccoutbuf++ = cast(float)(sample/kernelSum);
                ccPhase += ccPhaseInc;
                ccinbuf += cast(int)ccPhase;
                assert(ccPhase >= 0);
                ccPhase = ccPhase - cast(int)ccPhase;
            } while (ccinbuf < ccinbufend);
            phase = ccPhase;
            *outbuf = ccoutbuf;
            used = cast(int)(ccinbuf-inbuf);
            writeFilled -= used;
        }
        return used;
    }

    void doFill () 
    {        
        int ccMinFilled = minFilled();
        int ccXquality = xquality;
        while (writeFilled > ccMinFilled && readFilled < BufferSize) {
            int ccWritePos = (readPos+readFilled)%BufferSize;
            int ccWriteSize = BufferSize-ccWritePos;
            float* ccoutbuf = bufferOut.ptr+ccWritePos;
            if (ccWriteSize > BufferSize-readFilled) ccWriteSize = BufferSize-readFilled;
            switch (ccXquality) {
                case Quality.Zoh:
                    doZoh(&ccoutbuf, ccoutbuf+ccWriteSize);
                    break;
                case Quality.Blep:
                    int used;
                    int ccWriteExtra = 0;
                    if (ccWritePos >= readPos) ccWriteExtra = readPos;
                    if (ccWriteExtra > SincWidth*2-1) ccWriteExtra = SincWidth*2-1;
                    memcpy(bufferOut.ptr+BufferSize, bufferOut.ptr, ccWriteExtra*bufferOut[0].sizeof);
                    used = doBlep(&ccoutbuf, ccoutbuf+ccWriteSize+ccWriteExtra);
                    memcpy(bufferOut.ptr, bufferOut.ptr+BufferSize, ccWriteExtra*bufferOut[0].sizeof);
                    if (!used) return;
                    break;
                case Quality.Linear:
                    doLinear(&ccoutbuf, ccoutbuf+ccWriteSize);
                    break;
                case Quality.Blam:
                    float* outbuf = ccoutbuf;
                    int ccWriteExtra = 0;
                    if (ccWritePos >= readPos) ccWriteExtra = readPos;
                    if (ccWriteExtra > SincWidth*2-1) ccWriteExtra = SincWidth*2-1;
                    memcpy(bufferOut.ptr+BufferSize, bufferOut.ptr, ccWriteExtra*bufferOut[0].sizeof);
                    doBlam(&ccoutbuf, ccoutbuf+ccWriteSize+ccWriteExtra);
                    memcpy(bufferOut.ptr, bufferOut.ptr+BufferSize, ccWriteExtra*bufferOut[0].sizeof);
                    if (ccoutbuf == outbuf) return;
                    break;
                case Quality.Cubic:
                    doCubic(&ccoutbuf, ccoutbuf+ccWriteSize);
                    break;
                case Quality.Sinc:
                    doSinc(&ccoutbuf, ccoutbuf+ccWriteSize);
                    break;
                default: assert(0, "wtf?!");
            }
            readFilled += ccoutbuf-bufferOut.ptr-ccWritePos;
        }
    }

    void doFillAndRemoveDelay () {
        doFill();
        if (delayRemoved < 0) {
            int delay = outputDelay();
            delayRemoved = 0;
            while (delay--) removeSample(true);
        }
    }


}

private
{
    enum Shift = 10;
    enum ShiftExtra = 8;
    enum Resolution = 1<<Shift;
    enum ResolutionExtra = 1<<(Shift+ShiftExtra);
    enum SincWidth = 16;
    enum SincSamples = Resolution*SincWidth;
    enum CubicSamples = Resolution*4;
    enum BufferSize = SincWidth*4;
    enum float BlepCutoff = 0.90f;
    enum float BlamCutoff = 0.93f;
    enum float SincCutoff = 0.999f;

    int abs() (int n) 
    { 
        return (n < 0 ? -n : n); 
    }

    int fEqual() (const float b, const float a) 
    { 
        return (fast_fabs(a-b) < 1.0e-6f); 
    }

    float sinc() (float x) 
    { 
        return (fEqual(x, 0.0) ? 1.0 : sin(x*PI)/(x*PI)); 
    }
}

package:



// 16kb + 64kb + 64kb of tables
__gshared float[CubicSamples] cubicLut;
__gshared float[SincSamples+1] sincLut;
__gshared float[SincSamples+1] windowLut;
__gshared bool buildAudioResamplerTables_called = false;

static void buildAudioResamplerTables()
{
    if (buildAudioResamplerTables_called)
        return;

    double dx = cast(float)(SincWidth)/SincSamples, x = 0.0;
    for (uint i = 0; i < SincSamples+1; ++i, x += dx) 
    {
        float y = x/SincWidth;
        //float window = 0.42659-0.49656*cos(PI+PI*y)+0.076849*cos(2.0*PI*y); // Blackman
        float window = 0.40897+0.5*cos(PI*y)+0.09103*cos(2.0*PI*y); // Nuttal 3 term
        //float window = 0.79445*cos(0.5*PI*y)+0.20555*cos(1.5*PI*y); // C.R.Helmrich's 2 term window
        //float window = sinc(y); // Lanczos
        sincLut.ptr[i] = fast_fabs(x) < SincWidth ? sinc(x) : 0.0;
        windowLut.ptr[i] = window;
    }
    dx = 1.0/cast(float)(Resolution);
    x = 0.0;
    for (uint i = 0; i < Resolution; ++i, x += dx) 
    {
        cubicLut.ptr[i*4]   = cast(float)(-0.5*x*x*x+    x*x-0.5*x);
        cubicLut.ptr[i*4+1] = cast(float)( 1.5*x*x*x-2.5*x*x      +1.0);
        cubicLut.ptr[i*4+2] = cast(float)(-1.5*x*x*x+2.0*x*x+0.5*x);
        cubicLut.ptr[i*4+3] = cast(float)( 0.5*x*x*x-0.5*x*x);
    }

    buildAudioResamplerTables_called = true;
}
