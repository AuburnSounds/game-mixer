import std.stdio;
import std.math;

import turtle;
import gamemixer;

int main(string[] args)
{
    runGame(new DrumMachineExample);
    return 0;
}

enum int NUM_SOUNDS = 6;

enum Sounds
{
    kick,
    hiHat,
    openHat,
    snare,
    cowbell,
    wood
}

static immutable string[NUM_SOUNDS] paths = 
    ["kick.wav", "hihat.wav", "openhat.wav", "snare.wav", "cowbell.wav", "wood.wav"];


class DrumMachineExample : TurtleGame
{
    override void load()
    {
        // Having a clear color with an alpha value different from 255 
        // will result in a cheap motion blur.
        setBackgroundColor( color("#202020") );

        _mixer = mixerCreate();
        foreach(n; 0..NUM_SOUNDS)
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

    override void draw()
    {
        
    }

private:
    IMixer _mixer;
    IAudioSource[6] _samples;
}

