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
        Closed += (_,_) => updateLifetime.Cancel();
        if (!Environment.GetCommandLineArgs().Contains("--smoke-test"))
            _ = CheckUpdatesAsync(false);
    }
    private async Task CheckUpdatesAsync(bool manual)
    {
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
    private bool CanRestart() => !(busy || openFiles.Any(f=>f.Dirty || f.Saving) || !string.IsNullOrWhiteSpace(prompt.Text));
    private async Task InstallUpdateAsync()
    {
        if(pendingUpdate is not {} update || stagedInstaller is not {} installer)return;
        if(!CanRestart()) {status.Text="请先保存文件、处理输入草稿，并等待当前回复结束。";return;}
        var answer=await new ContentDialog { XamlRoot=root.XamlRoot, Title=$"安装 {update.Tag}？",
            Content="Claude Mirror 将关闭当前窗口，安装完成后重新打开。主机配置会保留。便携版将安装为当前用户的应用。",
            PrimaryButtonText="安装并重启",CloseButtonText="稍后" }.ShowAsync();
        if(answer!=ContentDialogResult.Primary)return;
        await update.VerifyFileAsync(installer,updateLifetime.Token);
        if(!CanRestart()) {status.Text="窗口仍有未完成的工作，请稍后重试。";return;}
        var start=new ProcessStartInfo(installer){UseShellExecute=true};
        foreach(var arg in new[]{"/SILENT","/NORESTART","/UPDATEANDRESTART"})start.ArgumentList.Add(arg);
        using var process=Process.Start(start) ?? throw new IOException("无法启动安装程序");
        Close();
    }
}
