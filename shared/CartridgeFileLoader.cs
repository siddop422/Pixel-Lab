using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;

namespace PocketGB.Shared;

/// <summary>
/// Resolves Game Boy-family cartridges consistently for the desktop, portable and Android front ends.
/// ROM bytes are still validated by the native mGBA cartridge detector before a game starts.
/// </summary>
public static class CartridgeFileLoader
{
    public const long MaxRomBytes = 32L * 1024L * 1024L;
    public const long MaxArchiveBytes = 128L * 1024L * 1024L;

    private static readonly string[] RomExtensions =
    {
        ".gb", ".gbc", ".sgb", ".gba", ".gbx",
        ".agb", ".dmg", ".cgb", ".bin", ".rom", ".pak"
    };

    private static readonly string[] PatchExtensions = { ".bps", ".ups", ".ips" };

    public static bool IsSupportedRomExtension(string? extension)
    {
        if (string.IsNullOrWhiteSpace(extension)) return false;
        string normalized = extension.StartsWith(".", StringComparison.Ordinal) ? extension : "." + extension;
        return RomExtensions.Contains(normalized, StringComparer.OrdinalIgnoreCase);
    }

    public static bool IsSevenZipArchive(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        string extension = Path.GetExtension(path);
        if (extension.Equals(".7z", StringComparison.OrdinalIgnoreCase)) return true;
        return extension.Equals(".pak", StringComparison.OrdinalIgnoreCase) &&
               File.Exists(path) && HasSevenZipContainerSignature(path);
    }

    public static bool IsSupportedGameFileName(string? fileName)
    {
        if (string.IsNullOrWhiteSpace(fileName)) return false;
        string extension = Path.GetExtension(fileName);
        return extension.Equals(".zip", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".7z", StringComparison.OrdinalIgnoreCase) ||
               IsSupportedRomExtension(extension);
    }

    public static string[] GetSupportedExtensions() =>
        RomExtensions.Concat(new[] { ".zip", ".7z" }).ToArray();

    /// <summary>
    /// Some game libraries use .pak as a raw ROM dump, while others simply rename a ZIP
    /// container. Detect the latter by its PKZIP signature; otherwise mGBA validates it as raw ROM bytes.
    /// </summary>
    private static bool HasZipContainerSignature(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        Span<byte> header = stackalloc byte[4];
        int read = stream.Read(header);
        return read == 4 && header[0] == 0x50 && header[1] == 0x4B &&
               ((header[2] == 0x03 && header[3] == 0x04) ||
                (header[2] == 0x05 && header[3] == 0x06) ||
                (header[2] == 0x07 && header[3] == 0x08));
    }

    private static bool HasSevenZipContainerSignature(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        Span<byte> header = stackalloc byte[6];
        int read = stream.Read(header);
        return read == 6 &&
               header[0] == 0x37 && header[1] == 0x7A && header[2] == 0xBC &&
               header[3] == 0xAF && header[4] == 0x27 && header[5] == 0x1C;
    }

    /// <summary>
    /// Returns a direct ROM unchanged, extracts a ROM from ZIP into a content-addressed cache,
    /// or leaves a 7z archive for mGBA's built-in LZMA/VFS reader.
    /// </summary>
    public static string ResolveRomPath(string path, string cacheDirectory)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new ArgumentException("A game file path is required.", nameof(path));
        if (string.IsNullOrWhiteSpace(cacheDirectory))
            throw new ArgumentException("A ROM cache directory is required.", nameof(cacheDirectory));

