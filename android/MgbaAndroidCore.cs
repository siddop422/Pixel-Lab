using PocketGB.Shared;
using System.Runtime.InteropServices;
using System.Text;

namespace PocketGB.Android;

/// <summary>Small managed wrapper over PocketGB's pinned mGBA C ABI.</summary>
internal sealed class MgbaAndroidCore : IDisposable
{
    private const string NativeLibrary = "pocketgb-mgba";
    private IntPtr _context;
    private bool _disposed;
    private uint[] _rawPixels = Array.Empty<uint>();

    public bool HasRom { get; private set; }
    public string GameTitle { get; private set; } = "Open a ROM";
    public string PlatformName { get; private set; } = "mGBA";
    public int Width { get; private set; } = 160;
    public int Height { get; private set; } = 144;
    public double FrameRate { get; private set; } = 59.7275;
    public int AudioSampleRate => _context == IntPtr.Zero ? 48000 : pgb_mgba_audio_sample_rate(_context);

    public MgbaAndroidCore()
    {
        _context = pgb_mgba_create();
        if (_context == IntPtr.Zero)
            throw new InvalidOperationException("The PocketGB mGBA engine could not start. Reinstall the APK for this device architecture.");
    }

    public void LoadRom(string path)
    {
        ThrowIfDisposed();
        if (HasRom) SaveBattery(BatteryPath);
        HasRom = false;
        GameTitle = "Loading game...";

        string fullSourcePath = Path.GetFullPath(path);
        string cacheRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PocketGB", "rom-cache");
        if (string.IsNullOrWhiteSpace(cacheRoot) || cacheRoot == Path.DirectorySeparatorChar.ToString())
            cacheRoot = Path.Combine(Path.GetDirectoryName(fullSourcePath)!, "rom-cache");

        string resolved = CartridgeFileLoader.ResolveRomPath(fullSourcePath, cacheRoot);
        SetSavePaths(fullSourcePath);

        int result;
        if (CartridgeFileLoader.IsSevenZipArchive(resolved))
        {
            result = pgb_mgba_load_7z_file(_context, resolved);
        }
        else
        {
            byte[] rom = File.ReadAllBytes(resolved);
            if (rom.Length == 0 || rom.Length > CartridgeFileLoader.MaxRomBytes)
                throw new InvalidDataException("ROM size must be between 1 byte and 32 MiB.");
            result = pgb_mgba_load_rom(_context, rom, (nuint)rom.Length);
        }

        if (result == 0) throw new InvalidDataException(GetLastError());

        try
        {
            string? patchPath = CartridgeFileLoader.FindSidecarPatch(fullSourcePath, resolved);
            if (patchPath != null)
            {
                byte[] patch = File.ReadAllBytes(patchPath);
                if (pgb_mgba_apply_patch(_context, patch, (nuint)patch.Length) == 0)
                    global::Android.Util.Log.Warn("PocketGB", $"Could not apply sidecar patch {patchPath}: {GetLastError()}");
            }
        }
        catch (Exception ex)
        {
            global::Android.Util.Log.Warn("PocketGB", $"Could not apply sidecar patch: {ex.Message}");
        }

        Width = pgb_mgba_video_width(_context);
        Height = pgb_mgba_video_height(_context);
        EnsurePixels();
        GameTitle = GetText(pgb_mgba_game_title);
        int platform = pgb_mgba_platform(_context);
        PlatformName = platform == 0 ? "Game Boy Advance" : platform == 1 ? "Game Boy / Color" : "mGBA";
        double rate = pgb_mgba_frame_rate(_context);
        if (double.IsFinite(rate) && rate > 1 && rate < 240) FrameRate = rate;
        HasRom = true;
        LoadBatterySave();
    }

    public void RunFrame()
    {
        if (!HasRom) return;
        if (pgb_mgba_run_frame(_context) == 0) throw new InvalidOperationException(GetLastError());
        Width = pgb_mgba_video_width(_context);
        Height = pgb_mgba_video_height(_context);
        EnsurePixels();
    }

    public void SetKeys(uint keys)
    {
        if (_context != IntPtr.Zero && HasRom) pgb_mgba_set_keys(_context, keys);
    }

    public void Reset()
    {
        ThrowIfDisposed();
        if (!HasRom) return;
        pgb_mgba_reset(_context);
        Width = pgb_mgba_video_width(_context);
        Height = pgb_mgba_video_height(_context);
        EnsurePixels();
    }

    public void CopyPixelsArgb(int[] destination)
    {
        if (!HasRom || destination.Length < Width * Height) return;
        IntPtr pixels = pgb_mgba_video_pixels(_context);
        if (pixels == IntPtr.Zero) return;
        int count = Width * Height;
        if (_rawPixels.Length < count) _rawPixels = new uint[count];

        unsafe
        {
            fixed (uint* target = _rawPixels)
                Buffer.MemoryCopy(pixels.ToPointer(), target, (long)count * sizeof(uint), (long)count * sizeof(uint));
        }

        // mGBA uses native XBGR8 bytes (R,G,B,X on little-endian Android).
        // Android Bitmap.SetPixels expects packed ARGB, so swap red and blue here.
        for (int i = 0; i < count; i++)
        {
            uint px = _rawPixels[i];
            uint red = px & 0xFFu;
            uint green = (px >> 8) & 0xFFu;
            uint blue = (px >> 16) & 0xFFu;
            destination[i] = unchecked((int)(0xFF000000u | (red << 16) | (green << 8) | blue));
        }
    }

