using Android.App;
using Android.Content;
using Android.Content.PM;
using Android.Database;
using Android.OS;
using Android.Provider;
using Android.Views;
using Android.Widget;
using System.IO;
using System.Security.Cryptography;
using PocketGB.Shared;

namespace PocketGB.Android;

[Activity(
    Label = "PocketGB",
    MainLauncher = true,
    Theme = "@android:style/Theme.Material.NoActionBar",
    ScreenOrientation = ScreenOrientation.SensorLandscape,
    ConfigurationChanges = ConfigChanges.Orientation | ConfigChanges.ScreenSize | ConfigChanges.KeyboardHidden,
    Exported = true)]
public sealed class MainActivity : Activity
{
    private const int OpenRomRequest = 4101;
    private const long MaxRomBytes = 32L * 1024L * 1024L;
    private const long MaxArchiveBytes = CartridgeFileLoader.MaxArchiveBytes;
    private EmulatorSurfaceView? _game;
    private Button? _pauseButton;
    private Button? _speedButton;
    private Button? _turboButton;

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        RequestedOrientation = ScreenOrientation.SensorLandscape;
        Window?.AddFlags(WindowManagerFlags.KeepScreenOn);
        Window?.SetFlags(WindowManagerFlags.Fullscreen, WindowManagerFlags.Fullscreen);
        HideSystemBars();

