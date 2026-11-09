Set-StrictMode -Version Latest

function Start-GitHubWindowsJobProcess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal CLI execution requires the atomic job attachment and cannot be conditionally skipped.')]
    [CmdletBinding()]
    param([string] $FilePath, [string[]] $Arguments)

    if (-not ('DevSecOps.GitHub.WindowsJobProcess' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace DevSecOps.GitHub {
    public sealed class WindowsJobProcess : IDisposable {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct Startup {
            public int Size;
            public IntPtr Reserved, Desktop, Title;
            public uint X, Y, XSize, YSize, XCount, YCount, Fill, Flags;
            public ushort Show, ReservedSize;
            public IntPtr ReservedData, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct CreatedProcess {
            public IntPtr Process, Thread;
            public uint ProcessId, ThreadId;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedStartup {
            public Startup Startup;
            public IntPtr Attributes;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processAttributes,
            IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory,
            ref ExtendedStartup startup, out CreatedProcess process);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool InitializeProcThreadAttributeList(IntPtr attributes, int count, uint flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool UpdateProcThreadAttribute(IntPtr attributes, uint flags, IntPtr attribute,
            IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")]
        static extern void DeleteProcThreadAttributeList(IntPtr attributes);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(SafeProcessHandle process, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint code);

        SafeProcessHandle process;
        public Stream StandardOutput { get; private set; }
        public Stream StandardError { get; private set; }
        public int ExitCode {
            get {
                uint code;
                if (!GetExitCodeProcess(process, out code)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return unchecked((int)code);
            }
        }
        public void WaitForExit() {
            if (WaitForSingleObject(process, uint.MaxValue) != 0)
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        public void Dispose() {
            StandardOutput.Dispose();
            StandardError.Dispose();
            process.Dispose();
        }
        static string Quote(string value) {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value) {
                if (character == '\\') { slashes++; continue; }
                result.Append('\\', character == '"' ? slashes * 2 + 1 : slashes);
                result.Append(character);
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }
        public static WindowsJobProcess Start(string file, string[] arguments, SafeWaitHandle job) {
            AnonymousPipeServerStream output = null, error = null;
            try {
                output = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
                error = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
                using (var input = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable)) {
                    var startup = new ExtendedStartup();
                    startup.Startup = new Startup {
                        Size = Marshal.SizeOf<ExtendedStartup>(), Flags = 0x100,
                        Input = input.ClientSafePipeHandle.DangerousGetHandle(),
                        Output = output.ClientSafePipeHandle.DangerousGetHandle(),
                        Error = error.ClientSafePipeHandle.DangerousGetHandle()
                    };
                    IntPtr size = IntPtr.Zero;
                    InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
                    IntPtr attributes = IntPtr.Zero, jobs = IntPtr.Zero, handles = IntPtr.Zero;
                    bool initialized = false;
                    SafeProcessHandle handle = null;
                    var command = new StringBuilder(Quote(file));
                    foreach (string argument in arguments) command.Append(' ').Append(Quote(argument));
                    try {
                        attributes = Marshal.AllocHGlobal(size);
                        jobs = Marshal.AllocHGlobal(IntPtr.Size);
                        handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
                        if (!InitializeProcThreadAttributeList(attributes, 2, 0, ref size))
                            throw new Win32Exception(Marshal.GetLastWin32Error());
                        initialized = true;
                        Marshal.WriteIntPtr(jobs, job.DangerousGetHandle());
                        if (!UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x2000D, jobs,
                                (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                            throw new Win32Exception(Marshal.GetLastWin32Error());
                        Marshal.WriteIntPtr(handles, 0, startup.Startup.Input);
                        Marshal.WriteIntPtr(handles, IntPtr.Size, startup.Startup.Output);
                        Marshal.WriteIntPtr(handles, IntPtr.Size * 2, startup.Startup.Error);
                        if (!UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x20002, handles,
                                (IntPtr)(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                            throw new Win32Exception(Marshal.GetLastWin32Error());
                        startup.Attributes = attributes;
                        CreatedProcess created;
                        // JOB_LIST binds the child atomically; there is no unowned suspended-process window.
                        if (!CreateProcessW(file, command, IntPtr.Zero, IntPtr.Zero, true, 0x08080000,
                                IntPtr.Zero, null, ref startup, out created))
                            throw new Win32Exception(Marshal.GetLastWin32Error());
                        handle = new SafeProcessHandle(created.Process, true);
                        using (var thread = new SafeWaitHandle(created.Thread, true)) {
                            output.DisposeLocalCopyOfClientHandle();
                            error.DisposeLocalCopyOfClientHandle();
                            input.DisposeLocalCopyOfClientHandle();
                            var result = new WindowsJobProcess { process = handle, StandardOutput = output, StandardError = error };
                            handle = null;
                            return result;
                        }
                    } finally {
                        if (handle != null) handle.Dispose();
                        if (initialized) DeleteProcThreadAttributeList(attributes);
                        Marshal.FreeHGlobal(attributes);
                        Marshal.FreeHGlobal(jobs);
                        Marshal.FreeHGlobal(handles);
                    }
                }
            } catch {
                if (output != null) output.Dispose();
                if (error != null) error.Dispose();
                throw;
            }
        }
    }
}
'@
    }
    return [DevSecOps.GitHub.WindowsJobProcess]::Start($FilePath, $Arguments, [DevSecOps.LocalCi.ProcessJob]::Lifetime)
}

Export-ModuleMember -Function Start-GitHubWindowsJobProcess
