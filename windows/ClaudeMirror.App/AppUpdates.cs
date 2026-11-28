using System.Diagnostics;
using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    private readonly CancellationTokenSource updateLifetime = new();
    private readonly SemaphoreSlim updateLock = new(1, 1);
    private Button restartButton = null!;
    private StableUpdate? pendingUpdate;
    private string? stagedInstaller;

    private void StartCheckingUpdates()
    {
        Closed += (_,_) => { updateLifetime.Cancel(); InstallOnQuit(); };
        if (DemoScene is null && !Environment.GetCommandLineArgs().Contains("--smoke-test"))
            _ = CheckPeriodicallyAsync();
    }
    private async Task CheckPeriodicallyAsync()
    {
        using var timer=new PeriodicTimer(TimeSpan.FromHours(4));
        try { do await CheckUpdatesAsync(false); while(await timer.WaitForNextTickAsync(updateLifetime.Token)); }
        catch(OperationCanceledException) { }
    }
    private bool installing;
    // Like Sparkle on macOS: a staged update the user did not install now goes in silently once the app quits.
    private void InstallOnQuit()
    {
        if(installing || stagedInstaller is not {} installer || pendingUpdate is not {} update || !File.Exists(Path.Combine(AppContext.BaseDirectory,"unins000.exe"))) return;
        try {
            update.VerifyFileAsync(installer,CancellationToken.None).GetAwaiter().GetResult();
            var start=new ProcessStartInfo(installer){UseShellExecute=true};
            foreach(var arg in new[]{"/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART"})start.ArgumentList.Add(arg);
            Process.Start(start)?.Dispose();
        } catch { }
    }
    private async Task CheckUpdatesAsync(bool manual)
    {
        if (stagedInstaller is not null) {
            if (manual) status.Text=$"{pendingUpdate?.Tag} 已下载，可以重启更新";
            return;
        }
        if (!await updateLock.WaitAsync(0)) {
            if (manual) status.Text="正在检查或下载更新…";
            return;
        }
        try {
            var token=updateLifetime.Token;
            if(manual) status.Text="正在检查更新…";
            var update=await StableUpdate.CheckAsync(token);
            if(update==null) {
                if(manual) status.Text=$"已是最新稳定版本 v{StableUpdate.CurrentVersion}";
                return;
            }
            if(manual) status.Text=$"正在下载 {update.Tag}…";
            var directory=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"claude-mirror","updates");
            var installer=await update.StageAsync(directory,token);
            token.ThrowIfCancellationRequested();
            pendingUpdate=update;stagedInstaller=installer;
            restartButton.Visibility=Visibility.Visible;
            status.Text=$"{update.Tag} 已下载，可以重启更新";
        } catch(OperationCanceledException) when(updateLifetime.IsCancellationRequested) {
        } catch(Exception ex) {
            if(manual) status.Text="更新检查失败："+ex.Message;
        } finally { updateLock.Release(); }
    }
    private bool CanRestart() => !(busy || parked.Values.Any(p => p.Active) || openFiles.Any(f=>f.Dirty || f.Saving) || !string.IsNullOrWhiteSpace(prompt.Text));
    private async Task InstallUpdateAsync()
    {
        if(pendingUpdate is not {} update || stagedInstaller is not {} installer)return;
        if(!CanRestart()) {status.Text="请先保存文件、处理草稿并等待回复结束";return;}
        var answer=await new ContentDialog { XamlRoot=root.XamlRoot, Title=$"安装 {update.Tag}？",
            Content="安装完成后会自动重新打开",
            PrimaryButtonText="安装并重启",CloseButtonText="稍后" }.ShowAsync();
        if(answer!=ContentDialogResult.Primary)return;
        await update.VerifyFileAsync(installer,updateLifetime.Token);
        if(!CanRestart()) {status.Text="窗口仍有未完成的工作，请稍后重试。";return;}
        var start=new ProcessStartInfo(installer){UseShellExecute=true};
        foreach(var arg in new[]{"/SILENT","/NORESTART","/UPDATEANDRESTART"})start.ArgumentList.Add(arg);
        using var process=Process.Start(start) ?? throw new IOException("无法启动安装程序");
        installing=true;
        Close();
    }
}