        string fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath))
            throw new FileNotFoundException("The selected game file could not be found.", fullPath);

        string extension = Path.GetExtension(fullPath);
        if (extension.Equals(".7z", StringComparison.OrdinalIgnoreCase) ||
            (extension.Equals(".pak", StringComparison.OrdinalIgnoreCase) && HasSevenZipContainerSignature(fullPath)))
        {
            long archiveSize = new FileInfo(fullPath).Length;
            if (archiveSize <= 0 || archiveSize > MaxArchiveBytes)
                throw new InvalidDataException("7z archives must be between 1 byte and 128 MiB.");
            return fullPath;
        }

        bool zipContainer = extension.Equals(".zip", StringComparison.OrdinalIgnoreCase) ||
            (extension.Equals(".pak", StringComparison.OrdinalIgnoreCase) && HasZipContainerSignature(fullPath));

        if (!zipContainer)
        {
            if (!IsSupportedRomExtension(extension))
            {
                throw new InvalidDataException(
                    "Supported games: GB, GBC, SGB, GBA, GBX, BIN, ROM and PAK raw cartridge images, or ZIP/7z archives.");
            }

            long directSize = new FileInfo(fullPath).Length;
            if (directSize <= 0 || directSize > MaxRomBytes)
                throw new InvalidDataException("Cartridge images must be between 1 byte and 32 MiB.");
            return fullPath;
        }

        long zipSize = new FileInfo(fullPath).Length;
        if (zipSize <= 0 || zipSize > MaxArchiveBytes)
            throw new InvalidDataException("ZIP archives must be between 1 byte and 128 MiB.");

        using ZipArchive archive = ZipFile.OpenRead(fullPath);
        var candidates = archive.Entries
            .Where(entry => !string.IsNullOrEmpty(entry.Name))
            .Where(entry => IsSupportedRomExtension(Path.GetExtension(entry.Name)))
            .Where(entry => entry.Length > 0 && entry.Length <= MaxRomBytes)
            .OrderBy(entry => entry.FullName.Count(ch => ch == '/' || ch == (char)92))
            .ThenBy(entry => entry.FullName, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (candidates.Count == 0)
            throw new InvalidDataException("This ZIP contains no supported GB, GBC, SGB, GBA or GBX/PAK cartridge under 32 MiB.");

        ZipArchiveEntry selected = candidates[0];
        string archiveHash;
        using (FileStream input = File.OpenRead(fullPath))
            archiveHash = Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant();

        string cacheFolder = Path.Combine(Path.GetFullPath(cacheDirectory), archiveHash);
        string safeName = Path.GetFileName(selected.FullName.Replace((char)92, '/'));
        if (string.IsNullOrWhiteSpace(safeName)) safeName = "cartridge.gb";
        foreach (char invalid in Path.GetInvalidFileNameChars())
            safeName = safeName.Replace(invalid, '_');

        string destination = Path.Combine(cacheFolder, safeName);
        if (File.Exists(destination) && new FileInfo(destination).Length == selected.Length)
            return destination;

        Directory.CreateDirectory(cacheFolder);
        string temporary = destination + ".tmp";
        try
        {
            using Stream source = selected.Open();
            using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                byte[] buffer = new byte[81920];
                long copied = 0;
                int read;
                while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
                {
                    copied += read;
                    if (copied > MaxRomBytes)
                        throw new InvalidDataException("The ROM expands beyond the 32 MiB cartridge safety limit.");
                    output.Write(buffer, 0, read);
                }

                if (copied != selected.Length)
                    throw new InvalidDataException("The ROM entry in this ZIP is incomplete or corrupt.");
            }
        }
        catch
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            throw;
        }

        File.Move(temporary, destination, true);
        return destination;
    }

    /// <summary>Finds sidecar patches in mGBA's priority order: BPS, UPS, then IPS.</summary>
    public static string? FindSidecarPatch(params string?[] romPaths)
    {
        foreach (string extension in PatchExtensions)
        {
            foreach (string? path in romPaths)
            {
                if (string.IsNullOrWhiteSpace(path)) continue;
                string candidate = Path.ChangeExtension(Path.GetFullPath(path), extension);
                if (File.Exists(candidate))
                {
                    long size = new FileInfo(candidate).Length;
                    if (size <= 0 || size > MaxRomBytes)
                        throw new InvalidDataException($"The {extension} patch is empty or exceeds the 32 MiB safety limit.");
                    return candidate;
                }
            }
        }
        return null;
    }
}
