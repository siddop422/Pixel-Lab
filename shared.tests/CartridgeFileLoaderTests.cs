using System.IO.Compression;
using PocketGB.Shared;
using Xunit;

namespace PocketGB.Shared.Tests;

public sealed class CartridgeFileLoaderTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "PocketGB-SharedRomTests", Guid.NewGuid().ToString("N"));
    private readonly string _cache;

    public CartridgeFileLoaderTests()
    {
        _cache = Path.Combine(_root, "cache");
        Directory.CreateDirectory(_root);
    }

    [Theory]
    [InlineData(".gb")]
    [InlineData(".gbc")]
    [InlineData(".sgb")]
    [InlineData(".gba")]
    [InlineData(".gbx")]
    [InlineData(".agb")]
    [InlineData(".dmg")]
    [InlineData(".cgb")]
    [InlineData(".bin")]
    [InlineData(".rom")]
    [InlineData(".pak")]
    [InlineData(".zip")]
    [InlineData(".7z")]
    public void RecognizesSupportedCartridgeAndArchiveExtensions(string extension)
    {
        Assert.True(CartridgeFileLoader.IsSupportedGameFileName("game" + extension));
    }

    [Fact]
    public void ResolvesDirectRomWithoutChangingItsPath()
    {
        string path = Path.Combine(_root, "homebrew.GBA");
        File.WriteAllBytes(path, new byte[] { 1, 2, 3, 4 });

        Assert.Equal(path, CartridgeFileLoader.ResolveRomPath(path, _cache));
    }

    [Fact]
    public void ResolvesZipRomAndPrefersRootThenAlphabeticalOrder()
    {
        string zip = CreateArchive(
            ("folder/nested.gba", new byte[] { 8, 8 }),
            ("zeta.gb", new byte[] { 9 }),
            ("alpha.gbc", new byte[] { 1, 2, 3 }),
            ("notes.txt", new byte[] { 0 }));

        string resolved = CartridgeFileLoader.ResolveRomPath(zip, _cache);

        Assert.EndsWith(".gbc", resolved, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(resolved));
    }

    [Fact]
    public void ResolvesNestedRomWhenNoRootRomExists()
    {
        string zip = CreateArchive(("games/title.sgb", new byte[] { 0x51, 0x52 }));

        string resolved = CartridgeFileLoader.ResolveRomPath(zip, _cache);

        Assert.EndsWith(".sgb", resolved, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(new byte[] { 0x51, 0x52 }, File.ReadAllBytes(resolved));
    }

    [Fact]
    public void CacheInvalidatesWhenArchiveBytesChange()
    {
        string zip = Path.Combine(_root, "replace.zip");
        WriteArchive(zip, ("game.gb", new byte[] { 1, 2, 3 }));
        string first = CartridgeFileLoader.ResolveRomPath(zip, _cache);

        WriteArchive(zip, ("game.gb", new byte[] { 4, 5, 6 }));
        string second = CartridgeFileLoader.ResolveRomPath(zip, _cache);

        Assert.NotEqual(first, second);
        Assert.Equal(new byte[] { 4, 5, 6 }, File.ReadAllBytes(second));
    }

    [Fact]
    public void RejectsCorruptZipWithoutStartingTheEmulator()
    {
        string path = Path.Combine(_root, "corrupt.zip");
        File.WriteAllBytes(path, new byte[] { 0x50, 0x4B, 0x03, 0x04, 0xFF, 0x00, 0x11 });

        Assert.Throws<InvalidDataException>(() => CartridgeFileLoader.ResolveRomPath(path, _cache));
    }

    [Fact]
    public void RejectsOversizedDirectCartridgeBeforeReadingItIntoMemory()
    {
        string path = Path.Combine(_root, "oversized.gba");
        using (var stream = File.Create(path))
            stream.SetLength(CartridgeFileLoader.MaxRomBytes + 1);

        Assert.Throws<InvalidDataException>(() => CartridgeFileLoader.ResolveRomPath(path, _cache));
    }

    [Fact]
    public void RejectsOversizedUncompressedRomEntryInsideSmallZip()
    {
        string path = Path.Combine(_root, "zip-bomb.zip");
        byte[] oversized = new byte[checked((int)CartridgeFileLoader.MaxRomBytes + 1)];
        using (var archive = ZipFile.Open(path, ZipArchiveMode.Create))
        using (Stream output = archive.CreateEntry("oversized.gba", CompressionLevel.Optimal).Open())
            output.Write(oversized, 0, oversized.Length);

        Assert.Throws<InvalidDataException>(() => CartridgeFileLoader.ResolveRomPath(path, _cache));
    }

    [Fact]
    public void RejectsZipWithoutCartridge()
    {
        string zip = CreateArchive(("readme.txt", new byte[] { 1 }));

        Assert.Throws<InvalidDataException>(() => CartridgeFileLoader.ResolveRomPath(zip, _cache));
    }

    [Fact]
    public void RejectsUnknownDirectExtension()
    {
        string path = Path.Combine(_root, "not-a-rom.txt");
        File.WriteAllBytes(path, new byte[] { 1 });

        Assert.Throws<InvalidDataException>(() => CartridgeFileLoader.ResolveRomPath(path, _cache));
    }

    [Fact]
    public void RejectsMissingFile()
    {
        Assert.Throws<FileNotFoundException>(() =>
            CartridgeFileLoader.ResolveRomPath(Path.Combine(_root, "missing.gba"), _cache));
    }

    [Fact]
    public void LeavesSevenZipForNativeMgbAArchiveReader()
    {
        string path = Path.Combine(_root, "collection.7z");
        File.WriteAllBytes(path, new byte[] { 1, 2, 3 });

        Assert.True(CartridgeFileLoader.IsSevenZipArchive(path));
        Assert.Equal(path, CartridgeFileLoader.ResolveRomPath(path, _cache));
    }

    [Fact]
    public void FindsSidecarPatchesInBpsUpsIpsPriorityOrder()
    {
        string rom = Path.Combine(_root, "game.gba");
        File.WriteAllBytes(rom, new byte[] { 1 });
        string ips = Path.ChangeExtension(rom, ".ips");
        string ups = Path.ChangeExtension(rom, ".ups");
        string bps = Path.ChangeExtension(rom, ".bps");
        File.WriteAllBytes(ips, new byte[] { 1 });
        File.WriteAllBytes(ups, new byte[] { 2 });
        File.WriteAllBytes(bps, new byte[] { 3 });

        Assert.Equal(bps, CartridgeFileLoader.FindSidecarPatch(rom));
        File.Delete(bps);
        Assert.Equal(ups, CartridgeFileLoader.FindSidecarPatch(rom));
        File.Delete(ups);
        Assert.Equal(ips, CartridgeFileLoader.FindSidecarPatch(rom));
    }

    [Fact]
    public void FindsSidecarPatchBesideOriginalZip()
    {
        string zip = Path.Combine(_root, "game-collection.zip");
        File.WriteAllBytes(zip, new byte[] { 1 });
        string patch = Path.ChangeExtension(zip, ".bps");
        File.WriteAllBytes(patch, new byte[] { 1, 2 });

        Assert.Equal(patch, CartridgeFileLoader.FindSidecarPatch(zip));
    }

    private string CreateArchive(params (string Name, byte[] Data)[] entries)
    {
        string path = Path.Combine(_root, "test-" + Guid.NewGuid().ToString("N") + ".zip");
        WriteArchive(path, entries);
        return path;
    }

    private static void WriteArchive(string path, params (string Name, byte[] Data)[] entries)
    {
        if (File.Exists(path)) File.Delete(path);
        using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var item in entries)
        {
            var entry = archive.CreateEntry(item.Name, CompressionLevel.Optimal);
            using var output = entry.Open();
            output.Write(item.Data);
        }
    }

    public void Dispose()
    {
        try { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
        catch { /* Do not mask a test failure during cleanup. */ }
    }
}
