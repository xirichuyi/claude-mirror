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
        muted = new(), edge = new(), bubble = new(), sage = new(), danger = new(), amber = new(), added = new(), removed = new(),
        frame = new(), popup = new(), hover = new(), dim = new(), accent = new(), accentFill = new(), onAccent = new(), selected = new();
    private readonly Grid railPanel = new();
    private readonly StackPanel home = new() { Spacing = 12, MaxWidth = 560, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly StackPanel homeRecent = new() { Spacing = 2 };
    private readonly TextBlock windowTitle = new();
    private Button archiveToggle = null!;
    private readonly TextBlock title = new(), subtitle = new(), connection = new(), homeTitle = new(), homeHint = new();
    private readonly StackPanel homeActions = new() { Spacing = 8 };
    private readonly Border stateDot = new() { Width=7, Height=7, CornerRadius=new CornerRadius(3.5) };
    private readonly TextBox search = new() { PlaceholderText = "搜索对话或目录", Visibility = Visibility.Collapsed };
    private readonly Border composer = new();
    private List<Conversation> history = [];
    private readonly Dictionary<string,bool> openGroups = [];
    private Button send = null!, steer = null!, enqueue = null!, fresh = null!, sync = null!;
    private readonly FontIcon sendIcon = new() { Glyph = "\uE74A", FontSize = 14 };
    private readonly TextBlock contextMeter = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4,0,4,0) };
    /// True while an input method is composing: Enter then belongs to it, not to send.
    private bool composing;
    private static bool Held(VirtualKey key) => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
    private Button files = null!, project = null!;
    private bool sidebarOpen = true;
    private readonly Border hostDot = new() { Width=7, Height=7, CornerRadius=new CornerRadius(3.5), VerticalAlignment=VerticalAlignment.Center };
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
        subtitle.Text = host==null ? "" : directory.Text;
        windowTitle.Text = host==null ? "claude-mirror" : ShortDirectory(directory.Text) is { Length: > 0 } folder ? folder : host.Name;
    }

    private Button PickerAction(bool model)
    {
        var trigger=ActionButton(model?"模型":"命令", model?"\uE70D":"\uE756",()=>Task.CompletedTask,model);
        var menu=new MenuFlyout();
        menu.Opening+=(_,_)=>{
            menu.Items.Clear();
            if(model){
                foreach(var option in availableModels){
                    var choice=new MenuFlyoutItem {Text=option.Label};
                    choice.Click+=(_,_)=>{selectedModel=option; UpdatePickerTitle(); if(permissionMode=="auto"&&!option.Auto){permissionMode="default"; UpdatePermissionTitle(); status.Text="这个模型不支持自动权限，已改回默认权限";}};menu.Items.Add(choice);
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

    /// The macOS palettes (daylight and midnight in DesignSystem/ThemePalette.swift) and the same derived tokens:
    /// cards float on a grey frame, inputs and code sit slightly off the card, and blue marks selection and the main action.
    private void ApplyTheme()
    {
        bool dark = root.ActualTheme == ElementTheme.Dark;
        int card = dark ? 0x1B1E24 : 0xFBFBFC, text = dark ? 0xD4D8DF : 0x24272E, fill = dark ? 0x3D6FC4 : 0x2B66D2;
        int over = dark ? 0xFFFFFF : 0x000000, green = dark ? 0x5FBFA0 : 0x16805F, red = dark ? 0xEB7F6C : 0xC4432F;
        foreach (var (brush, rgb) in new[] {
            (frame, dark ? 0x15171C : 0xE9EBEF), (canvas, card), (rail, card), (popup, dark ? 0x23272E : 0xFFFFFF),
            (surface, Mix(over,card,dark ? .035 : .03)), (edge, Mix(over,card,dark ? .07 : .09)), (hover, Mix(over,card,dark ? .05 : .045)),
            (ink, text), (muted, dark ? 0x959CA8 : 0x5C6370), (dim, dark ? 0x656C78 : 0x9AA0AB),
            (accent, dark ? 0x78AEF2 : 0x2B66D2), (accentFill, fill), (onAccent, 0xFFFFFF),
            (selected, Mix(fill,card,dark ? .32 : .16)), (bubble, Mix(fill,card,dark ? .24 : .1)),
            (sage, green), (danger, dark ? 0xF07F7F : 0xC2373A), (amber, dark ? 0xE2BA6A : 0x9A6200),
            (added, Mix(green,card,dark ? .2 : .14)), (removed, Mix(red,card,dark ? .2 : .14)) })
            brush.Color = Windows.UI.Color.FromArgb(255,(byte)(rgb >> 16),(byte)(rgb >> 8),(byte)rgb);
        // Minimise, maximise and close are drawn by Windows over the frame; they take the palette's ink.
        var caption = AppWindow.TitleBar;
        caption.ButtonBackgroundColor = caption.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        caption.ButtonForegroundColor = caption.ButtonHoverForegroundColor = caption.ButtonPressedForegroundColor = ink.Color;
        caption.ButtonInactiveForegroundColor = dim.Color;
        caption.ButtonHoverBackgroundColor = caption.ButtonPressedBackgroundColor = edge.Color;
    }
    /// `a` laid over `b` at `amount`, as an opaque colour.
    private static int Mix(int a, int b, double amount)
    {
        int Channel(int shift) => (int)Math.Round(((a >> shift) & 255) * amount + ((b >> shift) & 255) * (1 - amount));
        return Channel(16) << 16 | Channel(8) << 8 | Channel(0);
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
    /// A button with no fill of its own: it only tints under the pointer, like a toolbar item or a sidebar row.
    private Button Flat(Button button)
    {
        button.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        button.Resources["ButtonBackgroundPointerOver"] = hover; button.Resources["ButtonBackgroundPressed"] = edge;
        button.Resources["ButtonForegroundPointerOver"] = ink; button.Resources["ButtonForegroundPressed"] = ink;
        button.BorderThickness = new Thickness(0); button.CornerRadius = new CornerRadius(6); button.Foreground = ink;
        return button;
    }
    /// A quiet outlined button: the secondary actions on the home page and in cards.
    private Button Bordered(Button button)
    {
        button.Background = surface; button.BorderBrush = edge; button.BorderThickness = new Thickness(1);
        button.CornerRadius = new CornerRadius(8); button.Padding = new Thickness(10,5,12,5);
        return button;
    }
    private Button ActionButton(string name, string glyph, Func<Task> action, bool showLabel = false)
    {
        var button = Button(name,action);
        var icon = new FontIcon { Glyph = glyph, FontSize = 14 };
        // An element has one parent: the row is built only when the label is shown.
        if(showLabel) { var content = Row(icon,new TextBlock { Text = name, FontSize = 13 }); content.Spacing = 6; button.Content = content; }
        else button.Content = icon;
        Flat(button); button.MinWidth = 28; button.MinHeight = 28;
        button.Padding = showLabel ? new Thickness(8,4,8,4) : new Thickness(6,4,6,4);
        AutomationProperties.SetName(button,name); ToolTipService.SetToolTip(button,name);
        return button;
    }
    private void BuildWorkbench()
    {
        ApplySavedTheme(); ApplyTheme(); root.ActualThemeChanged += (_,_) => ApplyTheme();
        Application.Current.Resources["ControlCornerRadius"] = new CornerRadius(6);
        Application.Current.Resources["OverlayCornerRadius"] = new CornerRadius(10);
        // The sidebar and the conversation are cards on the window frame, 6 px from the edge and from each other, as on macOS.
        root.Background = frame; root.Padding = new Thickness(6,0,6,0); root.ColumnSpacing = 6;
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) });
        root.RowDefinitions.Add(new RowDefinition()); root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(28) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(250) });
        root.ColumnDefinitions.Add(new ColumnDefinition());

        // The window's own title bar: the sidebar switch and the project name sit on the frame; the rest of the strip drags the window.
        ExtendsContentIntoTitleBar = true;
        var titleBar = new Grid { ColumnSpacing = 6 };
        titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        titleBar.ColumnDefinitions.Add(new ColumnDefinition());
        titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) }); // Minimise, maximise and close are drawn here by Windows.
        var toggle = ActionButton("切换侧栏","\uE90C",() => { sidebarOpen = !sidebarOpen; LayoutSidebar(); return Task.CompletedTask; });
        toggle.VerticalAlignment = VerticalAlignment.Center; titleBar.Children.Add(toggle);
        windowTitle.FontSize = 13; windowTitle.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; windowTitle.Foreground = ink;
        windowTitle.VerticalAlignment = VerticalAlignment.Center; windowTitle.TextTrimming = TextTrimming.CharacterEllipsis;
        var drag = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        drag.Children.Add(windowTitle); Grid.SetColumn(drag,1); titleBar.Children.Add(drag);
        Grid.SetColumnSpan(titleBar,2); root.Children.Add(titleBar); SetTitleBar(drag);

        railPanel.Background = rail; railPanel.CornerRadius = new CornerRadius(10);
        railPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        railPanel.RowDefinitions.Add(new RowDefinition()); railPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(railPanel,1); root.Children.Add(railPanel);
        sidebar.Padding = new Thickness(8,8,8,2); sidebar.Spacing = 6;
        hosts.ItemsSource = local.Hosts; hosts.MinWidth = 0; hosts.FontSize = 13;
        var switcher = new Grid { ColumnSpacing = 2 };
        switcher.ColumnDefinitions.Add(new ColumnDefinition());
        switcher.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        hosts.BorderThickness=new Thickness(0);hosts.Background=new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        hosts.Padding=new Thickness(8,4,6,4);
        var hostPicker=new Grid {ColumnSpacing=2};hostPicker.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});hostPicker.ColumnDefinitions.Add(new ColumnDefinition());
        hostDot.Margin=new Thickness(8,0,0,0);hostPicker.Children.Add(hostDot);Grid.SetColumn(hosts,1);hostPicker.Children.Add(hosts);switcher.Children.Add(hostPicker);
        connectHost=ActionButton("连接","\uE839",() => ConnectDialogAsync(hosts.SelectedItem as HostProfile));
        hosts.SelectionChanged+=(_,_)=>UpdateHostPicker();
        var tools = Row(connectHost,
            ActionButton("添加主机","\uE710",() => ConnectDialogAsync(null)));
        tools.Spacing = 0; Grid.SetColumn(tools,1); switcher.Children.Add(tools); sidebar.Children.Add(switcher);
        fresh = ActionButton("新建对话","\uE70F",NewConversationAsync);
        fresh.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.N, Modifiers = VirtualKeyModifiers.Control });
        sync = ActionButton("同步历史","\uE72C",RefreshHistoryAsync);
        var find = ActionButton("搜索对话","\uE721",() => {
            search.Visibility = search.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            if(search.Visibility == Visibility.Visible) search.Focus(FocusState.Programmatic); else search.Text = "";
            return Task.CompletedTask;
        });
        var heading = new Grid { Margin = new Thickness(0,4,0,0) };
        heading.Children.Add(new TextBlock { Text = "项目", FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = ink, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8,0,0,0) });
        var listTools = Row(fresh,sync,find); listTools.Spacing = 0; listTools.HorizontalAlignment = HorizontalAlignment.Right; heading.Children.Add(listTools);
        sidebar.Children.Add(heading); search.FontSize = 13; sidebar.Children.Add(search);
        search.TextChanged += (_,_) => RenderHistory();
        At(railPanel,sidebar,0); projects.Padding = new Thickness(8,2,8,8); projects.Spacing = 1;
        At(railPanel,new ScrollViewer { Content = projects },1);
        var footer = new Grid { Margin = new Thickness(8,0,8,0), Padding = new Thickness(0,4,0,4), BorderBrush = edge, BorderThickness = new Thickness(0,1,0,0) };
        archiveToggle = ActionButton("归档","\uE7B8",() => { showArchived = !showArchived; RenderHistory(); return Task.CompletedTask; },true);
        archiveToggle.HorizontalAlignment = HorizontalAlignment.Left; footer.Children.Add(archiveToggle);
        var gear = ActionButton("设置","\uE713",SettingsAsync); gear.HorizontalAlignment = HorizontalAlignment.Right; footer.Children.Add(gear);
        At(railPanel,footer,2);

        // The strip under the cards: connection, working directory, and the latest notice.
        var statusBar = new Grid { ColumnSpacing = 8, Padding = new Thickness(8,0,8,0) };
        foreach(var width in new[] { GridLength.Auto, GridLength.Auto, GridLength.Auto, new GridLength(1,GridUnitType.Star) }) statusBar.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        connection.FontSize = subtitle.FontSize = 12; connection.Foreground = subtitle.Foreground = status.Foreground = muted;
        subtitle.TextTrimming = status.TextTrimming = TextTrimming.CharacterEllipsis; status.TextWrapping = TextWrapping.NoWrap;
        subtitle.Margin = new Thickness(12,0,0,0); status.HorizontalAlignment = HorizontalAlignment.Right;
        // The strip already says whether the server is connected: a notice that only repeats it is not shown twice.
        status.RegisterPropertyChangedCallback(TextBlock.TextProperty,(_,_) => { ToolTipService.SetToolTip(status,status.Text.Length > 0 ? status.Text : null); status.Opacity = status.Text == connection.Text ? 0 : 1; });
        int column = 0;
        foreach(FrameworkElement item in new FrameworkElement[] { stateDot, connection, subtitle, status }) { item.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(item,column++); statusBar.Children.Add(item); }
        Grid.SetRow(statusBar,2); Grid.SetColumnSpan(statusBar,2); root.Children.Add(statusBar);

        var area = Rows(GridLength.Auto,new GridLength(1,GridUnitType.Star),GridLength.Auto);
        BuildSplit(area);
        var bar = new Grid { Padding = new Thickness(16,4,6,4), ColumnSpacing = 10, MinHeight = 40 };
        bar.ColumnDefinitions.Add(new ColumnDefinition()); bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        title.FontSize = 13; title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; title.Foreground = ink;
        title.TextTrimming = TextTrimming.CharacterEllipsis; title.VerticalAlignment = VerticalAlignment.Center; bar.Children.Add(title);
        var update = ActionButton("检查更新","\uE895",()=>CheckUpdatesAsync(true),true);
        At(area,bar,0);
        scroll.HorizontalAlignment = HorizontalAlignment.Stretch;
        scroll.HorizontalContentAlignment = HorizontalAlignment.Stretch; scroll.HorizontalScrollMode = ScrollMode.Disabled;
        scroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        bool followReply = true;
        scroll.ViewChanged += (_,_) => followReply = scroll.ScrollableHeight-scroll.VerticalOffset < 48;
        messages.SizeChanged += (_,e) => { if(followReply && e.NewSize.Height > e.PreviousSize.Height)
            DispatcherQueue.TryEnqueue(()=>scroll.ChangeView(null,scroll.ScrollableHeight,null,true)); };
        // The conversation column is 680 wide and centred, whatever the width of the pane.
        // A grid as the scrolled content takes the pane's width and centres the column inside it.
        messages.HorizontalAlignment = HorizontalAlignment.Stretch; messages.MaxWidth = 728; messages.Padding = new Thickness(24,8,24,16); messages.Spacing = 14;
        var centred = new Grid(); centred.Children.Add(messages);
        scroll.Content = centred; At(area,scroll,1);
        home.Margin = new Thickness(24,40,24,16);
        home.VerticalAlignment = VerticalAlignment.Top;
        homeTitle.FontSize = 22; homeTitle.Foreground = ink; homeTitle.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;
        homeHint.Foreground = muted; homeHint.FontSize = 13;
        homeHint.TextWrapping = TextWrapping.Wrap;
        home.Children.Add(homeTitle); home.Children.Add(homeHint); home.Children.Add(healthPanel); home.Children.Add(homeActions); home.Children.Add(homeRecent);
        At(area,home,1);
        var composeArea = new StackPanel { MaxWidth = 680, Spacing = 8, Margin = new Thickness(24,4,24,12) };
        composer.Child = composeArea; At(area,composer,2);
        composeArea.Children.Add(permissionPanel); composeArea.Children.Add(queuePanel);
        var input = new StackPanel { Spacing = 6 }; prompt.MinHeight = 44;
        prompt.BorderThickness = new Thickness(0); prompt.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        foreach(var key in new[]{"TextControlBackground","TextControlBackgroundPointerOver","TextControlBackgroundFocused","TextControlBorderBrush","TextControlBorderBrushPointerOver","TextControlBorderBrushFocused"})
            prompt.Resources[key]=new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        prompt.Resources["TextControlBorderThemeThicknessFocused"]=new Thickness(0);
        prompt.Padding=new Thickness(2,3,2,3);
        prompt.FontSize=14;prompt.GotFocus+=(_,_)=>inputCard.BorderBrush=dim;
        prompt.LostFocus+=(_,_)=>inputCard.BorderBrush=edge;
        input.Children.Add(prompt);
        var toolbar = new Grid(); toolbar.ColumnDefinitions.Add(new ColumnDefinition()); toolbar.ColumnDefinitions.Add(new ColumnDefinition {Width=GridLength.Auto});

        commandMenu=PickerAction(false);modelMenu=PickerAction(true);UpdatePickerTitle();
        var left=Row(ActionButton("附件","\uE710",UploadAsync),commandMenu,PermissionPicker());left.Spacing=2;toolbar.Children.Add(left);
        // One button, as on macOS: it sends, and while Claude replies it stops. Typing during a reply adds "send now" and "queue".
        send = Primary(ActionButton("发送","\uE74A",()=>busy ? StopAsync() : SendAsync())); send.Content = sendIcon;
        send.CornerRadius = new CornerRadius(15); send.Width = send.Height = 30; send.Padding = new Thickness(0);
        steer = ActionButton("立即发送 · Ctrl+Enter","\uE724",()=>SendAsync(true));
        enqueue = ActionButton("加入队列 · Enter","\uE8FD",()=>SendAsync());
        contextMeter.Foreground = muted; ToolTipService.SetToolTip(contextMeter,"上下文");
        var actions = Row(modelMenu,contextMeter,steer,enqueue,send); actions.Spacing = 4; Grid.SetColumn(actions,1); toolbar.Children.Add(actions); input.Children.Add(toolbar);
        inputCard.Background=surface;inputCard.BorderBrush=edge;inputCard.BorderThickness=new Thickness(1);inputCard.CornerRadius=new CornerRadius(12);inputCard.Padding=new Thickness(10,8,8,6);inputCard.Child=input;composeArea.Children.Add(inputCard);
        files = ActionButton("远端文件","\uE8B7",BrowseAsync);
        project = ActionButton("工作目录","\uE838",() => Task.CompletedTask);
        directory.Width = 230; directory.Header = "远端工作目录";
        project.Flyout = new Flyout { Content = directory };
        var editors = ActionButton("切换文件编辑器","\uE8A5",()=>{ if(editorTabs.TabItems.Count==0)return BrowseAsync(); showEditor=!showEditor;LayoutSplit();return Task.CompletedTask; });
        var more=ActionButton("更多操作","\uE712",()=>Task.CompletedTask);
        var tunnels=ActionButton("端口转发","\uE968",()=>Task.CompletedTask,true);
        var tunnelFlyout=new Flyout { Content=TunnelPanel() }; tunnelFlyout.Opening+=(_,_)=>RenderTunnels(); tunnels.Flyout=tunnelFlyout;
        var changes=ActionButton("Git 变更","\uE8F1",ChangesAsync,true);
        var findInFiles=ActionButton("在文件中搜索","\uE721",SearchFilesAsync,true);
        var quick=ActionButton("快速打开文件（Ctrl+P）","\uE8E5",QuickOpenAsync,true);
        more.Flyout=new Flyout { Content=new StackPanel {Children={ActionButton("状态：用量、MCP、插件、Agent","\uE9D9",StatusAsync,true),ActionButton("对话文本：跨消息选择和复制","\uE8B3",TranscriptAsync,true),changes,findInFiles,quick,project,editors,tunnels,update}} };
        var quickKey=new KeyboardAccelerator { Key=VirtualKey.P, Modifiers=VirtualKeyModifiers.Control };
        quickKey.Invoked+=async (_,e)=>{ e.Handled=true; await RunAsync(QuickOpenAsync); };
        var findKey=new KeyboardAccelerator { Key=VirtualKey.F, Modifiers=VirtualKeyModifiers.Control|VirtualKeyModifiers.Shift };
        findKey.Invoked+=async (_,e)=>{ e.Handled=true; await RunAsync(SearchFilesAsync); };
        root.KeyboardAccelerators.Add(quickKey); root.KeyboardAccelerators.Add(findKey);
        restartButton=ActionButton("重启更新","\uE895",InstallUpdateAsync,true);
        restartButton.Visibility=Visibility.Collapsed;
        var headerActions = Row(restartButton,files,more);
        headerActions.Spacing = 2; Grid.SetColumn(headerActions,1); bar.Children.Add(headerActions);
        directory.TextChanged += (_,_) => UpdateSubtitle();
        prompt.TextChanged += (_,_) => UpdateActions();
        // Enter sends and Shift+Enter breaks the line, as on macOS; Ctrl+Enter hands the message to the running reply.
        prompt.TextCompositionStarted += (_,_) => composing = true; prompt.TextCompositionEnded += (_,_) => composing = false;
        prompt.PreviewKeyDown += async (_,e) =>
        {
            if(e.Key != VirtualKey.Enter || composing || Held(VirtualKey.Shift)) return;
            e.Handled = true; bool now = Held(VirtualKey.Control);
            if(agent?.Connected == true && !string.IsNullOrWhiteSpace(prompt.Text)) await RunAsync(()=>SendAsync(now));
        };
        // Esc stops the reply wherever the focus is. An open menu or dialog takes the key first and only closes.
        root.KeyDown += async (_,e) => { if(e.Key != VirtualKey.Escape || !busy || stopping) return; e.Handled = true; await RunAsync(StopAsync); };
        root.SizeChanged += (_,e) => { if((e.PreviousSize.Width >= 720) != (e.NewSize.Width >= 720) || e.PreviousSize.Width == 0) { sidebarOpen = e.NewSize.Width >= 720; LayoutSidebar(); } };
        Content = root; RenderHistory();
    }
    private void LayoutSidebar()
    {
        railPanel.Visibility = sidebarOpen ? Visibility.Visible : Visibility.Collapsed;
        root.ColumnDefinitions[0].Width = new GridLength(sidebarOpen ? 250 : 0); root.ColumnSpacing = sidebarOpen ? 6 : 0;
    }
    private bool showArchived;
    private string HostKeyOrEmpty => host == null ? "" : LocalState.HostKey(host);
    /// A conversation the server has not given an id yet is only ever itself.
    private bool IsCurrent(Conversation c) => conversation is not null && c.Directory == conversation.Directory &&
        ((c.SessionId ?? c.Reference) is { } id ? id == (conversation.SessionId ?? conversation.Reference) : ReferenceEquals(c, conversation));

    private TextBlock SectionLabel(string text) => new() { Text = text, Foreground = muted, FontSize = 12, Margin = new Thickness(8,8,0,2) };
    private void RenderHistory()
    {
        projects.Children.Clear();
        var list = Sessions.Visible(history,local,HostKeyOrEmpty,search.Text);
        var archive = Sessions.Visible(history,local,HostKeyOrEmpty,search.Text,true);
        if(parked.Count > 0)
        {
            // Conversations left running, newest first: one click brings each back as it was.
            projects.Children.Add(SectionLabel("后台对话"));
            foreach(var waiting in parked.Values.Reverse()) projects.Children.Add(ParkedRow(waiting));
        }
        var pinned = list.Where(entry => entry.Pinned).ToList();
        if(pinned.Count > 0)
        {
            projects.Children.Add(SectionLabel("已固定"));
            foreach(var entry in pinned) projects.Children.Add(ConversationRow(entry,"\uE718"));
        }
        if(list.Count == 0) projects.Children.Add(SectionLabel(search.Text.Length > 0 ? "没有找到匹配的对话" : "暂无历史对话"));
        if(history.Count == 0 && host == null) projects.Children.Add(SectionLabel("连接后自动同步这台机器的对话"));
        int index = 0;
        foreach(var group in Sessions.Projects(list))
        {
            var items = new StackPanel { Spacing = 1 };
            var path = group.Directory; var groupId = HostKeyOrEmpty + "|" + path;
            foreach(var entry in group.Entries) items.Children.Add(ConversationRow(entry,null));
            var folder = ShortDirectory(path);
            bool expanded = search.Text.Length>0 || (openGroups.TryGetValue(groupId,out var remembered) ? remembered : index < 2 || group.Entries.Any(entry=>IsCurrent(entry.Conversation)));
            index++;
            var arrow = new FontIcon { FontSize=9, Foreground=muted, Width=12 };
            void SetExpanded(bool value) { expanded=value;arrow.Glyph=value?"\uE70D":"\uE76C";items.Visibility=value?Visibility.Visible:Visibility.Collapsed; }
            var section = Flat(Button(folder ?? path,()=> { SetExpanded(!expanded); openGroups[groupId]=expanded;return Task.CompletedTask; }));
            var label = Row(arrow,new FontIcon {Glyph="\uE8B7",FontSize=14,Foreground=muted},new TextBlock {Text=string.IsNullOrEmpty(folder)?path:folder,FontSize=13,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,TextTrimming=TextTrimming.CharacterEllipsis});
            label.Spacing = 6; section.Content = label; section.Padding = new Thickness(6,5,8,5);
            section.HorizontalContentAlignment=HorizontalAlignment.Left;section.HorizontalAlignment=HorizontalAlignment.Stretch;
            AutomationProperties.SetName(section,path);ToolTipService.SetToolTip(section,path);items.Margin=new Thickness(14,0,0,0);
            var menu=new MenuFlyout();
            menu.Items.Add(MenuItem("在此目录新建对话","\uE710",async () => { directory.Text = path; await NewConversationAsync(); }));
            menu.Items.Add(MenuItem("把此项目的历史移到废纸篓…","\uE74D",() => TrashProjectAsync(path)));
            section.ContextFlyout=menu;
            var add = ActionButton("在此目录新建对话","\uE710",async () => { directory.Text = path; await NewConversationAsync(); });
            var header = new Grid(); header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.Children.Add(section); Grid.SetColumn(add,1); header.Children.Add(add);
            SetExpanded(expanded);projects.Children.Add(header);projects.Children.Add(items);
        }
        archiveToggle.Visibility = archive.Count > 0 || showArchived ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(archiveToggle,showArchived ? "隐藏已归档的对话" : $"显示已归档的对话（{archive.Count}）");
        if(showArchived)
        {
            projects.Children.Add(SectionLabel(archive.Count > 0 ? $"已归档（{archive.Count}）" : "没有已归档的对话"));
            foreach(var entry in archive) projects.Children.Add(ConversationRow(entry,"\uE7B8"));
        }
        RenderRecent();
    }
    /// The home page lists the newest conversations of this server; the sidebar holds the full tree.
    private void RenderRecent()
    {
        homeRecent.Children.Clear();
        var list = agent?.Connected == true ? Sessions.Visible(history,local,HostKeyOrEmpty,"").Take(6).ToList() : [];
        homeRecent.Visibility = list.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if(list.Count == 0) return;
        homeRecent.Children.Add(new TextBlock { Text = "最近对话", FontSize = 12, Foreground = muted, Margin = new Thickness(0,12,0,4) });
        foreach(var entry in list)
        {
            var c = entry.Conversation;
            var row = Flat(Button(c.Name,() => SelectAsync(c)));
            var text = new StackPanel { Spacing = 2 };
            text.Children.Add(new TextBlock { Text = c.Name, FontSize = 13, Foreground = ink, TextTrimming = TextTrimming.CharacterEllipsis });
            text.Children.Add(new TextBlock { Text = c.Directory, FontSize = 12, Foreground = muted, TextTrimming = TextTrimming.CharacterEllipsis });
            var line = new Grid { ColumnSpacing = 12 }; line.ColumnDefinitions.Add(new ColumnDefinition()); line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var chevron = new FontIcon { Glyph = "\uE76C", FontSize = 10, Foreground = dim, VerticalAlignment = VerticalAlignment.Center };
            line.Children.Add(text); Grid.SetColumn(chevron,1); line.Children.Add(chevron);
            row.Content = line; row.Padding = new Thickness(10,6,10,6);
            row.HorizontalAlignment = HorizontalAlignment.Stretch; row.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            homeRecent.Children.Add(row);
        }
    }
    private void RefreshWorkbench()
    {
        bool online = agent?.Connected == true, empty = messages.Children.Count == 0 && conversation == null;
        title.Text = conversation?.Name ?? (host == null ? "claude-mirror" : "新对话");
        UpdateSubtitle();UpdatePickerTitle();UpdateHostPicker();
        composer.Visibility = host != null ? Visibility.Visible : Visibility.Collapsed;
        hostDot.Background=stateDot.Background=online?sage:dim;connection.Text=online?"已连接":"未连接";status.Opacity=status.Text==connection.Text?0:1;
        fresh.IsEnabled = online; sync.IsEnabled = online;
        files.Visibility = project.Visibility = host == null ? Visibility.Collapsed : Visibility.Visible;
        files.IsEnabled = online; project.IsEnabled = online && !busy;
        home.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        scroll.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        if(empty) {
            homeTitle.Text = online ? "新对话" : host == null ? "开始使用" : agent?.SshConnected == true ? "设置服务器" : "连接服务器";
            homeHint.Text = online ? host!.Name : host == null
                ? "在这台电脑上使用服务器里的 Claude Code：代码和 Claude 都在服务器上运行，这里负责对话和审批。\n\n1. 准备一台能用 SSH 登录的 Linux 或 macOS 服务器\n2. 添加服务器：填写地址和密码\n3. 自动检查环境：缺少 Claude Code 或 Node.js 时一键安装，然后登录 Claude"
                : agent?.SshConnected == true ? "SSH 已连接，按下面的提示完成设置。" : "使用服务器上的 Claude Code。";
            homeActions.Children.Clear();
            if(!online) {
                var add = Primary(ActionButton(host == null ? "添加服务器" : "重新连接","\uE710",()=>ConnectDialogAsync(host),true));
                add.HorizontalAlignment=HorizontalAlignment.Left;add.Padding=new Thickness(12,6,14,6);
                if(agent?.SshConnected != true) homeActions.Children.Add(add);
                if(host == null) homeActions.Children.Add(new HyperlinkButton { Content = "没有服务器？查看入门指南", NavigateUri = GettingStartedUrl });
            } else {
                var remote = agent!;
                homeActions.Children.Add(Row(
                    Bordered(ActionButton("在主目录开始对话","\uE80F",()=>{directory.Text=remote.Home;prompt.Focus(FocusState.Programmatic);return Task.CompletedTask;},true)),
                    Bordered(ActionButton("打开项目目录","\uE838",BrowseAsync,true))));
            }
        }
        RenderRecent();
        UpdateActions();
    }
    private void UpdateActions()
    {
        bool online = agent?.Connected == true, typed = !string.IsNullOrWhiteSpace(prompt.Text);
        string name = busy ? (stopping ? "正在停止…" : "停止 · Esc") : "发送 · Enter";
        sendIcon.Glyph = busy ? "\uE71A" : "\uE74A";
        send.IsEnabled = online && (busy ? !stopping : typed);
        AutomationProperties.SetName(send, name); ToolTipService.SetToolTip(send, name);
        steer.Visibility = enqueue.Visibility = busy && typed && online ? Visibility.Visible : Visibility.Collapsed;
        contextMeter.Text = Turn.Context(lastState) ?? "";
        contextMeter.Visibility = contextMeter.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
}
