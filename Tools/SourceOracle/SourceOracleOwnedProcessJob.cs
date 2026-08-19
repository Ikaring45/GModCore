using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

/// <summary>
/// Starts one explicitly named executable inside a private Windows Job Object.
/// The process is created suspended, assigned to the job, and only then resumed,
/// so every descendant is covered by JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
/// </summary>
public sealed class SourceOracleOwnedProcessJob : IDisposable
{
    private const uint CreateSuspended = 0x00000004;
    private const uint StartfUseShowWindow = 0x00000001;
    private const ushort SwHide = 0;
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const int JobObjectBasicAccountingInformation = 1;
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint WaitObject0 = 0x00000000;
    private const uint WaitTimeout = 0x00000102;
    private const uint WaitFailed = 0xFFFFFFFF;
    private const uint StartupFailureExitCode = 0xE0450001;

    private readonly object sync = new object();
    private SafeKernelHandle jobHandle;
    private SafeKernelHandle rootProcessHandle;
    private bool disposed;

    private SourceOracleOwnedProcessJob(
        SafeKernelHandle jobHandle,
        SafeKernelHandle rootProcessHandle,
        int processId)
    {
        this.jobHandle = jobHandle;
        this.rootProcessHandle = rootProcessHandle;
        ProcessId = processId;
    }

    /// <summary>The ID of the directly created root, for diagnostics only.</summary>
    public int ProcessId { get; private set; }

    /// <summary>
    /// Creates a suspended process, assigns it to a new non-breakaway Job Object,
    /// and resumes its primary thread. The application and working directory must
    /// both be explicit absolute paths.
    /// </summary>
    public static SourceOracleOwnedProcessJob Start(
        string applicationPath,
        string[] arguments,
        string workingDirectory)
    {
        string executable = ValidateApplicationPath(applicationPath);
        string currentDirectory = ValidateWorkingDirectory(workingDirectory);
        string commandLine = BuildCommandLine(executable, arguments ?? new string[0]);

        SafeKernelHandle job = null;
        SafeKernelHandle process = null;
        SafeKernelHandle thread = null;
        bool processWasCreated = false;

        try
        {
            job = NativeMethods.CreateJobObject(IntPtr.Zero, null);
            if (job == null || job.IsInvalid)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateJobObjectW failed");
            }

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits =
                new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags =
                JobObjectLimitKillOnJobClose;

            if (!NativeMethods.SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                ref limits,
                (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "SetInformationJobObject(KILL_ON_JOB_CLOSE) failed");
            }

            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
            startup.dwFlags = StartfUseShowWindow;
            startup.wShowWindow = SwHide;
            PROCESS_INFORMATION processInformation;
            StringBuilder mutableCommandLine = new StringBuilder(commandLine);

            // No breakaway flag is used. Handle inheritance is also disabled.
            if (!NativeMethods.CreateProcess(
                executable,
                mutableCommandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                false,
                CreateSuspended,
                IntPtr.Zero,
                currentDirectory,
                ref startup,
                out processInformation))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateProcessW(CREATE_SUSPENDED) failed");
            }

            processWasCreated = true;
            process = new SafeKernelHandle(processInformation.hProcess, true);
            thread = new SafeKernelHandle(processInformation.hThread, true);

