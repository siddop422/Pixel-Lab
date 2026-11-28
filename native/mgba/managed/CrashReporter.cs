using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

namespace GameboySharp;

/// <summary>Writes portable, copyable diagnostics without including cartridge bytes.</summary>
internal static class CrashReporter
{
    private static readonly object FileLock = new();

    public static string LogDirectory
    {
        get
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(local)) local = Path.GetTempPath();
            return Path.Combine(local, "PocketGB", "logs");
        }
    }

    public static string LastErrorPath => Path.Combine(LogDirectory, "last-error.txt");
    public static string NativeCrashPath => Path.Combine(LogDirectory, "native-crash.txt");

    public static void Install()
    {
        try { Directory.CreateDirectory(LogDirectory); }
        catch { /* Diagnostics must never prevent the emulator from starting. */ }

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            string details = args.ExceptionObject?.ToString() ?? "Unknown unhandled exception.";
            WriteText("Unhandled process exception", details);
        };

        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            WriteText("Unobserved task exception", args.Exception.ToString());
            args.SetObserved();
        };
    }

    public static string WriteException(string operation, string? gamePath, Exception exception)
    {
        var report = new StringBuilder();
        report.AppendLine("PocketGB diagnostic report");
        report.AppendLine($"Time (UTC): {DateTime.UtcNow:O}");
        report.AppendLine($"Operation: {operation}");
        report.AppendLine($"Game file: {gamePath ?? "(not available)"}");
        report.AppendLine($"Application: {AppContext.BaseDirectory}");
        report.AppendLine($"OS: {RuntimeInformation.OSDescription}");
        report.AppendLine($"Process architecture: {RuntimeInformation.ProcessArchitecture}");
        report.AppendLine($"Runtime: {Environment.Version}");
        report.AppendLine();
        report.AppendLine(exception.ToString());
        WriteText(LastErrorPath, report.ToString());
        return $"{operation} failed: {exception.Message}\nDiagnostic report: {LastErrorPath}";
    }

    private static void WriteText(string heading, string details) =>
        WriteText(LastErrorPath, $"PocketGB diagnostic report\r\nTime (UTC): {DateTime.UtcNow:O}\r\n{heading}\r\n\r\n{details}");

    private static void WriteText(string path, string contents)
    {
        try
        {
            Directory.CreateDirectory(LogDirectory);
            lock (FileLock) File.WriteAllText(path, contents, new UTF8Encoding(false));
        }
        catch { /* A crash reporter must never throw into the emulation loop. */ }
    }

    public static string BuildClipboardText(string visibleMessage)
    {
        var text = new StringBuilder();
        text.AppendLine("PocketGB error");
        text.AppendLine(visibleMessage);
        AppendTail(text, LastErrorPath);
        AppendTail(text, NativeCrashPath);
        text.AppendLine();
        text.AppendLine($"Diagnostic folder: {LogDirectory}");
        return text.ToString();
    }

    private static void AppendTail(StringBuilder destination, string path)
    {
        try
        {
            if (!File.Exists(path)) return;
            string contents = File.ReadAllText(path);
            if (contents.Length > 30000) contents = contents[^30000..];
            destination.AppendLine();
            destination.AppendLine($"--- {Path.GetFileName(path)} ---");
            destination.AppendLine(contents);
        }
        catch (Exception ex)
        {
            destination.AppendLine($"Could not read {path}: {ex.Message}");
        }
    }
}
