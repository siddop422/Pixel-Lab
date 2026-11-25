namespace GameboySharp;

// Optional length-aware fast path for variable-sized audio blocks.
internal interface IAudioSinkWithCount
{
    void Submit(short[] left, short[] right, int frames);
}