            if (!NativeMethods.AssignProcessToJobObject(job, process))
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(
                    error,
                    "AssignProcessToJobObject failed before the root was resumed");
            }

            uint previousSuspendCount = NativeMethods.ResumeThread(thread);
            if (previousSuspendCount == UInt32.MaxValue)
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "ResumeThread failed");
            }

            thread.Dispose();
            thread = null;

            SourceOracleOwnedProcessJob ownedProcess =
                new SourceOracleOwnedProcessJob(
                    job,
                    process,
                    checked((int)processInformation.dwProcessId));
            job = null;
            process = null;
            processWasCreated = false;
            return ownedProcess;
        }
        catch
        {
            // If CreateProcessW succeeded, cleanup is performed through the exact
            // hProcess returned by that call. There is intentionally no PID lookup
            // or process-name fallback, which also avoids PID-reuse races.
            if (processWasCreated && process != null && !process.IsInvalid)
            {
                NativeMethods.TerminateProcess(process, StartupFailureExitCode);
                NativeMethods.WaitForSingleObject(process, 5000);
            }

            if (thread != null)
            {
                thread.Dispose();
            }
            if (process != null)
            {
                process.Dispose();
            }
            if (job != null)
            {
                job.Dispose();
            }
            throw;
        }
    }

    /// <summary>True when the directly created root handle is signaled.</summary>
    public bool HasExited
    {
        get
        {
            lock (sync)
            {
                ThrowIfDisposed();
                uint result = NativeMethods.WaitForSingleObject(rootProcessHandle, 0);
                if (result == WaitObject0)
                {
                    return true;
                }
                if (result == WaitTimeout)
                {
                    return false;
                }
                if (result == WaitFailed)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "WaitForSingleObject(root process) failed");
                }
                throw new InvalidOperationException(
                    "WaitForSingleObject returned an unexpected status");
            }
        }
    }

    /// <summary>
    /// Exit code of the directly created root. As with System.Diagnostics.Process,
    /// reading it before exit is an error.
    /// </summary>
    public int ExitCode
    {
        get
        {
            lock (sync)
            {
                ThrowIfDisposed();
                uint wait = NativeMethods.WaitForSingleObject(rootProcessHandle, 0);
                if (wait == WaitTimeout)
                {
                    throw new InvalidOperationException(
                        "The root process has not exited");
                }
                if (wait == WaitFailed)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "WaitForSingleObject(root process) failed");
                }
                if (wait != WaitObject0)
                {
                    throw new InvalidOperationException(
                        "WaitForSingleObject returned an unexpected status");
                }

                uint code;
                if (!NativeMethods.GetExitCodeProcess(rootProcessHandle, out code))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "GetExitCodeProcess failed");
                }
                // Exit code 259 is conventionally STILL_ACTIVE, but it is also a
                // legal application exit code. The signaled process handle above
                // is the authoritative exited-state check.
                return unchecked((int)code);
            }
        }
    }

    /// <summary>Number of live processes currently assigned to this job.</summary>
    public uint ActiveProcessCount
    {
        get
        {
            lock (sync)
            {
                ThrowIfDisposed();
                return QueryActiveProcessCount();
            }
        }
    }

    /// <summary>
    /// Terminates the complete owned job and waits for both the retained root
    /// process handle and job accounting to report completion.
    /// </summary>
    public bool TerminateAndWait(int timeoutMilliseconds, uint exitCode)
    {
        if (timeoutMilliseconds < 0)
        {
            throw new ArgumentOutOfRangeException(
                "timeoutMilliseconds",
                "The timeout must be zero or greater");
        }

        lock (sync)
        {
            ThrowIfDisposed();

            if (!NativeMethods.TerminateJobObject(jobHandle, exitCode))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "TerminateJobObject failed");
            }

            Stopwatch timeout = Stopwatch.StartNew();
            uint wait = NativeMethods.WaitForSingleObject(
                rootProcessHandle,
                checked((uint)timeoutMilliseconds));
            if (wait == WaitTimeout)
            {
                return false;
            }
            if (wait == WaitFailed)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "WaitForSingleObject(root process) failed after job termination");
            }
            if (wait != WaitObject0)
            {
                throw new InvalidOperationException(
                    "WaitForSingleObject returned an unexpected status");
            }

            while (QueryActiveProcessCount() != 0)
            {
                if (timeout.ElapsedMilliseconds >= timeoutMilliseconds)
                {
                    return false;
                }
                Thread.Sleep(10);
            }
            return true;
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;

            // Closing the job first activates KILL_ON_JOB_CLOSE for any process
            // that remains. Closing the retained root handle cannot target a
            // recycled PID because no PID lookup is involved.
            if (jobHandle != null)
            {
                jobHandle.Dispose();
                jobHandle = null;
            }
            if (rootProcessHandle != null)
            {
                rootProcessHandle.Dispose();
                rootProcessHandle = null;
            }
        }
        GC.SuppressFinalize(this);
    }

    private uint QueryActiveProcessCount()
    {
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting;
        uint returnedLength;
        if (!NativeMethods.QueryInformationJobObject(
            jobHandle,
            JobObjectBasicAccountingInformation,
            out accounting,
            (uint)Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)),
            out returnedLength))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "QueryInformationJobObject(BasicAccountingInformation) failed");
        }
        return accounting.ActiveProcesses;
    }

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException("SourceOracleOwnedProcessJob");
        }
    }

    private static string ValidateApplicationPath(string applicationPath)
    {
        if (String.IsNullOrWhiteSpace(applicationPath))
        {
            throw new ArgumentException(
                "An explicit application path is required",
                "applicationPath");
        }
        if (applicationPath.IndexOf('\0') >= 0)
        {
            throw new ArgumentException(
                "The application path contains a NUL character",
                "applicationPath");
        }
        if (!Path.IsPathRooted(applicationPath))
        {
            throw new ArgumentException(
                "The application path must be absolute",
                "applicationPath");
        }

        string fullPath = Path.GetFullPath(applicationPath);
        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException(
                "The requested application does not exist",
                fullPath);
        }
        return fullPath;
    }

    private static string ValidateWorkingDirectory(string workingDirectory)
    {
        if (String.IsNullOrWhiteSpace(workingDirectory))
        {
            throw new ArgumentException(
                "An explicit working directory is required",
                "workingDirectory");
        }
        if (workingDirectory.IndexOf('\0') >= 0)
        {
            throw new ArgumentException(
                "The working directory contains a NUL character",
                "workingDirectory");
        }
        if (!Path.IsPathRooted(workingDirectory))
        {
            throw new ArgumentException(
                "The working directory must be absolute",
                "workingDirectory");
        }

        string fullPath = Path.GetFullPath(workingDirectory);
        if (!Directory.Exists(fullPath))
        {
            throw new DirectoryNotFoundException(
                "The requested working directory does not exist: " + fullPath);
        }
        return fullPath;
    }

    private static string BuildCommandLine(string applicationPath, string[] arguments)
    {
        StringBuilder commandLine = new StringBuilder();
        AppendQuotedArgument(commandLine, applicationPath);

        for (int i = 0; i < arguments.Length; i++)
        {
            string argument = arguments[i];
            if (argument == null)
            {
                throw new ArgumentException(
                    "Argument " + i + " is null",
                    "arguments");
            }
            if (argument.IndexOf('\0') >= 0)
            {
                throw new ArgumentException(
                    "Argument " + i + " contains a NUL character",
                    "arguments");
            }

            commandLine.Append(' ');
            AppendQuotedArgument(commandLine, argument);
        }
        return commandLine.ToString();
    }

    // Implements the CommandLineToArgvW/MSVCRT backslash-and-quote rules. Every
    // argument is quoted, including argv[0], so whitespace and empty arguments
    // are unambiguous and an embedded quote cannot introduce another argument.
    private static void AppendQuotedArgument(StringBuilder output, string value)
    {
        output.Append('"');
        int backslashes = 0;

        for (int i = 0; i < value.Length; i++)
        {
            char character = value[i];
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            if (character == '"')
            {
                output.Append('\\', (backslashes * 2) + 1);
                output.Append('"');
                backslashes = 0;
                continue;
            }

            if (backslashes != 0)
            {
                output.Append('\\', backslashes);
                backslashes = 0;
            }
            output.Append(character);
        }

        // Backslashes immediately before the closing quote must be doubled.
        if (backslashes != 0)
        {
            output.Append('\\', backslashes * 2);
        }
        output.Append('"');
    }

    private sealed class SafeKernelHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeKernelHandle()
            : base(true)
        {
        }

        public SafeKernelHandle(IntPtr handle, bool ownsHandle)
            : base(ownsHandle)
        {
            SetHandle(handle);
        }

        protected override bool ReleaseHandle()
        {
            return NativeMethods.CloseHandle(handle);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFO
    {
        public uint cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
    {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
    }

    private static class NativeMethods
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeKernelHandle CreateJobObject(
            IntPtr jobAttributes,
            string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetInformationJobObject(
            SafeKernelHandle job,
            int informationClass,
            ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION information,
            uint informationLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateProcess(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref STARTUPINFO startupInfo,
            out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AssignProcessToJobObject(
            SafeKernelHandle job,
            SafeKernelHandle process);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint ResumeThread(SafeKernelHandle thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateProcess(
            SafeKernelHandle process,
            uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateJobObject(
            SafeKernelHandle job,
            uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint WaitForSingleObject(
            SafeKernelHandle handle,
            uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetExitCodeProcess(
            SafeKernelHandle process,
            out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool QueryInformationJobObject(
            SafeKernelHandle job,
            int informationClass,
            out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION information,
            uint informationLength,
            out uint returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);
    }
}
