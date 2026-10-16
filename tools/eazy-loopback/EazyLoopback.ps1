# EazyLoopback audio monitor. Windows PowerShell 5.1 / PowerShell 7, Windows only.
# Run with: powershell.exe -ExecutionPolicy Bypass -File .\EazyLoopback.ps1
# Copyright (C) 2026 GoldesqueMoON
# SPDX-License-Identifier: Apache-2.0

param([switch]$GuiProcess)

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    throw 'This script requires Windows.'
}

if (-not $GuiProcess -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $quotedPath = '"' + $PSCommandPath + '"'
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $quotedPath, '-GuiProcess')
    return
}

$source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class EazyLoopbackMonitor : IDisposable
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WaveInCaps {
        public ushort wMid, wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public uint dwFormats;
        public ushort wChannels, wReserved1;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WaveOutCaps {
        public ushort wMid, wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public uint dwFormats;
        public ushort wChannels, wReserved1;
        public uint dwSupport;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct WaveFormat {
        public ushort wFormatTag, nChannels;
        public uint nSamplesPerSec, nAvgBytesPerSec;
        public ushort nBlockAlign, wBitsPerSample, cbSize;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct WaveHeader {
        public IntPtr lpData;
        public uint dwBufferLength, dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags, dwLoops;
        public IntPtr lpNext, reserved;
    }
    private sealed class Buffer {
        public IntPtr inputData, outputData, inputHeader, outputHeader;
        public short[] samples;
        public bool outputQueued;
    }
    [DllImport("winmm.dll")] private static extern uint waveInGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] private static extern uint waveInGetDevCaps(UIntPtr id, out WaveInCaps caps, uint size);
    [DllImport("winmm.dll")] private static extern uint waveOutGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] private static extern uint waveOutGetDevCaps(UIntPtr id, out WaveOutCaps caps, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInOpen(out IntPtr handle, uint id, ref WaveFormat format, IntPtr callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] private static extern uint waveOutOpen(out IntPtr handle, uint id, ref WaveFormat format, IntPtr callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] private static extern uint waveInPrepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveOutPrepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInUnprepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveOutUnprepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInAddBuffer(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveOutWrite(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInStart(IntPtr handle);
    [DllImport("winmm.dll")] private static extern uint waveInReset(IntPtr handle);
    [DllImport("winmm.dll")] private static extern uint waveOutReset(IntPtr handle);
    [DllImport("winmm.dll")] private static extern uint waveInClose(IntPtr handle);
    [DllImport("winmm.dll")] private static extern uint waveOutClose(IntPtr handle);
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] private static extern uint waveInGetErrorText(uint error, System.Text.StringBuilder text, uint size);
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] private static extern uint waveOutGetErrorText(uint error, System.Text.StringBuilder text, uint size);

    private const uint CallbackEvent = 0x00050000;
    private const uint HeaderDone = 0x00000001;
    private const int BufferCount = 6;
    private const int FramesPerBuffer = 512;
    private readonly List<Buffer> buffers = new List<Buffer>();
    private readonly AutoResetEvent inputEvent = new AutoResetEvent(false);
    private readonly AutoResetEvent outputEvent = new AutoResetEvent(false);
    private readonly ManualResetEvent stopEvent = new ManualResetEvent(false);
    private IntPtr input, output;
    private Thread worker;
    private int gainPercent = 100;
    private int running;
    private int inputLeftPeak, inputRightPeak, outputLeftPeak, outputRightPeak, clipCount;
    private string previewError;
    private string error;
    private int formatRate, formatChannels;

    public static string[] InputNames() {
        var result = new List<string>();
        for (uint i = 0; i < waveInGetNumDevs(); i++) {
            WaveInCaps caps;
            if (waveInGetDevCaps(new UIntPtr(i), out caps, (uint)Marshal.SizeOf(typeof(WaveInCaps))) == 0)
                result.Add(caps.szPname);
            else result.Add("Input " + i);
        }
        return result.ToArray();
    }
    public static string[] OutputNames() {
        var result = new List<string>();
        for (uint i = 0; i < waveOutGetNumDevs(); i++) {
            WaveOutCaps caps;
            if (waveOutGetDevCaps(new UIntPtr(i), out caps, (uint)Marshal.SizeOf(typeof(WaveOutCaps))) == 0)
                result.Add(caps.szPname);
            else result.Add("Output " + i);
        }
        return result.ToArray();
    }
    public int GainPercent { get { return Interlocked.CompareExchange(ref gainPercent, 0, 0); } set { Interlocked.Exchange(ref gainPercent, Math.Max(0, Math.Min(2000, value))); } }
    public bool IsRunning { get { return Interlocked.CompareExchange(ref running, 0, 0) != 0; } }
    public string Error { get { return error; } }
    public string FormatDescription { get { return formatRate + " Hz / " + formatChannels + " ch / 16 bit"; } }
    public int[] TakePeaks() {
        return new int[] {
            Interlocked.Exchange(ref inputLeftPeak, 0), Interlocked.Exchange(ref inputRightPeak, 0),
            Interlocked.Exchange(ref outputLeftPeak, 0), Interlocked.Exchange(ref outputRightPeak, 0),
            Interlocked.Exchange(ref clipCount, 0)
        };
    }
    public string TakePreviewError() { return Interlocked.Exchange(ref previewError, null); }
    private static void UpdateMax(ref int target, int value) {
        int old;
        while (value > (old = Interlocked.CompareExchange(ref target, 0, 0)) &&
               Interlocked.CompareExchange(ref target, value, old) != old) { }
    }
    public void PlayPreview(int outputId) {
        int gain = GainPercent;
        ThreadPool.QueueUserWorkItem(delegate(object unused) {
            try { PlayPreviewCore(outputId, gain); }
            catch (Exception ex) { Interlocked.Exchange(ref previewError, ex.Message); }
        });
    }
    private void PlayPreviewCore(int outputId, int gain) {
        if (outputId < -1 || outputId >= OutputNames().Length)
            throw new ArgumentException("Select an output device for preview.");
        IntPtr previewOutput = IntPtr.Zero, sampleData = IntPtr.Zero, headerPtr = IntPtr.Zero;
        bool prepared = false;
        uint headerSize = (uint)Marshal.SizeOf(typeof(WaveHeader));
        using (var done = new AutoResetEvent(false)) {
            try {
                int rate = 0;
                uint openResult = 0;
                foreach (int candidate in new int[] { 48000, 44100 }) {
                    WaveFormat format = MakeFormat(candidate, 2);
                    openResult = waveOutOpen(out previewOutput, outputId == -1 ? 0xFFFFFFFFu : (uint)outputId,
                        ref format, done.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, CallbackEvent);
                    if (openResult == 0) { rate = candidate; break; }
                    previewOutput = IntPtr.Zero;
                }
                if (previewOutput == IntPtr.Zero)
                    throw new InvalidOperationException("Preview output: " + ErrorText(openResult, false));
                int frames = rate / 5;
                var samples = new short[frames * 2];
                double amplitude = 0.09 * Math.Pow(gain / 100.0, 0.7);
                int peak = 0;
                for (int i = 0; i < frames; i++) {
                    double time = i / (double)rate;
                    double fadeIn = Math.Min(1.0, i / (rate * 0.008));
                    double fadeOut = Math.Min(1.0, (frames - i) / (rate * 0.06));
                    double frequency = i < frames / 2 ? 660.0 : 880.0;
                    int value = (int)Math.Round(32767.0 * amplitude * fadeIn * fadeOut * Math.Sin(2.0 * Math.PI * frequency * time));
                    short sample = (short)Math.Max(short.MinValue, Math.Min(short.MaxValue, value));
                    samples[i * 2] = sample;
                    samples[i * 2 + 1] = sample;
                    peak = Math.Max(peak, Math.Abs((int)sample));
                }
                sampleData = Marshal.AllocHGlobal(samples.Length * 2);
                headerPtr = Marshal.AllocHGlobal((int)headerSize);
                Marshal.Copy(samples, 0, sampleData, samples.Length);
                Marshal.StructureToPtr(new WaveHeader { lpData = sampleData, dwBufferLength = (uint)(samples.Length * 2) }, headerPtr, false);
                uint result = waveOutPrepareHeader(previewOutput, headerPtr, headerSize);
                if (result != 0) throw new InvalidOperationException("Preview prepare: " + ErrorText(result, false));
                prepared = true;
                result = waveOutWrite(previewOutput, headerPtr, headerSize);
                if (result != 0) throw new InvalidOperationException("Preview play: " + ErrorText(result, false));
                UpdateMax(ref outputLeftPeak, peak);
                UpdateMax(ref outputRightPeak, peak);
                DateTime deadline = DateTime.UtcNow.AddMilliseconds(1500);
                while ((((WaveHeader)Marshal.PtrToStructure(headerPtr, typeof(WaveHeader))).dwFlags & HeaderDone) == 0) {
                    int remaining = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
                    if (remaining <= 0 || !done.WaitOne(remaining))
                        throw new TimeoutException("Preview playback timed out.");
                }
            } finally {
                if (previewOutput != IntPtr.Zero) waveOutReset(previewOutput);
                if (prepared) waveOutUnprepareHeader(previewOutput, headerPtr, headerSize);
                if (headerPtr != IntPtr.Zero) Marshal.FreeHGlobal(headerPtr);
                if (sampleData != IntPtr.Zero) Marshal.FreeHGlobal(sampleData);
                if (previewOutput != IntPtr.Zero) waveOutClose(previewOutput);
            }
        }
    }

    private static string ErrorText(uint code, bool isInput) {
        var builder = new System.Text.StringBuilder(256);
        if (isInput) waveInGetErrorText(code, builder, (uint)builder.Capacity);
        else waveOutGetErrorText(code, builder, (uint)builder.Capacity);
        return builder.Length > 0 ? builder.ToString() + " (" + code + ")" : "winmm error " + code;
    }
    private static WaveFormat MakeFormat(int rate, int channels) {
        return new WaveFormat { wFormatTag = 1, nChannels = (ushort)channels,
            nSamplesPerSec = (uint)rate, nAvgBytesPerSec = (uint)(rate * channels * 2),
            nBlockAlign = (ushort)(channels * 2), wBitsPerSample = 16, cbSize = 0 };
    }
    public void Start(int inputId, int outputId) {
        if (IsRunning) return;
        if (inputId < -1 || inputId >= InputNames().Length) throw new ArgumentException("Select an input device.");
        if (outputId < -1 || outputId >= OutputNames().Length) throw new ArgumentException("Select an output device.");
        error = null;
        stopEvent.Reset();
        uint inputResult = 0, outputResult = 0;
        try {
            bool opened = false;
            foreach (int rate in new int[] { 48000, 44100, 32000 }) {
                foreach (int channels in new int[] { 2, 1 }) {
                    WaveFormat format = MakeFormat(rate, channels);
                    inputResult = waveInOpen(out input, inputId == -1 ? 0xFFFFFFFFu : (uint)inputId, ref format,
                        inputEvent.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, CallbackEvent);
                    if (inputResult != 0) { input = IntPtr.Zero; continue; }
                    outputResult = waveOutOpen(out output, outputId == -1 ? 0xFFFFFFFFu : (uint)outputId,
                        ref format, outputEvent.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, CallbackEvent);
                    if (outputResult == 0) { formatRate = rate; formatChannels = channels; opened = true; break; }
                    output = IntPtr.Zero;
                    waveInClose(input); input = IntPtr.Zero;
                }
                if (opened) break;
            }
            if (!opened) throw new InvalidOperationException("Could not open a common 16-bit PCM format. Input: " + ErrorText(inputResult, true) + "; output: " + ErrorText(outputResult, false));
            uint headerSize = (uint)Marshal.SizeOf(typeof(WaveHeader));
            int sampleCount = FramesPerBuffer * formatChannels;
            for (int i = 0; i < BufferCount; i++) {
                var b = new Buffer();
                b.samples = new short[sampleCount];
                b.inputData = Marshal.AllocHGlobal(sampleCount * 2);
                b.outputData = Marshal.AllocHGlobal(sampleCount * 2);
                b.inputHeader = Marshal.AllocHGlobal((int)headerSize);
                b.outputHeader = Marshal.AllocHGlobal((int)headerSize);
                buffers.Add(b);
                Marshal.StructureToPtr(new WaveHeader { lpData = b.inputData, dwBufferLength = (uint)(sampleCount * 2) }, b.inputHeader, false);
                Marshal.StructureToPtr(new WaveHeader { lpData = b.outputData, dwBufferLength = (uint)(sampleCount * 2) }, b.outputHeader, false);
                uint r = waveInPrepareHeader(input, b.inputHeader, headerSize);
                if (r != 0) throw new InvalidOperationException("Prepare input: " + ErrorText(r, true));
                r = waveOutPrepareHeader(output, b.outputHeader, headerSize);
                if (r != 0) throw new InvalidOperationException("Prepare output: " + ErrorText(r, false));
                r = waveInAddBuffer(input, b.inputHeader, headerSize);
                if (r != 0) throw new InvalidOperationException("Queue input: " + ErrorText(r, true));
            }
            worker = new Thread(Work) { IsBackground = true, Name = "EazyLoopback audio monitor" };
            Interlocked.Exchange(ref running, 1);
            worker.Start();
            uint startResult = waveInStart(input);
            if (startResult != 0) throw new InvalidOperationException("Start input: " + ErrorText(startResult, true));
        } catch {
            Stop();
            throw;
        }
    }
    private void Work() {
        uint headerSize = (uint)Marshal.SizeOf(typeof(WaveHeader));
        WaitHandle[] handles = { stopEvent, inputEvent, outputEvent };
        try {
            while (!stopEvent.WaitOne(0)) {
                WaitHandle.WaitAny(handles, 100);
                foreach (Buffer b in buffers) {
                    if (b.outputQueued) {
                        WaveHeader outHeader = (WaveHeader)Marshal.PtrToStructure(b.outputHeader, typeof(WaveHeader));
                        if ((outHeader.dwFlags & HeaderDone) != 0) {
                            b.outputQueued = false;
                            uint r = waveInAddBuffer(input, b.inputHeader, headerSize);
                            if (r != 0) throw new InvalidOperationException("Queue input: " + ErrorText(r, true));
                        }
                    } else {
                        WaveHeader inHeader = (WaveHeader)Marshal.PtrToStructure(b.inputHeader, typeof(WaveHeader));
                        if ((inHeader.dwFlags & HeaderDone) == 0) continue;
                        int count = (int)inHeader.dwBytesRecorded / 2;
                        if (count <= 0) {
                            uint r = waveInAddBuffer(input, b.inputHeader, headerSize);
                            if (r != 0) throw new InvalidOperationException("Queue input: " + ErrorText(r, true));
                            continue;
                        }
                        Marshal.Copy(b.inputData, b.samples, 0, count);
                        double gain = GainPercent / 100.0;
                        int inLeft = 0, inRight = 0, outLeft = 0, outRight = 0, clipped = 0;
                        for (int j = 0; j < count; j++) {
                            int channel = j % formatChannels;
                            int inputLevel = Math.Abs((int)b.samples[j]);
                            if (channel == 0) inLeft = Math.Max(inLeft, inputLevel);
                            else inRight = Math.Max(inRight, inputLevel);
                            int value = (int)Math.Round(b.samples[j] * gain);
                            if (value < short.MinValue || value > short.MaxValue) clipped++;
                            b.samples[j] = (short)Math.Max(short.MinValue, Math.Min(short.MaxValue, value));
                            int outputLevel = Math.Abs((int)b.samples[j]);
                            if (channel == 0) outLeft = Math.Max(outLeft, outputLevel);
                            else outRight = Math.Max(outRight, outputLevel);
                        }
                        if (formatChannels == 1) { inRight = inLeft; outRight = outLeft; }
                        UpdateMax(ref inputLeftPeak, inLeft);
                        UpdateMax(ref inputRightPeak, inRight);
                        UpdateMax(ref outputLeftPeak, outLeft);
                        UpdateMax(ref outputRightPeak, outRight);
                        if (clipped > 0) Interlocked.Add(ref clipCount, clipped);
                        Marshal.Copy(b.samples, 0, b.outputData, count);
                        WaveHeader outHeader = (WaveHeader)Marshal.PtrToStructure(b.outputHeader, typeof(WaveHeader));
                        outHeader.dwBufferLength = (uint)(count * 2);
                        Marshal.StructureToPtr(outHeader, b.outputHeader, false);
                        uint writeResult = waveOutWrite(output, b.outputHeader, headerSize);
                        if (writeResult != 0) throw new InvalidOperationException("Play audio: " + ErrorText(writeResult, false));
                        b.outputQueued = true;
                    }
                }
            }
        } catch (Exception ex) { error = ex.Message; Interlocked.Exchange(ref running, 0); }
    }
    public void Stop() {
        stopEvent.Set();
        if (worker != null && worker.IsAlive && Thread.CurrentThread != worker) worker.Join(1000);
        worker = null;
        if (input != IntPtr.Zero) waveInReset(input);
        if (output != IntPtr.Zero) waveOutReset(output);
        uint headerSize = (uint)Marshal.SizeOf(typeof(WaveHeader));
        foreach (Buffer b in buffers) {
            if (input != IntPtr.Zero && b.inputHeader != IntPtr.Zero) waveInUnprepareHeader(input, b.inputHeader, headerSize);
            if (output != IntPtr.Zero && b.outputHeader != IntPtr.Zero) waveOutUnprepareHeader(output, b.outputHeader, headerSize);
            if (b.inputData != IntPtr.Zero) Marshal.FreeHGlobal(b.inputData);
            if (b.outputData != IntPtr.Zero) Marshal.FreeHGlobal(b.outputData);
            if (b.inputHeader != IntPtr.Zero) Marshal.FreeHGlobal(b.inputHeader);
            if (b.outputHeader != IntPtr.Zero) Marshal.FreeHGlobal(b.outputHeader);
        }
        buffers.Clear();
        if (input != IntPtr.Zero) { waveInClose(input); input = IntPtr.Zero; }
        if (output != IntPtr.Zero) { waveOutClose(output); output = IntPtr.Zero; }
        Interlocked.Exchange(ref running, 0);
    }
    public void Dispose() { Stop(); inputEvent.Dispose(); outputEvent.Dispose(); stopEvent.Dispose(); }
}
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioDeviceEnumerator {
    void EnumAudioEndpoints(int flow, uint mask, out IntPtr devices);
    void GetDefaultAudioEndpoint(int flow, int role, out IAudioDevice device);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioDevice {
    void Activate(ref Guid iid, uint context, IntPtr parameters, out IntPtr iface);
    void OpenPropertyStore(uint access, out IntPtr store);
    void GetId(out IntPtr id);
}
public static class EazyLoopbackEndpoint {
    public static string DefaultId(int flow) {
        if (flow != 0 && flow != 1) throw new ArgumentOutOfRangeException("flow");
        var type = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
        var enumerator = (IAudioDeviceEnumerator)Activator.CreateInstance(type);
        IAudioDevice device = null;
        IntPtr pointer = IntPtr.Zero;
        try {
            enumerator.GetDefaultAudioEndpoint(flow, 1, out device);
            device.GetId(out pointer);
            return Marshal.PtrToStringUni(pointer);
        } finally {
            if (pointer != IntPtr.Zero) Marshal.FreeCoTaskMem(pointer);
            if (device != null) Marshal.ReleaseComObject(device);
            Marshal.ReleaseComObject(enumerator);
        }
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$monitor = [EazyLoopbackMonitor]::new()
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="EazyLoopback 音频监听" Width="640" SizeToContent="Height"
        MinWidth="560" MinHeight="365" MaxHeight="720" WindowStartupLocation="CenterScreen"
        FontFamily="Microsoft YaHei UI" FontSize="14"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <DockPanel>
    <Menu DockPanel.Dock="Top" FontSize="13" Padding="5,2">
      <MenuItem Header="快捷方式">
        <MenuItem x:Name="SoundSettingsLink" Header="打开声音设置"/>
        <MenuItem x:Name="ClassicSoundLink" Header="声音（控制面板）"/>
        <MenuItem x:Name="DeviceManagerLink" Header="设备管理器"/>
        <MenuItem x:Name="DevicesPrintersLink" Header="设备与打印机"/>
        <Separator/>
        <MenuItem x:Name="VolumeMixerLink" Header="音量合成器"/>
        <MenuItem x:Name="SoundDevicesLink" Header="所有声音设备"/>
        <MenuItem x:Name="OutputPropertiesLink" Header="默认输出设备属性"/>
        <MenuItem x:Name="InputPropertiesLink" Header="默认输入设备属性"/>
        <MenuItem x:Name="MicrophonePrivacyLink" Header="麦克风权限"/>
      </MenuItem>
      <MenuItem x:Name="AboutLink" Header="关于"/>
    </Menu>
    <Grid Margin="20,14,20,18">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="实时音频输入监听与增益控制" Foreground="#666666" Margin="0,0,0,12"/>
      <StackPanel Grid.Row="1" Margin="0,0,0,12">
        <TextBlock Text="音频输入设备" Margin="0,0,0,5"/>
        <ComboBox x:Name="InputBox" Height="33" VerticalContentAlignment="Center" Padding="7,5,5,1"/>
      </StackPanel>
      <StackPanel Grid.Row="2" Margin="0,0,0,12">
        <TextBlock Text="播放设备" Margin="0,0,0,5"/>
        <ComboBox x:Name="OutputBox" Height="33" VerticalContentAlignment="Center" Padding="7,5,5,1"/>
      </StackPanel>
      <StackPanel Grid.Row="3" Margin="0,0,0,12">
        <TextBlock Text="监听音量（0–2000%）" Margin="0,0,0,5"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="82"/>
          </Grid.ColumnDefinitions>
          <Slider x:Name="VolumeSlider" Grid.Column="0" Minimum="0" Maximum="2000"
                  Value="100" TickFrequency="100" IsSnapToTickEnabled="False"
                  IsMoveToPointEnabled="True" SmallChange="1" LargeChange="10"
                  VerticalAlignment="Center" Margin="0,0,12,0"/>
          <TextBox x:Name="VolumeBox" Grid.Column="1" Height="31" Text="100"
                   VerticalContentAlignment="Center" HorizontalContentAlignment="Right"
                   ToolTip="输入 0 到 2000 的百分比，按 Enter 确认"/>
        </Grid>
      </StackPanel>
      <Expander x:Name="LevelExpander" Grid.Row="4" Header="实时音量" IsExpanded="False" Margin="0,0,0,13">
        <Border BorderBrush="#D0D8E2" BorderThickness="1" CornerRadius="4" Padding="10,5,10,7">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="70"/>
            <ColumnDefinition Width="25"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="70"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="24"/>
            <RowDefinition Height="24"/>
            <RowDefinition Height="24"/>
            <RowDefinition Height="24"/>
            <RowDefinition Height="25"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Grid.Column="0" Text="输入" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="0" Grid.Column="1" Text="L" VerticalAlignment="Center"/>
          <ProgressBar x:Name="InputLeftMeter" Grid.Row="0" Grid.Column="2" Maximum="100" Height="12" VerticalAlignment="Center"/>
          <TextBlock x:Name="InputLeftText" Grid.Row="0" Grid.Column="3" Text="−∞ dB" TextAlignment="Right" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="1" Grid.Column="1" Text="R" VerticalAlignment="Center"/>
          <ProgressBar x:Name="InputRightMeter" Grid.Row="1" Grid.Column="2" Maximum="100" Height="12" VerticalAlignment="Center"/>
          <TextBlock x:Name="InputRightText" Grid.Row="1" Grid.Column="3" Text="−∞ dB" TextAlignment="Right" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="2" Grid.Column="0" Text="监听输出" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="2" Grid.Column="1" Text="L" VerticalAlignment="Center"/>
          <ProgressBar x:Name="OutputLeftMeter" Grid.Row="2" Grid.Column="2" Maximum="100" Height="12" VerticalAlignment="Center" Foreground="#2E8B57"/>
          <TextBlock x:Name="OutputLeftText" Grid.Row="2" Grid.Column="3" Text="−∞ dB" TextAlignment="Right" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="3" Grid.Column="1" Text="R" VerticalAlignment="Center"/>
          <ProgressBar x:Name="OutputRightMeter" Grid.Row="3" Grid.Column="2" Maximum="100" Height="12" VerticalAlignment="Center" Foreground="#2E8B57"/>
          <TextBlock x:Name="OutputRightText" Grid.Row="3" Grid.Column="3" Text="−∞ dB" TextAlignment="Right" VerticalAlignment="Center"/>
          <TextBlock x:Name="ClipLabel" Grid.Row="4" Grid.ColumnSpan="4" Text="输入与监听输出峰值（dBFS）"
                     Foreground="#666666" VerticalAlignment="Bottom"/>
        </Grid>
        </Border>
      </Expander>
      <Grid Grid.Row="5" VerticalAlignment="Top">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="StartButton" Grid.Column="0" Content="开始监听" Width="106" Height="34" Margin="0,0,10,0"/>
        <Button x:Name="StopButton" Grid.Column="1" Content="停止" Width="75" Height="34" IsEnabled="False" Margin="0,0,10,0"/>
        <Button x:Name="PreviewButton" Grid.Column="2" Content="试听" Width="75" Height="34"/>
        <TextBlock x:Name="StatusLabel" Grid.Column="3" Text="就绪" TextAlignment="Right"
                   VerticalAlignment="Center" Margin="12,0,0,0" TextTrimming="CharacterEllipsis"/>
      </Grid>
    </Grid>
  </DockPanel>
</Window>
'@
$xmlReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
try { $window = [System.Windows.Markup.XamlReader]::Load($xmlReader) }
finally { $xmlReader.Dispose() }

$inputBox = $window.FindName('InputBox')
$outputBox = $window.FindName('OutputBox')
$volumeSlider = $window.FindName('VolumeSlider')
$volumeBox = $window.FindName('VolumeBox')
$startButton = $window.FindName('StartButton')
$stopButton = $window.FindName('StopButton')
$previewButton = $window.FindName('PreviewButton')
$statusLabel = $window.FindName('StatusLabel')
$clipLabel = $window.FindName('ClipLabel')
$meters = @(
    @{ Bar = $window.FindName('InputLeftMeter'); Text = $window.FindName('InputLeftText') },
    @{ Bar = $window.FindName('InputRightMeter'); Text = $window.FindName('InputRightText') },
    @{ Bar = $window.FindName('OutputLeftMeter'); Text = $window.FindName('OutputLeftText') },
    @{ Bar = $window.FindName('OutputRightMeter'); Text = $window.FindName('OutputRightText') }
)

$shortcuts = @(
    @{ Name='SoundSettingsLink'; File='explorer.exe'; Args='ms-settings:sound' },
    @{ Name='ClassicSoundLink'; File='control.exe'; Args='/name Microsoft.Sound' },
    @{ Name='DeviceManagerLink'; File='mmc.exe'; Args='devmgmt.msc' },
    @{ Name='DevicesPrintersLink'; File='control.exe'; Args='/name Microsoft.DevicesAndPrinters' },
    @{ Name='VolumeMixerLink'; File='explorer.exe'; Args='ms-settings:apps-volume' },
    @{ Name='SoundDevicesLink'; File='explorer.exe'; Args='ms-settings:sound-devices' },
    @{ Name='MicrophonePrivacyLink'; File='explorer.exe'; Args='ms-settings:privacy-microphone' }
)
foreach ($spec in $shortcuts) {
    $item = $window.FindName($spec.Name)
    $item.Tag = $spec
    $item.Add_Click({
        param($sender, $eventArgs)
        try { Start-Process -FilePath $sender.Tag.File -ArgumentList $sender.Tag.Args | Out-Null }
        catch { [System.Windows.MessageBox]::Show($_.Exception.Message, '无法打开快捷方式', 'OK', 'Error') | Out-Null }
    })
}

foreach ($propertyLink in @(@{ Name='OutputPropertiesLink'; Flow=0 }, @{ Name='InputPropertiesLink'; Flow=1 })) {
    $item = $window.FindName($propertyLink.Name)
    $item.Tag = $propertyLink.Flow
    $item.Add_Click({
        param($sender, $eventArgs)
        try {
            $flow = [int]$sender.Tag
            $endpointId = [EazyLoopbackEndpoint]::DefaultId($flow)
            Start-Process -FilePath 'rundll32.exe' -ArgumentList "shell32.dll,Control_RunDLL mmsys.cpl ms-mmsys:,$endpointId,general" | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, '无法打开设备属性', 'OK', 'Error') | Out-Null
        }
    })
}

$window.FindName('AboutLink').Add_Click({
    $aboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="关于 EazyLoopback" Width="450" Height="275" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" FontFamily="Microsoft YaHei UI" FontSize="14"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <StackPanel Margin="24,18">
    <TextBlock Text="EazyLoopback" FontSize="25" FontWeight="SemiBold" Margin="0,0,0,10"/>
    <TextBlock Text="Windows 音频输入监听与增益控制" Margin="0,0,0,14"/>
    <TextBlock Text="作者：GoldesqueMoON" Margin="0,0,0,5"/>
    <TextBlock Text="许可证：Apache License 2.0" Margin="0,0,0,5"/>
    <TextBlock Text="版本：1.0.0"/>
    <StackPanel Orientation="Horizontal" Margin="0,20,0,0">
      <Button x:Name="RepositoryButton" Content="打开 GitHub 项目" Width="145" Height="32" Margin="0,0,10,0"/>
      <Button x:Name="CloseAboutButton" Content="关闭" Width="75" Height="32"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($aboutXaml))
    try { $about = [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
    $about.Owner = $window
    $about.FindName('RepositoryButton').Add_Click({
        try { Start-Process 'https://github.com/Goldppx/awesome-gemTools/tree/main/tools/eazy-loopback' | Out-Null }
        catch { [System.Windows.MessageBox]::Show($_.Exception.Message, '无法打开 GitHub', 'OK', 'Error') | Out-Null }
    })
    $about.FindName('CloseAboutButton').Add_Click({ $about.Close() })
    [void]$about.ShowDialog()
})

[void]$inputBox.Items.Add('系统默认录音设备')
foreach ($deviceName in [EazyLoopbackMonitor]::InputNames()) { [void]$inputBox.Items.Add($deviceName) }
$inputBox.SelectedIndex = 0
[void]$outputBox.Items.Add('系统默认播放设备')
foreach ($deviceName in [EazyLoopbackMonitor]::OutputNames()) { [void]$outputBox.Items.Add($deviceName) }
$outputBox.SelectedIndex = 0

$volumeSlider.Add_ValueChanged({
    $value = [int][Math]::Round($volumeSlider.Value)
    $monitor.GainPercent = $value
    if (-not $volumeBox.IsKeyboardFocusWithin) { $volumeBox.Text = [string]$value }
})
$applyVolume = {
    $old = [int][Math]::Round($volumeSlider.Value)
    $value = 0
    if (-not [int]::TryParse($volumeBox.Text, [ref]$value)) { $value = $old }
    $value = [Math]::Max(0, [Math]::Min(2000, $value))
    $volumeSlider.Value = $value
    $volumeBox.Text = [string]$value
    $monitor.GainPercent = $value
    return ($value -ne $old)
}
$playPreview = {
    $monitor.PlayPreview($outputBox.SelectedIndex - 1)
}
$volumeSlider.Add_PreviewMouseLeftButtonUp({ & $playPreview })
$volumeSlider.Add_KeyUp({
    if ($_.Key -in @([System.Windows.Input.Key]::Left, [System.Windows.Input.Key]::Right,
                     [System.Windows.Input.Key]::Up, [System.Windows.Input.Key]::Down,
                     [System.Windows.Input.Key]::Home, [System.Windows.Input.Key]::End,
                     [System.Windows.Input.Key]::PageUp, [System.Windows.Input.Key]::PageDown)) { & $playPreview }
})
$volumeBox.Add_LostKeyboardFocus({ if (& $applyVolume) { & $playPreview } })
$volumeBox.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::Enter) {
        if (& $applyVolume) { & $playPreview }
        $window.Focus() | Out-Null
    }
})
$previewButton.Add_Click({
    [void](& $applyVolume)
    & $playPreview
})

$startButton.Add_Click({
    try {
        [void](& $applyVolume)
        $monitor.Start($inputBox.SelectedIndex - 1, $outputBox.SelectedIndex - 1)
        $inputBox.IsEnabled = $false
        $outputBox.IsEnabled = $false
        $startButton.IsEnabled = $false
        $stopButton.IsEnabled = $true
        $statusLabel.Text = "正在监听：$($monitor.FormatDescription)"
        $statusLabel.ToolTip = $statusLabel.Text
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, '无法开始监听', 'OK', 'Error') | Out-Null
    }
})
$stopButton.Add_Click({
    $monitor.Stop()
    $inputBox.IsEnabled = $true
    $outputBox.IsEnabled = $true
    $startButton.IsEnabled = $true
    $stopButton.IsEnabled = $false
    $statusLabel.Text = '已停止'
})

