using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    private static readonly (string Value, string Label)[] Themes = [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")];

    /// The saved appearance. The palette follows through the root's ActualThemeChanged.
    private void ApplySavedTheme() =>
        root.RequestedTheme = local.Theme switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };

    private async Task SettingsAsync()
    {
        var theme = new ComboBox { Header = "外观", ItemsSource = Themes.Select(item => item.Label).ToList(), SelectedIndex = Math.Max(0, Array.FindIndex(Themes, item => item.Value == local.Theme)), MinWidth = 220 };
        theme.SelectionChanged += (_, _) =>
        {
            if (theme.SelectedIndex < 0) return;
            local.Theme = Themes[theme.SelectedIndex].Value; local.Save(); ApplySavedTheme();
        };
        var panel = new StackPanel { Spacing = 16, MinWidth = 380 };
        panel.Children.Add(theme);
        void Line(string label, string value)
        {
            panel.Children.Add(new TextBlock { Text = label, FontSize = 12, Foreground = muted });
            panel.Children.Add(new TextBlock { Text = value, FontSize = 13, Foreground = ink, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Margin = new Thickness(0, -12, 0, 0) });
        }
        Line("版本", typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "未知");
        Line("已保存的服务器", local.Hosts.Count == 0 ? "无" : string.Join("、", local.Hosts.Select(saved => saved.Name)));
        Line("本机数据", "LocalAppData\\claude-mirror · 不保存密码");
        await new ContentDialog { XamlRoot = root.XamlRoot, Title = "设置", Content = panel, CloseButtonText = "完成", Background = canvas }.ShowAsync();
    }
}
