using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace ClaudeMirror.App;

/// <summary>System notifications for what needs the user while the window is in the background. Clicking one brings the window back.</summary>
internal sealed class Notifier
{
    private readonly bool ready;
    public bool Foreground { get; set; } = true;

    public Notifier(Action invoked)
    {
        try
        {
            if (!AppNotificationManager.IsSupported()) return;
            AppNotificationManager.Default.NotificationInvoked += (_, _) => invoked();
            AppNotificationManager.Default.Register();
            ready = true;
        }
        catch (Exception) { } // Notifications are a convenience; the app works without them.
    }

    public void Tell(string title, string body)
    {
        if (!ready || Foreground) return;
        try { AppNotificationManager.Default.Show(new AppNotificationBuilder().AddText(title).AddText(body).BuildNotification()); }
        catch (Exception) { }
    }

    public void Close()
    {
        if (!ready) return;
        try { AppNotificationManager.Default.Unregister(); } catch (Exception) { }
    }
}