    public int AudioAvailable => _context == IntPtr.Zero ? 0 : Math.Clamp(pgb_mgba_audio_available(_context), 0, 16384);

    public int ReadAudio(short[] destination, int frames)
    {
        if (_context == IntPtr.Zero || frames <= 0) return 0;
        return pgb_mgba_audio_read(_context, destination, frames);
    }

    public void SaveState(string path)
    {
        ThrowIfDisposed();
        if (!HasRom) return;
        nuint size = pgb_mgba_state_size(_context);
        if (size == 0 || size > 64 * 1024 * 1024) throw new InvalidOperationException("Invalid mGBA save-state size.");
        byte[] bytes = new byte[(int)size];
        if (pgb_mgba_save_state(_context, bytes, size) == 0) throw new IOException("Could not save state.");
        WriteAtomic(path, bytes);
    }

    public bool LoadState(string path)
    {
        ThrowIfDisposed();
        if (!HasRom || !File.Exists(path)) return false;
        byte[] bytes = File.ReadAllBytes(path);
        if (pgb_mgba_load_state(_context, bytes, (nuint)bytes.Length) == 0) return false;
        Width = pgb_mgba_video_width(_context);
        Height = pgb_mgba_video_height(_context);
        EnsurePixels();
        return true;
    }

    public void SaveBattery(string path)
    {
        if (_context == IntPtr.Zero || !HasRom) return;
        nuint size = pgb_mgba_savedata_size(_context);
        if (size == 0 || size > 16 * 1024 * 1024) return;
        byte[] bytes = new byte[(int)size];
        if (pgb_mgba_savedata_copy(_context, bytes, size) != size)
            throw new IOException("Could not copy cartridge save data.");
        WriteAtomic(path, bytes);
    }

    private void LoadBatterySave()
    {
        string path = BatteryPath;
        if (!File.Exists(path)) return;
        try
        {
            byte[] bytes = File.ReadAllBytes(path);
            if (bytes.Length == 0 || bytes.Length > 16 * 1024 * 1024 ||
                pgb_mgba_savedata_load(_context, bytes, (nuint)bytes.Length) == 0)
            {
                string backup = path + ".corrupt-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmssfff");
                try
                {
                    File.Move(path, backup);
                    global::Android.Util.Log.Warn("PocketGB", $"Preserved an unreadable battery save at {backup}; starting with fresh save data.");
                }
                catch (Exception moveError)
                {
                    global::Android.Util.Log.Warn("PocketGB", $"Could not quarantine unreadable save {path}: {moveError.Message}");
                }
            }
        }
        catch (Exception ex)
        {
            global::Android.Util.Log.Warn("PocketGB", $"Could not load battery save {path}; starting fresh: {ex.Message}");
        }
    }

    public string BatteryPath { get; private set; } = string.Empty;
    public string StatePath { get; private set; } = string.Empty;

    public void SetSavePaths(string romPath)
    {
        BatteryPath = Path.ChangeExtension(romPath, ".sav");
        StatePath = Path.ChangeExtension(romPath, ".state0");
    }

    private static void WriteAtomic(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temp = path + ".tmp";
        File.WriteAllBytes(temp, bytes);
        File.Move(temp, path, true);
    }

    private void EnsurePixels()
    {
        if (Width <= 0 || Height <= 0 || Width > 256 || Height > 224)
            throw new InvalidDataException($"Unsupported mGBA screen size: {Width}x{Height}.");
        int needed = checked(Width * Height);
        if (_rawPixels.Length != needed) _rawPixels = new uint[needed];
    }

    private delegate void NativeTextGetter(IntPtr context, StringBuilder destination, nuint capacity);
    private string GetText(NativeTextGetter getter)
    {
        var value = new StringBuilder(64);
        getter(_context, value, (nuint)value.Capacity);
        return value.ToString().TrimEnd('\0', ' ');
    }

    private string GetLastError()
    {
        IntPtr error = pgb_mgba_last_error(_context);
        return error == IntPtr.Zero ? "mGBA rejected this ROM." : Marshal.PtrToStringUTF8(error) ?? "mGBA rejected this ROM.";
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(MgbaAndroidCore));
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_context != IntPtr.Zero)
        {
            pgb_mgba_destroy(_context);
            _context = IntPtr.Zero;
        }
    }

    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_load_7z_file(IntPtr context, [MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_apply_patch(IntPtr context, byte[] patch, nuint size);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr pgb_mgba_create();
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern void pgb_mgba_destroy(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr pgb_mgba_last_error(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_load_rom(IntPtr context, byte[] rom, nuint size);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_run_frame(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr pgb_mgba_video_pixels(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_video_width(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_video_height(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_platform(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern void pgb_mgba_game_title(IntPtr context, StringBuilder destination, nuint capacity);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern double pgb_mgba_frame_rate(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern void pgb_mgba_set_keys(IntPtr context, uint keys);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_audio_sample_rate(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_audio_available(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_audio_read(IntPtr context, short[] destination, int frames);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern nuint pgb_mgba_state_size(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_save_state(IntPtr context, byte[] destination, nuint capacity);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_load_state(IntPtr context, byte[] source, nuint size);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern nuint pgb_mgba_savedata_size(IntPtr context);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern nuint pgb_mgba_savedata_copy(IntPtr context, byte[] destination, nuint capacity);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern int pgb_mgba_savedata_load(IntPtr context, byte[] source, nuint size);
    [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)] private static extern void pgb_mgba_reset(IntPtr context);
}
