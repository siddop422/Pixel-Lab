using PocketGB.Shared;
using Xunit;

namespace PocketGB.Shared.Tests;

public sealed class EmulationFramePacerTests
{
    private static int RunForOneSecond(double speed)
    {
        var pacer = new EmulationFramePacer();
        int total = 0;
        for (int i = 0; i < 60; i++)
            total += pacer.Consume(1.0 / 60.0, speed, 60.0);
        return total;
    }

    [Theory]
    [InlineData(0.5, 30)]
    [InlineData(1.0, 60)]
    [InlineData(2.0, 120)]
    [InlineData(4.0, 240)]
    [InlineData(8.0, 480)]
    [InlineData(16.0, 960)]
    public void AdvancesTheRequestedNumberOfFramesOverOneSecond(double speed, int expected) =>
        Assert.Equal(expected, RunForOneSecond(speed));

    [Fact]
    public void PausingClearsFractionalFrameDebt()
    {
        var pacer = new EmulationFramePacer();
        Assert.Equal(0, pacer.Consume(0.5 / 60.0, 1.0, 60.0));
        Assert.Equal(0, pacer.Consume(1.0, 16.0, 60.0, paused: true));
        Assert.Equal(0, pacer.Consume(0.5 / 60.0, 1.0, 60.0));
        Assert.Equal(1, pacer.Consume(0.5 / 60.0, 1.0, 60.0));
    }

    [Fact]
    public void LongStallProducesOnlyOneBoundedBatch()
    {
        var pacer = new EmulationFramePacer(maxFramesPerBatch: 32, maxBacklogFrames: 32);
        Assert.Equal(32, pacer.Consume(5.0, 16.0, 60.0));
        Assert.Equal(1, pacer.Consume(1.0 / 60.0, 1.0, 60.0));
    }

    [Fact]
    public void RejectsInvalidBatchAndBacklogLimits()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new EmulationFramePacer(0, 32));
        Assert.Throws<ArgumentOutOfRangeException>(() => new EmulationFramePacer(8, 7));
    }
}
