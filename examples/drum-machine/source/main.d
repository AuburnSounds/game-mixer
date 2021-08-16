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


class DrumMachineExample : TurtleGame
{
    
    override void load()
    {
        // Having a clear color with an alpha value different from 255 
        // will result in a cheap motion blur.
        setBackgroundColor( color("#202020") );

        _mixer = mixerCreate();
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

        // TODO play sounds here
    }

    override void resized(float width, float height)
    {
        float W = windowWidth() * 0.9f; // some margin
        float H = windowHeight() * 0.9f;
        float padW = W / numStepsInLoop;
        float padH = H / numTracks;
        _padSize = padW < padH ? padW : padH;
    }

    override void mousePressed(float x, float y, MouseButton button, int repeat)
    {
        float W = windowWidth();
        float H = windowHeight();
        int step  = cast(int)( (x - (W / 2)) / _padSize + numStepsInLoop*0.5f);
        int track = cast(int)( (y - (H / 2)) / _padSize + numTracks     *0.5f);

        if (step < 0 || track < 0 || step >= numStepsInLoop || track >= numTracks)
            return;

        _steps[track][step] = !_steps[track][step];
    }

    override void draw()
    {
        float W = windowWidth();
        float H = windowHeight();

        float PAD_SIZE = 16; // TODO: adapt when window resize

        // draw pads
        for (int track = 0; track < numTracks; ++track)
        {
            for (int step = 0; step < numStepsInLoop; ++step)
            {
                float posx = W / 2 + (-numStepsInLoop*0.5f + step) * _padSize;
                float posy = H / 2 + (-numTracks*0.5f + track) * _padSize;

                if (_steps[track][step])
                    canvas.fillStyle = "white";
                else
                    canvas.fillStyle = "grey";
                canvas.fillRect(posx, posy, _padSize * 0.9f, _padSize * 0.9f);

            }
        }        
    }

private:
    IMixer _mixer;
    IAudioSource[numTracks] _samples;
    float _padSize;

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