        var root = new FrameLayout(this);
        _game = new EmulatorSurfaceView(this, FilesDir?.AbsolutePath ?? CacheDir?.AbsolutePath ?? ".");
        root.AddView(_game, new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MatchParent, ViewGroup.LayoutParams.MatchParent));

        var toolbar = new LinearLayout(this)
        {
            Orientation = Orientation.Horizontal
        };
        toolbar.SetGravity(GravityFlags.CenterVertical);
        toolbar.SetPadding(Dp(4), Dp(2), Dp(4), Dp(2));
        toolbar.SetBackgroundColor(global::Android.Graphics.Color.Argb(210, 10, 26, 20));

        AddToolbarButton(toolbar, "OPEN", OpenRom);
        _pauseButton = AddToolbarButton(toolbar, "PAUSE", TogglePause);
        AddToolbarButton(toolbar, "RESET", () => _game?.Reset());
        _speedButton = AddToolbarButton(toolbar, "1x", CycleSpeed);
        _turboButton = AddToolbarButton(toolbar, "TURBO", ToggleTurbo);
        AddToolbarButton(toolbar, "SAVE", () => RunGameAction(() => _game?.SaveState()));
        AddToolbarButton(toolbar, "LOAD", () => RunGameAction(() => _game?.LoadState()));

        var toolbarParams = new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MatchParent, Dp(48), GravityFlags.Top);
        root.AddView(toolbar, toolbarParams);
        SetContentView(root);
    }

    private int Dp(float value) => (int)(value * Resources!.DisplayMetrics!.Density + 0.5f);

    private Button AddToolbarButton(LinearLayout parent, string text, Action action)
    {
        var button = new Button(this) { Text = text };
        button.SetTextSize(global::Android.Util.ComplexUnitType.Sp, 11f);
        button.SetPadding(Dp(2), 0, Dp(2), 0);
        button.SetAllCaps(false);
        button.Click += (_, _) => action();
        parent.AddView(button, new LinearLayout.LayoutParams(0, Dp(44), 1f));
        return button;
    }

    private void TogglePause()
    {
        if (_game == null) return;
        _game.TogglePause();
        if (_pauseButton != null) _pauseButton.Text = _game.IsPaused ? "PLAY" : "PAUSE";
    }

    private void CycleSpeed()
    {
        if (_game == null) return;
        _game.CycleSpeed();
        if (_speedButton != null) _speedButton.Text = $"{_game.SpeedMultiplier:0.##}x";
    }

    private void ToggleTurbo()
    {
        if (_game == null) return;
        _game.ToggleTurbo();
        if (_turboButton != null) _turboButton.Text = _game.TurboActive ? "TURBO ON" : "TURBO";
    }

    private void RunGameAction(Action action)
    {
        try { action(); }
        catch (Exception ex) { Toast.MakeText(this, ex.Message, ToastLength.Long)?.Show(); }
    }

    private void OpenRom()
    {
        var intent = new Intent(Intent.ActionOpenDocument);
        intent.AddCategory(Intent.CategoryOpenable);
        intent.SetType("*/*");
        try
        {
            StartActivityForResult(Intent.CreateChooser(intent, "Choose a GB, GBC, GBA or ZIP game"), OpenRomRequest);
        }
        catch (Exception ex)
        {
            Toast.MakeText(this, $"Could not open file picker: {ex.Message}", ToastLength.Long)?.Show();
        }
    }

    protected override void OnActivityResult(int requestCode, Result resultCode, Intent? data)
    {
        base.OnActivityResult(requestCode, resultCode, data);
        if (requestCode != OpenRomRequest || resultCode != Result.Ok || data?.Data == null) return;

        try
        {
            string displayName = GetDisplayName(data.Data) ?? $"game-{DateTime.UtcNow:yyyyMMdd-HHmmss}.rom";
            displayName = Path.GetFileName(displayName);
            string extension = Path.GetExtension(displayName).ToLowerInvariant();
            if (!CartridgeFileLoader.IsSupportedGameFileName(displayName))
                throw new InvalidDataException("Choose a GB, GBC, SGB, GBA, GBX, BIN, ROM, PAK, ZIP or 7z game file.");

            string destination = ImportDocument(data.Data, displayName, extension);
            _game?.LoadRom(destination);
            if (_pauseButton != null) _pauseButton.Text = "PAUSE";
            Toast.MakeText(this, $"Loaded {displayName}", ToastLength.Short)?.Show();
        }
        catch (Exception ex)
        {
            Toast.MakeText(this, ex.Message, ToastLength.Long)?.Show();
        }
    }

    private string ImportDocument(global::Android.Net.Uri uri, string displayName, string extension)
    {
        string romDirectory = Path.Combine(FilesDir!.AbsolutePath, "roms");
        Directory.CreateDirectory(romDirectory);
        string temporary = Path.Combine(romDirectory, $".import-{Guid.NewGuid():N}.tmp");
        long limit = extension is ".zip" or ".7z" or ".pak" ? MaxArchiveBytes : MaxRomBytes;

        try
        {
            using (Stream? input = ContentResolver!.OpenInputStream(uri))
            {
                if (input == null) throw new IOException("Android could not open that file.");
                using var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                byte[] buffer = new byte[81920];
                long copied = 0;
                int read;
                while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    copied += read;
                    if (copied > limit)
                        throw new InvalidDataException(extension is ".zip" or ".7z" or ".pak"
                            ? "ZIP/7z/PAK containers must be 128 MiB or smaller."
                            : "ROM files must be 32 MiB or smaller.");
                    output.Write(buffer, 0, read);
                }

                if (copied == 0) throw new InvalidDataException("The selected file is empty.");
                output.Flush(true);
            }

            string hash;
            using (var input = File.OpenRead(temporary))
            using (var sha = SHA256.Create())
                hash = Convert.ToHexString(sha.ComputeHash(input)).ToLowerInvariant();

            // Content-addressed names stop two different games with the same filename
            // from overwriting each other's .sav and .state0 files.
            string safeName = Path.GetFileName(displayName);
            string destination = Path.Combine(romDirectory, $"{hash[..16]}-{safeName}");
            File.Move(temporary, destination, true);
            return destination;
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private string? GetDisplayName(global::Android.Net.Uri uri)
    {
        ICursor? cursor = null;
        try
        {
            cursor = ContentResolver?.Query(uri, new[] { OpenableColumns.DisplayName }, null, null, null);
            if (cursor != null && cursor.MoveToFirst())
            {
                int column = cursor.GetColumnIndex(OpenableColumns.DisplayName);
                if (column >= 0) return cursor.GetString(column);
            }
        }
        catch { }
        finally { cursor?.Close(); }
        return uri.LastPathSegment;
    }

    private void HideSystemBars()
    {
        if (Build.VERSION.SdkInt >= BuildVersionCodes.R)
        {
            Window?.SetDecorFitsSystemWindows(false);
            Window?.InsetsController?.Hide(WindowInsets.Type.StatusBars() | WindowInsets.Type.NavigationBars());
            var controller = Window?.InsetsController;
            if (controller != null)
                controller.SystemBarsBehavior = (int)WindowInsetsControllerBehavior.ShowTransientBarsBySwipe;
        }
        else
        {
#pragma warning disable CS0618
            Window!.DecorView!.SystemUiVisibility = (StatusBarVisibility)(
                SystemUiFlags.Fullscreen | SystemUiFlags.HideNavigation |
                SystemUiFlags.ImmersiveSticky | SystemUiFlags.LayoutStable |
                SystemUiFlags.LayoutHideNavigation | SystemUiFlags.LayoutFullscreen);
#pragma warning restore CS0618
        }
    }

    protected override void OnResume()
    {
        base.OnResume();
        HideSystemBars();
        _game?.ResumeEmulation();
    }

    protected override void OnPause()
    {
        _game?.PauseEmulation();
        base.OnPause();
    }

    public override bool OnKeyDown(Keycode keyCode, KeyEvent? e)
    {
        if (_game?.SetHardwareKey(keyCode, true) == true) return true;
        return base.OnKeyDown(keyCode, e);
    }

    public override bool OnKeyUp(Keycode keyCode, KeyEvent? e)
    {
        if (_game?.SetHardwareKey(keyCode, false) == true) return true;
        return base.OnKeyUp(keyCode, e);
    }

    protected override void OnDestroy()
    {
        _game?.Dispose();
        _game = null;
        base.OnDestroy();
    }
}