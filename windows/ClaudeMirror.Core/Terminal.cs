using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Renci.SshNet;

namespace ClaudeMirror.Core;

/// <summary>A login shell on the server with a pseudo-terminal: bytes in both directions, as a terminal sees them.</summary>
public interface IRemoteTerminal : IDisposable
{
    Stream Output { get; }
    Stream Input { get; }
    void Resize(int columns, int rows);
}

public static class LoginShell
{
    private const string Script = "cd -- \"$1\" 2>/dev/null || cd; exec \"${SHELL:-/bin/sh}\" -l";

    /// <summary>The folder as a shell word; <c>~</c> stands for the home directory.</summary>
    public static string Folder(string directory) =>
        directory == "~" || directory.StartsWith("~/") ? "\"$HOME\"" + (directory.Length > 1 ? Protocol.Quote(directory[1..]) : "") : Protocol.Quote(directory);

    /// <summary>The remote command for <c>ssh -tt</c>. The login shell may be fish or csh, so the POSIX part runs under sh.</summary>
    public static string Command(string directory) => "sh -c " + Protocol.Quote(Script) + " sh " + Folder(directory);

    /// <summary>Typed into a shell the server has already started; it clears its own line and replaces that shell.</summary>
    public static string Typed(string directory) => " exec sh -c " + Protocol.Quote("clear; " + Script) + " sh " + Folder(directory) + "\n";
}

/// <summary>A shell channel on an SSH.NET connection. The library has no exec with a terminal, so the folder is typed in.</summary>
internal sealed class ShellTerminal : IRemoteTerminal
{
    private readonly ShellStream shell;
    public ShellTerminal(SshClient ssh, string directory, int columns, int rows)
    {
        shell = ssh.CreateShellStream("xterm-256color", (uint)columns, (uint)rows, 0, 0, 64 * 1024);
        shell.Write(LoginShell.Typed(directory)); shell.Flush();
    }
    public Stream Output => shell;
    public Stream Input => shell;
    public void Resize(int columns, int rows) => shell.ChangeWindowSize((uint)columns, (uint)rows, 0, 0);
    public void Dispose() => shell.Dispose();
}

/// <summary>
/// ssh.exe in a Windows pseudo console. OpenSSH sees a real console, so it asks the server for a terminal
/// and passes on every resize as it does in Windows Terminal.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class PseudoConsoleTerminal : IRemoteTerminal
{
    private readonly IntPtr console;
    private readonly SafeProcessHandle process;
    private readonly FileStream output, input;
    private int disposed;

    public PseudoConsoleTerminal(string executable, IEnumerable<string> arguments, int columns, int rows)
    {
        if (!CreatePipe(out var consoleIn, out var writeSide, IntPtr.Zero, 0) || !CreatePipe(out var readSide, out var consoleOut, IntPtr.Zero, 0))
            throw new Win32Exception();
        int created = CreatePseudoConsole(new Coord(columns, rows), consoleIn, consoleOut, 0, out console);
        consoleIn.Dispose(); consoleOut.Dispose();
        if (created != 0) { readSide.Dispose(); writeSide.Dispose(); throw new Win32Exception(created); }

        var size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        var attributes = Marshal.AllocHGlobal(size);
        try
        {
            if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size)
                || !UpdateProcThreadAttribute(attributes, 0, PseudoConsoleAttribute, console, IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception();
            // Without its own (empty) standard handles the child would inherit this process's and bypass the console.
            var startup = new StartupInfoEx { Size = Marshal.SizeOf<StartupInfoEx>(), Flags = UseStandardHandles, Attributes = attributes };
            var line = new StringBuilder(CommandLine(executable, arguments));
            if (!CreateProcessW(null, line, IntPtr.Zero, IntPtr.Zero, false, ExtendedStartupInfo, IntPtr.Zero, null, ref startup, out var info))
            {
                var error = Marshal.GetLastWin32Error();
                ClosePseudoConsole(console); readSide.Dispose(); writeSide.Dispose();
                throw error == 2 ? new SystemSshException(SystemSshFailure.Missing, "未安装 OpenSSH 客户端（设置 › 系统 › 可选功能）") : new Win32Exception(error);
            }
            CloseHandle(info.Thread);
            process = new SafeProcessHandle(info.Process, true);
        }
        finally { DeleteProcThreadAttributeList(attributes); Marshal.FreeHGlobal(attributes); }
        output = new FileStream(readSide, FileAccess.Read, 1);
        input = new FileStream(writeSide, FileAccess.Write, 1);
    }

    public Stream Output => output;
    public Stream Input => input;
    public void Resize(int columns, int rows) { if (Volatile.Read(ref disposed) == 0) ResizePseudoConsole(console, new Coord(columns, rows)); }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        input.Dispose();
        // Closing the console ends ssh.exe; it can wait for its last output to be read, so the reader keeps going until then.
        Task.Run(() => { ClosePseudoConsole(console); output.Dispose(); TerminateProcess(process, 1); process.Dispose(); });
    }

    /// <summary>Quotes each argument the way the C runtime splits a command line back into arguments.</summary>
    internal static string CommandLine(string executable, IEnumerable<string> arguments) =>
        string.Join(" ", new[] { executable }.Concat(arguments).Select(Argument));

    internal static string Argument(string value)
    {
        if (value.Length > 0 && value.IndexOfAny([' ', '\t', '"']) < 0) return value;
        var quoted = new StringBuilder("\"");
        int slashes = 0;
        foreach (var c in value)
        {
            if (c == '\\') { slashes++; continue; }
            quoted.Append('\\', c == '"' ? slashes * 2 + 1 : slashes).Append(c); slashes = 0;
        }
        return quoted.Append('\\', slashes * 2).Append('"').ToString();
    }

    // No CREATE_NO_WINDOW: it gives the child a hidden console of its own instead of the pseudo console.
    private const uint ExtendedStartupInfo = 0x00080000;
    private const int UseStandardHandles = 0x00000100;
    private static readonly IntPtr PseudoConsoleAttribute = 0x00020016;

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct Coord(int x, int y) { public readonly short X = (short)Math.Clamp(x, 1, short.MaxValue), Y = (short)Math.Clamp(y, 1, short.MaxValue); }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfoEx
    {
        public int Size; public string? Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public short ShowWindow, Reserved2; public IntPtr Reserved3, StdInput, StdOutput, StdError;
        public IntPtr Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation { public IntPtr Process, Thread; public int ProcessId, ThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attributes, int size);
    [DllImport("kernel32.dll")] private static extern int CreatePseudoConsole(Coord size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr console);
    [DllImport("kernel32.dll")] private static extern int ResizePseudoConsole(IntPtr console, Coord size);
    [DllImport("kernel32.dll")] private static extern void ClosePseudoConsole(IntPtr console);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returnSize);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(string? application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string? directory, ref StartupInfoEx startup, out ProcessInformation information);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern bool TerminateProcess(SafeProcessHandle process, uint code);
}
