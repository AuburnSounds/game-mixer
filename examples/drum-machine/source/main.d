import std.stdio;
import std.math;
import turtle;
import gamemixer;

int main(string[] args)
{
    runGame(new DrumMachineExample);
    return 0;
}

enum int numTracks = 6;
enum int numStepsInLoop = 16;
enum double BPM = 120.0;

enum Sounds
{
    kick,
    hiHat,
    openHat,
    snare,
    cowbell,
    wood
}

static immutable string[numTracks] paths = 
    ["kick.wav", "hihat.wav", "openhat.wav", "snare.wav", "cowbell.wav", "wood.wav"];

// Note: game-mixer is not really appropriate to make a drum-machine.
// Notes would need to be triggered in an audio thread callback not in graphics animation.
// Right now we are dependent on the animation callback being called.

// A simple drum machine example
class DrumMachineExample : TurtleGame
{   
    override void load()
    {
        // Having a clear color with an alpha value different from 255 
        // will result in a cheap motion blur.
        setBackgroundColor( color("#202020") );

        MixerOptions options;
        options.numChannels = 32;
        _mixer = mixerCreate(options);
        foreach(n; 0..numTracks)
            _samples[n] = _mixer.createSourceFromFile(paths[n]);
    }

    ~this()
    {
        mixerDestroy(_mixer);
    }

    override void update(double dt)
    {
        if (keyboard.isDown("escape")) exitGame;

        double playbackTimeSinceStart = _mixer.playbackTimeInSeconds();

        // Which step are we in?
        double fcurstep = BPM * (playbackTimeSinceStart / 60.0) * (numStepsInLoop / 4);
        if (fcurstep < 0)
            return;

        int curstep = cast(int)(fcurstep);
        double delayBeforePlay = (curstep + 1 - fcurstep) * (60.0 / (BPM * 4));

        curstep = curstep % numStepsInLoop;
        assert(curstep >= 0 && curstep < numStepsInLoop);

        if ((_oldStep != -1) && (_oldStep != curstep))
        {
            // A step was changed.
            // Schedule all notes that would happen at next step.
            int nextStep = (curstep + 1) % numStepsInLoop;

            for (int track = 0; track < numTracks; ++track)
            {
                if (_steps[track][nextStep])
                {                    
                    assert(delayBeforePlay >= 0);
                    PlayOptions options;
                    options.volume = 0.5f;
                    options.channel = anyMixerChannel;
                    options.delayBeforePlay = delayBeforePlay;
                    _mixer.play(_samples[track], options);
                }
            }
        }
        _oldStep = curstep;
    }

    override void resized(float width, float height)
    {
        float W = windowWidth() * 0.9f; // some margin
        float H = windowHeight() * 0.9f;
        float padW = W / numStepsInLoop;
        float padH = H / numTracks;
        _padSize = padW < padH ? padW : padH;
    }

    bool getStepAndTrack(float x, float y, out int step, out int track)
    {
        float W = windowWidth();
        float H = windowHeight();
        step  = cast(int) floor( (x - (W / 2)) / _padSize + numStepsInLoop*0.5f);
        track = cast(int) floor( (y - (H / 2)) / _padSize + numTracks     *0.5f);
        return !(step < 0 || track < 0 || step >= numStepsInLoop || track >= numTracks);
    }

    override void mousePressed(float x, float y, MouseButton button, int repeat)
    {
        int step, track;
        if (getStepAndTrack(x, y, step, track))
        {
            if (button == MouseButton.left)
                _steps[track][step] = !_steps[track][step];
            else if (button == MouseButton.right)
            {
                PlayOptions options;
                options.volume = 0.5f;
                options.channel = anyMixerChannel;
                options.delayBeforePlay = 0;
                _mixer.play(_samples[track], options);
            }
        }
    }

    override void draw()
    {
        float W = windowWidth();
        float H = windowHeight();

        float PAD_SIZE = 16; // TODO: adapt when window resize

        int mstep = -1;
        int mtrack = -1;
        getStepAndTrack(mouse.positionX, mouse.positionY, mstep, mtrack);

        // draw pads
        for (int track = 0; track < numTracks; ++track)
        {
            for (int step = 0; step < numStepsInLoop; ++step)
            {
                float posx = W / 2 + (-numStepsInLoop*0.5f + step) * _padSize;
                float posy = H / 2 + (-numTracks*0.5f + track) * _padSize;

                bool intense = _steps[track][step] != 0;
                bool yellow = step == _oldStep;

                RGBA color;
                if (intense)
                {
                    color = yellow ? RGBA(255, 255, 100, 255) : RGBA(200, 200, 200, 255);
                }
                else
                {
                    color = yellow ? RGBA(128, 128, 50, 255) : RGBA(100, 100, 100, 255);
                }

                if (track == mtrack && step == mstep)
                    color.b += 55;

                canvas.fillStyle = color;
                canvas.fillRect(posx + _padSize * 0.05f, posy + _padSize * 0.05f, 
                                _padSize * 0.9f, _padSize * 0.9f);
            }
        }        
    }

private:
    IMixer _mixer;
    IAudioSource[numTracks] _samples;
    float _padSize;

    int _oldStep = -1;

    int[numStepsInLoop][numTracks] _steps =
    [
        [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 ],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ],
    ];
}

