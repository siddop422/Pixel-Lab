using System;

namespace PocketGB.Shared;

/// <summary>
/// Converts elapsed wall time into a bounded batch of emulated frames.
/// A bounded backlog prevents slow devices or debugger pauses from entering an endless catch-up loop.
/// </summary>
public sealed class EmulationFramePacer
{
    private readonly int _maxFramesPerBatch;
    private readonly int _maxBacklogFrames;
    private double _fractionalFrames;

    public EmulationFramePacer(int maxFramesPerBatch = 32, int maxBacklogFrames = 32)
    {
        if (maxFramesPerBatch < 1) throw new ArgumentOutOfRangeException(nameof(maxFramesPerBatch));
        if (maxBacklogFrames < maxFramesPerBatch)
            throw new ArgumentOutOfRangeException(nameof(maxBacklogFrames), "Backlog limit must be at least one full frame batch.");
        _maxFramesPerBatch = maxFramesPerBatch;
        _maxBacklogFrames = maxBacklogFrames;
    }

    public int Consume(double elapsedSeconds, double speedMultiplier, double frameRate, bool paused = false)
    {
        if (paused)
        {
            Reset();
            return 0;
        }

        if (!double.IsFinite(elapsedSeconds) || elapsedSeconds <= 0 ||
            !double.IsFinite(speedMultiplier) || speedMultiplier <= 0 ||
            !double.IsFinite(frameRate) || frameRate <= 0)
            return 0;

        // Ignore extreme stalls and cap outstanding work; do not freeze the UI trying to replay
        // seconds of missed frames on a low-power device.
        double elapsed = Math.Min(elapsedSeconds, 0.1);
        double speed = Math.Clamp(speedMultiplier, 0.1, 16.0);
        _fractionalFrames = Math.Min(_maxBacklogFrames,
            _fractionalFrames + elapsed * speed * frameRate);

        int frames = Math.Min(_maxFramesPerBatch, (int)Math.Floor(_fractionalFrames + 1e-9));
        _fractionalFrames -= frames;
        return frames;
    }

    public void Reset() => _fractionalFrames = 0;
}
