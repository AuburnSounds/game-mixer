# game-mixer

A simple-to-use library for emitting sounds in your game.
It was thought of as a replacement of SDL2_mixer.

## Features

- ✅ MP3 / OGG / WAV / FLAC / XM / MOD playback
- ✅ Threaded decoding with progressive buffering. Unlimited channels, decoded streams are reused
- ✅ Looping, fade-in/fade-out, delayed triggering, synchronized triggering
- ✅ Playback volume, channel volume, master volume
- ✅ Integrated resampling
- ✅ Loopback: you can get mixer output in pull-mode instead of using audio I/O
- ✅ `nothrow @nogc`
- ✅ Based upon `libsoundio-d`: https://code.dlang.org/packages/libsoundio-d



## Changelog

### 🔔 `game-mixer` v1
- Initial release.
  

### How to use it?

- Add `game-mixer` as dependency to your `dub.json` or `dub.sdl`.
- See the [drum machine example](https://github.com/AuburnSounds/game-mixer/tree/main/examples/drum-machine) for usage.


---

## Usage tutorial

### The Mixer object
All `game-mixer` ressources and features are accessible through `IMixer`.

```d
interface IMixer
{
    // Create audio sources.
    IAudioSource createSourceFromMemory(const(ubyte[]) inputData);
    IAudioSource createSourceFromFile(const(char[]) path);

    // Play audio.
    void play(IAudioSource source, PlayOptions options);
    void play(IAudioSource source, float volume = 1.0f);
    void playSimultaneously(IAudioSource[] sources, PlayOptions[] options);

    /// Stop sounds.
    void stopChannel(int channel, float fadeOutSecs = 0.040f);
    void stopAllChannels(float fadeOutSecs = 0.040f);

    /// Set channel and master volume.
    void setChannelVolume(int channel, float volume);
    void setMasterVolume(float volume);

    /// Adds an effect on the master bus.
    void addMasterEffect(IAudioEffect effect);

    /// Create a custom effect.
    IAudioEffect createEffectCustom(EffectCallbackFunction callback, void* userData = null);
    
    // Mixer status.
    double playbackTimeInSeconds();
    float getSampleRate();
    bool isErrored();
    const(char)[] lastErrorString();

    /// Manual output ("loopback")
    void loopbackGenerate(float*[2] outBuffers, int frames);
    void loopbackMix(float*[2] inoutBuffers, int frames); ///ditto
}


```


### Create and Destroy a Mixer object

- To have an `IMixer`, create it with `mixerCreate`

  ```d
  MixerOptions options;
  IMixer mixer = mixerCreate(options);
  ```
- The `MixerOptions` can be customized:
  ```d
  struct MixerOptions
  {
      /// Desired output sample rate.
      float sampleRate = 48000.0f;

      /// Number of possible sounds to play simultaneously.
      int numChannels = 16; 

      /// The fade time it takes for one playing channel to change 
      /// its volume with `setChannelVolume`. 
      float channelVolumeSecs = 0.040f;
  }
  ```
  Mixers always have a stereo output and mixing engine stereo.


- Destroy it with `mixerDestroy`:

  ```d
  mixerDestroy(mixer);
  ```
This terminates the audio threaded playback and clean-up resources from this library.


### Load and play audio streams

  - Create audio sources with `IMixer.createSourceFromMemory` and `IMixer.createSourceFromFile`.

    ```d
    IAudioSource music = mixer.createSourceFromFile("8b-music.mod");
    mixer.play(music);
    ```

  - You can play an `IAudioSource` with custom `PlayOptions`:

    ```d
    IAudioSource music = mixer.createSourceFromFile("first_last.mod");
    PlayOptions options;
    options.pan = 0.2f;
    mixer.play(music, options);
    ````
    
    The following options exist:
    ```d
    struct PlayOptions
    {
        /// Force a specific playback channel
        int channel = anyMixerChannel;

        /// The volume to play the source with
        float volume = 1.0f;

        /// Stereo pan
        float pan = 0.0f;

        /// Play in x seconds (not compatible with startTimeSecs)
        float delayBeforePlay = 0.0f;

        /// Skip x seconds of source (not compatible with delayBeforePlay)
        float startTimeSecs = 0.0f;

        /// Looped source plays.
        uint loopCount = 1;

        /// Transition time on same channel, new sound
        float crossFadeInSecs = 0.000f;

         /// Transition time on same channel, old sound
        float crossFadeOutSecs = 0.040f;

        /// Transition time when channel was empty
        float fadeInSecs = 0.0f;
    }
    ``` 


### Loopback interface

You can reuse `game-mixer` in your own audio callback, for example in an audio plug-in situation.


Create an `Imixer` with `isLoopback` option. 
```d
MixerOptions options;
options.isLoopback = true;
IMixer mixer = mixerCreate(options);
```

Then generate mixer output in your own stereo buffers:
```d
float*[2] outBuffers = [ left.ptr, right.ptr ];
mixer.loopbackGenerate(outBuffers, N); // can only be called if isLoopback was passed
```

