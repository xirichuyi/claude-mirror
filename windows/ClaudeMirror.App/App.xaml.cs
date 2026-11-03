using Microsoft.UI.Xaml;
namespace ClaudeMirror.App;
public partial class App : Application
{
    private Window? window;
    public App() { InitializeComponent(); }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        if (args.Arguments == "--smoke-test" && window.Content is FrameworkElement root)
        {
            root.Loaded += (_, _) =>
            {
                File.WriteAllText(Path.Combine(Path.GetTempPath(), "claude-mirror-smoke.txt"), "WinUI window loaded");
                Exit();
            };
        }
        window.Activate();
    }
}
