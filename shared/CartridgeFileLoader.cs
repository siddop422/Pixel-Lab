using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;

namespace PocketGB.Shared;

/// <summary>
/// Resolves supported Game Boy-family cartridge files for every PocketGB frontend.
/// It deliberately does not guess from a filename alone: the native mGBA core validates
/// the actual cartridge header when the resolved bytes are loaded.
/// </summary>
public static class CartridgeFileLoader
{
    public const long MaxRomBytes = 32L * 1024L * 1024L;

    private static readonly string[] RomExtensions =
    {
        ".gb", ".gbc", ".sgb", ".gba", ".gbx",
        ".agb", ".dmg", ".cgb", ".bin", ".rom"
    };

    private static readonly string[] PatchExtensions = { ".bps", ".ups", ".ips" };

    public static bool IsSupportedRomExtension(string? extension)
    {
        if (string.IsNullOrWhiteSpace(extension)) return false;
        return RomExtensions.Contains(extension.StartsWith(".", StringComparison.Ordinal)
            ? extension : "." + extension, StringComparer.OrdinalIgnoreCase);
    }

    public static bool IsSupportedGameFileName(string? fileName)
    {
        if (string.IsNullOrWhiteSpace(fileName)) return false;
        string extension = Path.GetExtension(fileName);
        return extension.Equals(".zip", StringComparison.OrdinalIgnoreCase) ||
               IsSupportedRomExtension(extension);
    }

    public static string[] GetSupportedExtensions() =>
        RomExtensions.Concat(new[] { ".zip" }).ToArray();

    /// <summary>
    /// Returns a direct cartridge path unchanged, or extracts one ROM from a ZIP into a
    /// content-addressed cache. ZIP entries are bounded by both advertised and actual size.
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
        if (!extension.Equals(".zip", StringComparison.OrdinalIgnoreCase))
        {
            if (!IsSupportedRomExtension(extension))
            {
                throw new InvalidDataException(
                    "Supported files: GB, GBC, SGB, GBA, GBX and raw ROM aliases (.agb, .dmg, .cgb, .bin, .rom), or a ZIP containing one.");
            }

            long directSize = new FileInfo(fullPath).Length;
            if (directSize <= 0 || directSize > MaxRomBytes)
                throw new InvalidDataException($"Cartridge images must be between 1 byte and {MaxRomBytes / (1024 * 1024)} MiB.");
            return fullPath;
        }

        using ZipArchive archive = ZipFile.OpenRead(fullPath);
        var candidates = archive.Entries
            .Where(entry => !string.IsNullOrEmpty(entry.Name))
            .Where(entry => IsSupportedRomExtension(Path.GetExtension(entry.Name)))
            .Where(entry => entry.Length > 0 && entry.Length <= MaxRomBytes)
            .OrderBy(entry => entry.FullName.Count(ch => ch == '/' || ch == '\\'))
            .ThenBy(entry => entry.FullName, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (candidates.Count == 0)
            throw new InvalidDataException("This ZIP contains no supported GB, GBC, SGB, GBA or GBX cartridge image under 32 MiB.");

        // Prefer root-level entries and use a stable ordinal order if the archive has multiple ROMs.
        ZipArchiveEntry selected = candidates[0];
        string archiveHash;
        using (FileStream input = File.OpenRead(fullPath))
            archiveHash = Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant();

        string cacheFolder = Path.Combine(Path.GetFullPath(cacheDirectory), archiveHash);
        string safeName = Path.GetFileName(selected.FullName.Replace('\\', '/'));
        if (string.IsNullOrWhiteSpace(safeName))
            safeName = "cartridge.gb";
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
            using var output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None);
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
        finally
        {
            if (File.Exists(temporary))
                File.Delete(temporary);
        }

        File.Move(temporary, destination, true);
        return destination;
    }

    /// <summary>
    /// Finds a matching sidecar patch. mGBA supports IPS, UPS and BPS; BPS is preferred
    /// when more than one patch is present, matching mGBA's own patch search order.
    /// </summary>
    public static string? FindSidecarPatch(params string?[] romPaths)
    {
        foreach (string extension in PatchExtensions)
        {
            foreach (string? path in romPaths)
            {
                if (string.IsNullOrWhiteSpace(path)) continue;
                string candidate = Path.ChangeExtension(Path.GetFullPath(path), extension);
                if (File.Exists(candidate))
                    return candidate;
            }
        }
        return null;
    }
}
