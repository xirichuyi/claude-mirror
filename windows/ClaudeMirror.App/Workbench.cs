using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    private readonly SolidColorBrush canvas = new(), rail = new(), surface = new(), ink = new(),
        muted = new(), edge = new(), bubble = new(), sage = new();
    private readonly Grid railPanel = new();
    private readonly StackPanel home = new() { Spacing = 16, MaxWidth = 620, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock title = new(), subtitle = new(), connection = new(), homeTitle = new(), homeHint = new();
    private readonly StackPanel homeActions = new() { Spacing = 8 };
    private readonly TextBox search = new() { PlaceholderText = "搜索对话或目录", Visibility = Visibility.Collapsed };
    private readonly Border composer = new();
    private List<Conversation> history = [];
    private readonly Dictionary<string,bool> openGroups = [];
    private Button send = null!, stop = null!, fresh = null!, sync = null!;
    private Button files = null!, project = null!;
    private bool sidebarOpen = true;
    private readonly StackPanel welcomeHeading = new() { Orientation=Orientation.Horizontal, Spacing=12 };
    private readonly Image welcomeIcon = new() { Width=38, Height=38 };
    private readonly Border hostDot = new() { Width=8, Height=8, CornerRadius=new CornerRadius(4), VerticalAlignment=VerticalAlignment.Center };
    private readonly Border inputCard = new();
    private Button commandMenu = null!, modelMenu = null!, connectHost = null!;

    private static string ShortDirectory(string path)
    {
        var leaf = path.TrimEnd('/','\\').Split('/','\\').LastOrDefault();
        return string.IsNullOrEmpty(leaf) ? path : leaf;
    }

    private void UpdateHostPicker()
    {
        bool current=agent?.Connected==true && host!=null && Equals(hosts.SelectedItem,host);
        connectHost.Visibility=current?Visibility.Collapsed:Visibility.Visible;
        ToolTipService.SetToolTip(hosts,(hosts.SelectedItem as HostProfile)?.Name ?? "选择主机");
    }

    private void UpdateSubtitle()
    {
        subtitle.Text = host==null ? "" : ShortDirectory(directory.Text)+"  ·  "+host.Name;
        ToolTipService.SetToolTip(subtitle, directory.Text);
    }

    private Button PickerAction(bool model)
    {
        var trigger=ActionButton(model?"模型":"命令", model?"\uE70D":"\uE756",()=>Task.CompletedTask,true);
        var menu=new MenuFlyout();
        menu.Opening+=(_,_)=>{
            menu.Items.Clear();
            if(model){
                foreach(var option in availableModels){
                    var choice=new MenuFlyoutItem {Text=option.Label};
                    choice.Click+=(_,_)=>{selectedModel=option; UpdatePickerTitle();};menu.Items.Add(choice);
                }
            }else{
                foreach(var name in availableCommands){
                    var choice=new MenuFlyoutItem {Text="/"+name};
                    choice.Click+=(_,_)=>{prompt.Text="/"+name+" ";prompt.SelectionStart=prompt.Text.Length;prompt.Focus(FocusState.Programmatic);};menu.Items.Add(choice);
                }
            }
            if(menu.Items.Count==0)menu.Items.Add(new MenuFlyoutItem {Text=model?"服务器未返回模型列表":"服务器未返回命令列表",IsEnabled=false});
        };
        trigger.Flyout=menu;return trigger;
    }
    private void UpdatePickerTitle()
    {
        var label=selectedModel?.Label ?? "模型";
        modelMenu.Content=Row(new TextBlock {Text=label,MaxWidth=125,TextTrimming=TextTrimming.CharacterEllipsis},new FontIcon {Glyph="\uE70D",FontSize=10});
    }

    private void ApplyTheme()
    {
        bool dark = root.ActualTheme == ElementTheme.Dark;
        foreach (var (brush, light, night) in new[] {
            (canvas,0xFAF6F2,0x242424), (rail,0xF0EAE3,0x1C1C1C), (surface,0xF6F1EB,0x2C2C2C),
            (ink,0x272727,0xEAEAEA), (muted,0x645E58,0xBBB6B0), (edge,0xDCD5CE,0x484848),
            (bubble,0xEDE5DC,0x343434), (sage,0x566746,0xB4C49E) })
        {
            int rgb = dark ? night : light;
            brush.Color = Windows.UI.Color.FromArgb(255,(byte)(rgb >> 16),(byte)(rgb >> 8),(byte)rgb);
        }
    }
    private static Grid Rows(params GridLength[] heights)
    {
        var g = new Grid();
        foreach (var h in heights) g.RowDefinitions.Add(new RowDefinition { Height = h });
        return g;
    }
    private static void At(Grid g, FrameworkElement el, int row)
    {
        Grid.SetRow(el,row); g.Children.Add(el);
    }
    private Button ActionButton(string name, string glyph, Func<Task> action, bool showLabel = false)
    {
        var button = Button(name,action);
        var icon = new FontIcon { Glyph = glyph, FontSize = 15 };
        button.Content = showLabel ? Row(icon,new TextBlock { Text = name }) : icon;
        button.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        button.BorderThickness = new Thickness(0); button.CornerRadius = new CornerRadius(6);
        button.Foreground = ink; button.MinWidth = 32; button.MinHeight = 32;
        button.Padding = new Thickness(7,4,7,4);
        AutomationProperties.SetName(button,name); ToolTipService.SetToolTip(button,name);
        return button;
    }
    private void BuildWorkbench()
    {
        ApplyTheme(); root.ActualThemeChanged += (_,_) => ApplyTheme();
        root.Background = canvas;
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) });
        root.ColumnDefinitions.Add(new ColumnDefinition());
        railPanel.Background = rail; railPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        railPanel.RowDefinitions.Add(new RowDefinition()); railPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(railPanel);
        sidebar.Padding = new Thickness(12); sidebar.Spacing = 8;
        var brand = new TextBlock { Text = "claude-mirror", FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = ink, Margin = new Thickness(7,4,0,6) };
        sidebar.Children.Add(brand);
        hosts.ItemsSource = local.Hosts; hosts.MinWidth = 0;
        var switcher = new Grid { ColumnSpacing = 2 };
        switcher.ColumnDefinitions.Add(new ColumnDefinition());
        switcher.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        hosts.BorderThickness=new Thickness(0);hosts.Background=new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        hosts.Padding=new Thickness(8,4,6,4);
        var hostPicker=new Grid {ColumnSpacing=2};hostPicker.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});hostPicker.ColumnDefinitions.Add(new ColumnDefinition());
        hostDot.Margin=new Thickness(6,0,0,0);hostPicker.Children.Add(hostDot);Grid.SetColumn(hosts,1);hostPicker.Children.Add(hosts);switcher.Children.Add(hostPicker);
        connectHost=ActionButton("连接","\uE839",() => ConnectDialogAsync(hosts.SelectedItem as HostProfile));
        hosts.SelectionChanged+=(_,_)=>UpdateHostPicker();
        var tools = Row(connectHost,
            ActionButton("添加主机","\uE710",() => ConnectDialogAsync(null)));
        Grid.SetColumn(tools,1); switcher.Children.Add(tools); sidebar.Children.Add(switcher);
        fresh = ActionButton("新建对话","\uE70F",NewConversationAsync,true);
        fresh.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.N, Modifiers = VirtualKeyModifiers.Control });
        sync = ActionButton("同步历史","\uE72C",RefreshHistoryAsync);
        var find = ActionButton("搜索对话","\uE721",() => {
            search.Visibility = search.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            if(search.Visibility == Visibility.Visible) search.Focus(FocusState.Programmatic); else search.Text = "";
            return Task.CompletedTask;
        });
        sidebar.Children.Add(Row(fresh,find,sync)); sidebar.Children.Add(search);
        search.TextChanged += (_,_) => RenderHistory();
        At(railPanel,sidebar,0); projects.Padding = new Thickness(12,8,12,12);
        At(railPanel,new ScrollViewer { Content = projects },1);
        status.Foreground = muted; status.Margin = new Thickness(16,12,16,12);
        At(railPanel,status,2);

        var area = Rows(GridLength.Auto,new GridLength(1,GridUnitType.Star),GridLength.Auto);
        BuildSplit(area);
        var bar = new Grid { Padding = new Thickness(12,8,12,8), ColumnSpacing = 10 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition()); bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var toggle = ActionButton("切换侧栏","\uE700",() => { sidebarOpen = !sidebarOpen; LayoutSidebar(); return Task.CompletedTask; });
        bar.Children.Add(toggle);
        var headings = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; title.Foreground = ink; title.TextTrimming = TextTrimming.CharacterEllipsis;
        subtitle.FontSize = 12; subtitle.Foreground = muted; subtitle.TextTrimming = TextTrimming.CharacterEllipsis;
        headings.Children.Add(title); headings.Children.Add(subtitle); Grid.SetColumn(headings,1); bar.Children.Add(headings);
        var update = ActionButton("检查更新","\uE895",()=>CheckUpdatesAsync(true),true);
        At(area,bar,0);
        scroll.MaxWidth = 800; scroll.HorizontalAlignment = HorizontalAlignment.Stretch;
        scroll.HorizontalContentAlignment = HorizontalAlignment.Stretch; scroll.HorizontalScrollMode = ScrollMode.Disabled;
        scroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        bool followReply = true;
        scroll.ViewChanged += (_,_) => followReply = scroll.ScrollableHeight-scroll.VerticalOffset < 48;
        messages.SizeChanged += (_,e) => { if(followReply && e.NewSize.Height > e.PreviousSize.Height)
            DispatcherQueue.TryEnqueue(()=>scroll.ChangeView(null,scroll.ScrollableHeight,null,true)); };
        messages.HorizontalAlignment = HorizontalAlignment.Stretch;
        scroll.Content = messages; At(area,scroll,1);
        home.Margin = new Thickness(32,64,32,16);
        home.VerticalAlignment = VerticalAlignment.Top;
        homeTitle.FontSize = 28; homeTitle.Foreground = ink; homeTitle.FontWeight=Microsoft.UI.Text.FontWeights.Medium;
        welcomeIcon.Source=new BitmapImage(new Uri("ms-appx:///Assets/BrandIcon.png"));
        welcomeHeading.Children.Add(welcomeIcon);welcomeHeading.Children.Add(homeTitle);
        homeHint.Foreground = muted;
        homeHint.TextWrapping = TextWrapping.Wrap;
        home.Children.Add(welcomeHeading); home.Children.Add(homeHint); home.Children.Add(healthPanel); home.Children.Add(homeActions);
        At(area,home,1);
        var composeArea = new StackPanel { MaxWidth = 800, Spacing = 8, Margin = new Thickness(20,6,20,14) };
        composer.Child = composeArea; At(area,composer,2);
        connection.FontSize = 12; connection.Foreground = sage; composeArea.Children.Add(connection);
        var input = new StackPanel { Spacing = 6 }; prompt.MinHeight = 44;
        prompt.BorderThickness = new Thickness(0); prompt.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        foreach(var key in new[]{"TextControlBackground","TextControlBackgroundPointerOver","TextControlBackgroundFocused","TextControlBorderBrush","TextControlBorderBrushPointerOver","TextControlBorderBrushFocused"})
            prompt.Resources[key]=new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        prompt.Resources["TextControlBorderThemeThicknessFocused"]=new Thickness(0);
        prompt.Padding=new Thickness(2,3,2,3);
        prompt.GotFocus+=(_,_)=>inputCard.BorderBrush=muted;
        prompt.LostFocus+=(_,_)=>inputCard.BorderBrush=edge;
        input.Children.Add(prompt);
        var toolbar = new Grid(); toolbar.ColumnDefinitions.Add(new ColumnDefinition()); toolbar.ColumnDefinitions.Add(new ColumnDefinition {Width=GridLength.Auto});

        commandMenu=PickerAction(false);modelMenu=PickerAction(true);UpdatePickerTitle();
        toolbar.Children.Add(Row(ActionButton("附件","\uE723",UploadAsync),commandMenu));
        send = ActionButton("发送","\uE74A",SendAsync); send.Background = ink; send.Foreground = canvas; send.CornerRadius = new CornerRadius(18);
        stop = ActionButton("停止","\uE71A",StopAsync);
        var actions = Row(modelMenu,stop,send); Grid.SetColumn(actions,1); toolbar.Children.Add(actions); input.Children.Add(toolbar);
        inputCard.Background=surface;inputCard.BorderBrush=edge;inputCard.BorderThickness=new Thickness(1);inputCard.CornerRadius=new CornerRadius(16);inputCard.Padding=new Thickness(14,12,14,10);inputCard.Child=input;composeArea.Children.Add(inputCard);
        files = ActionButton("远端文件","\uE8B7",BrowseAsync);
        project = ActionButton("工作目录","\uE838",() => Task.CompletedTask);
        directory.Width = 230; directory.Header = "远端工作目录";
        project.Flyout = new Flyout { Content = directory };
        var editors = ActionButton("切换文件编辑器","\uE8A5",()=>{ if(openFiles.Count==0)return BrowseAsync(); showEditor=!showEditor;LayoutSplit();return Task.CompletedTask; });
        var more=ActionButton("更多操作","\uE712",()=>Task.CompletedTask);
        more.Flyout=new Flyout { Content=new StackPanel {Children={project,editors,update}} };
        restartButton=ActionButton("重启更新","\uE895",InstallUpdateAsync,true);
        restartButton.Visibility=Visibility.Collapsed;
        var headerActions = Row(restartButton,files,more);
        Grid.SetColumn(headerActions,2); bar.Children.Add(headerActions);
        directory.TextChanged += (_,_) => UpdateSubtitle();
        prompt.TextChanged += (_,_) => {UpdateActions();ShowSuggestions();};
        prompt.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.Enter, Modifiers = VirtualKeyModifiers.Control });
        prompt.KeyboardAccelerators[0].Invoked += async (_,e) => { e.Handled = true; if(send.IsEnabled) await RunAsync(SendAsync); };
        root.SizeChanged += (_,e) => { if((e.PreviousSize.Width >= 720) != (e.NewSize.Width >= 720) || e.PreviousSize.Width == 0) { sidebarOpen = e.NewSize.Width >= 720; LayoutSidebar(); } };
        Content = root; RenderHistory();
    }
    private void LayoutSidebar()
    {
        railPanel.Visibility = sidebarOpen ? Visibility.Visible : Visibility.Collapsed;
        root.ColumnDefinitions[0].Width = new GridLength(sidebarOpen ? 240 : 0);
    }
    private void RenderHistory()
    {
        projects.Children.Clear();
        var list = history.Where(c => (c.Name+" "+c.Directory).Contains(search.Text,StringComparison.OrdinalIgnoreCase)).ToList();
        projects.Children.Add(new TextBlock { Text = list.Count > 0 ? "项目" : search.Text.Length > 0 ? "没有找到匹配的对话" : "暂无历史对话", Foreground = muted, FontSize = 13 });
        if(history.Count == 0 && host == null) projects.Children.Add(new TextBlock { Text = "连接后自动同步这台机器的对话", Foreground = muted, FontSize = 12 });
        int index = 0;
        foreach(var group in list.GroupBy(c=>c.Directory))
        {
            var items = new StackPanel { Spacing = 2 };
            items.Children.Add(ActionButton("新建对话","\uE710",async () => { directory.Text = group.Key; await NewConversationAsync(); },true));
            foreach(var c in group)
            {
                var row = Button(c.Name,() => SelectAsync(c));
                row.Content = new TextBlock {Text=c.Name,TextTrimming=TextTrimming.CharacterEllipsis};
                row.HorizontalAlignment = HorizontalAlignment.Stretch; row.HorizontalContentAlignment = HorizontalAlignment.Left;
                row.Background = c == conversation ? bubble : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
                row.BorderThickness = new Thickness(0); ToolTipService.SetToolTip(row,c.Name); items.Children.Add(row);
            }
            var path = group.Key; var groupId = (host == null ? "" : LocalState.HostKey(host)) + "|" + path;
            var folder = ShortDirectory(path);
            bool expanded = search.Text.Length>0 || (openGroups.TryGetValue(groupId,out var remembered) ? remembered : index < 2 || group.Any(c=>c==conversation));
            index++;
            var arrow = new FontIcon { FontSize=11 };
            void SetExpanded(bool value) { expanded=value;arrow.Glyph=value?"\uE70D":"\uE76C";items.Visibility=value?Visibility.Visible:Visibility.Collapsed; }
            var section = Button(folder ?? path,()=> { SetExpanded(!expanded); openGroups[groupId]=expanded;return Task.CompletedTask; });
            section.Content=Row(arrow,new FontIcon {Glyph="\uE8B7",FontSize=15},new TextBlock {Text=string.IsNullOrEmpty(folder)?path:folder,TextTrimming=TextTrimming.CharacterEllipsis});
            section.HorizontalContentAlignment=HorizontalAlignment.Left;section.HorizontalAlignment=HorizontalAlignment.Stretch;
            section.Background=new SolidColorBrush(Microsoft.UI.Colors.Transparent);section.BorderThickness=new Thickness(0);
            AutomationProperties.SetName(section,path);ToolTipService.SetToolTip(section,path);items.Margin=new Thickness(12,0,0,0);
            SetExpanded(expanded);projects.Children.Add(section);projects.Children.Add(items);
        }
        if(list.Count > 0 && search.Text.Length == 0) {
            projects.Children.Add(new TextBlock { Text="最近对话", Foreground=muted, FontSize=13, Margin=new Thickness(4,12,0,0) });
            foreach(var c in list.Take(6)) {
                var item=ActionButton(c.Name,"\uE81C",()=>SelectAsync(c),true);
                item.HorizontalContentAlignment=HorizontalAlignment.Left;
                projects.Children.Add(item);
            }
        }
    }
    private void RefreshWorkbench()
    {
        bool online = agent?.Connected == true, empty = messages.Children.Count == 0 && conversation == null;
        title.Text = conversation?.Name ?? (host == null ? "claude-mirror" : "新对话");
        UpdateSubtitle();UpdatePickerTitle();UpdateHostPicker();
        composer.Visibility = host != null ? Visibility.Visible : Visibility.Collapsed;
        hostDot.Background=online?sage:muted;connection.Text="未连接";connection.Visibility=online?Visibility.Collapsed:Visibility.Visible;
        fresh.IsEnabled = online; sync.IsEnabled = online;
        files.Visibility = project.Visibility = host == null ? Visibility.Collapsed : Visibility.Visible;
        files.IsEnabled = online; project.IsEnabled = online && !busy;
        home.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        scroll.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        if(empty) {
            homeTitle.Text = online ? "今天，想完成什么？" : host == null ? "开始使用" : agent?.SshConnected == true ? "设置服务器" : "连接服务器";
            home.VerticalAlignment=online?VerticalAlignment.Center:VerticalAlignment.Top;
            home.Margin=online?new Thickness(16,12,16,36):new Thickness(32,64,32,16);
            home.Spacing=online?24:16;
            welcomeHeading.HorizontalAlignment=homeActions.HorizontalAlignment=online?HorizontalAlignment.Center:HorizontalAlignment.Left;
            welcomeIcon.Visibility=online?Visibility.Visible:Visibility.Collapsed;
            homeHint.Text = host == null
                ? "在这台电脑上使用服务器里的 Claude Code：代码和 Claude 都在服务器上运行，这里负责对话和审批。\n\n1. 准备一台能用 SSH 登录的 Linux 或 macOS 服务器\n2. 添加服务器：填写地址和密码\n3. 自动检查环境：缺少 Claude Code 或 Node.js 时一键安装，然后登录 Claude"
                : agent?.SshConnected == true ? "SSH 已连接，按下面的提示完成设置。" : "使用服务器上的 Claude Code。";
            homeHint.Visibility=online?Visibility.Collapsed:Visibility.Visible;
            homeActions.Children.Clear();
            if(!online) {
                var add = ActionButton(host == null ? "添加服务器" : "重新连接","\uE710",()=>ConnectDialogAsync(host),true);
                add.Background=ink;add.Foreground=canvas;add.HorizontalAlignment=HorizontalAlignment.Left;
                if(agent?.SshConnected != true) homeActions.Children.Add(add);
                if(host == null) homeActions.Children.Add(new HyperlinkButton { Content = "没有服务器？查看入门指南", NavigateUri = GettingStartedUrl });
            } else {
                var suggestions = new StackPanel { Orientation=Orientation.Horizontal,Spacing=6 };
                foreach(var (name,glyph,text) in new[]{("了解项目","\uE8B7","请梳理这个项目的目录结构、技术栈和主要入口。"),("检查代码","\uE721","请检查当前项目，找出影响使用的问题并给出改进建议。"),("实现功能","\uE943","我想实现一个新功能：")}) {
                    var item = ActionButton(name,glyph,()=>{prompt.Text=text;prompt.Focus(FocusState.Programmatic);return Task.CompletedTask;},true);
                    item.Background=surface;item.BorderBrush=edge;item.BorderThickness=new Thickness(1);item.CornerRadius=new CornerRadius(8);suggestions.Children.Add(item);
                }
                homeActions.Children.Add(suggestions);
            }
        }
        ShowSuggestions();
        UpdateActions();
    }
    private void ShowSuggestions()
    {
        bool hidden = agent?.Connected==true && prompt.Text.Length>0;
        homeActions.MinHeight=34;
        if(homeActions.Children.Count>0) homeActions.Children[0].Visibility=hidden?Visibility.Collapsed:Visibility.Visible;
    }
    private void UpdateActions()
    {
        send.IsEnabled = agent?.Connected == true && !busy && !string.IsNullOrWhiteSpace(prompt.Text);
        stop.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
    }
}