$meterPercent = {
    param([int]$peak)
    if ($peak -le 0) { return 0.0 }
    $db = 20.0 * [Math]::Log10($peak / 32768.0)
    return [Math]::Max(0.0, [Math]::Min(100.0, ($db + 60.0) * 100.0 / 60.0))
}
$meterText = {
    param([int]$peak)
    if ($peak -le 0) { return '−∞ dB' }
    return ('{0:0} dB' -f (20.0 * [Math]::Log10($peak / 32768.0)))
}
$script:clipUntil = [DateTime]::MinValue
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
    $peaks = $monitor.TakePeaks()
    for ($i = 0; $i -lt 4; $i++) {
        $target = & $meterPercent $peaks[$i]
        $bar = $meters[$i].Bar
        $bar.Value = [Math]::Max($target, $bar.Value - 5)
        if ($peaks[$i] -gt 0) { $meters[$i].Text.Text = & $meterText $peaks[$i] }
        elseif ($bar.Value -le 0) { $meters[$i].Text.Text = '−∞ dB' }
    }
    if ($peaks[4] -gt 0) { $script:clipUntil = [DateTime]::UtcNow.AddMilliseconds(1200) }
    if ([DateTime]::UtcNow -lt $script:clipUntil) {
        $clipLabel.Text = '监听输出削波：请降低音量以避免失真'
        $clipLabel.Foreground = [System.Windows.Media.Brushes]::OrangeRed
    } else {
        $clipLabel.Text = '输入与监听输出峰值（dBFS）'
        $clipLabel.Foreground = [System.Windows.Media.Brushes]::DimGray
    }
    $previewError = $monitor.TakePreviewError()
    if ($previewError) { [System.Windows.MessageBox]::Show($previewError, '试听失败', 'OK', 'Error') | Out-Null }
    if ($stopButton.IsEnabled -and -not $monitor.IsRunning) {
        $message = $monitor.Error
        $monitor.Stop()
        $inputBox.IsEnabled = $true
        $outputBox.IsEnabled = $true
        $startButton.IsEnabled = $true
        $stopButton.IsEnabled = $false
        $statusLabel.Text = '监听已停止'
        if ($message) { [System.Windows.MessageBox]::Show($message, '音频错误', 'OK', 'Error') | Out-Null }
    }
})
$timer.Start()
$window.Add_Closed({ $timer.Stop(); $monitor.Dispose() })
[void]$window.ShowDialog()
