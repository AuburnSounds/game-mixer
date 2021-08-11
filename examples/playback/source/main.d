import std.stdio;
import gamemixer;

void main()
{
    IMixer mixer = mixerCreate();
    
    // Wait until keypress
    writeln("Press ENTER to end the playback...");
    readln();
    mixerDestroy(mixer);
}