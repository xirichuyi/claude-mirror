using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    private MessageView AddMessage(string text, bool user = false)
    {
        var view = new MessageView(this,user,text);
        messages.Children.Add(view.Container);
        if(home.Visibility == Visibility.Visible) RefreshWorkbench();
        return view;
    }

    private static void Copy(string text) { var data=new DataPackage(); data.SetText(text); Clipboard.SetContent(data); }
    private static readonly FontFamily Mono = new("Cascadia Mono, Consolas");

    /// One message. A reply keeps one view per block and only rebuilds the blocks whose content changed,
    /// so a streaming chunk does not reset open tool cards or code scroll positions elsewhere in the reply.
    private sealed class MessageView
    {
        private sealed record Part(string Key, string Json, FrameworkElement View, ToolCard? Tool);
        private readonly MainWindow window;
        private readonly StackPanel body = new() { Spacing = 10 };
        private readonly StackPanel footer = new() { Orientation = Orientation.Horizontal, Spacing = 4, Visibility = Visibility.Collapsed };
        private readonly TextBlock error = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Visibility = Visibility.Collapsed };
        private readonly List<Part> parts = [];
        private readonly bool user;
        private string? previous, checkpoint;
        private string plain = "";
        public Border Container { get; }
        public bool User => user;
        /// The message's text without tool calls or thinking.
        public string Plain => plain;

        public MessageView(MainWindow window,bool user,string text)
        {
            this.window = window; this.user = user; plain = text;
            error.Foreground = window.danger;
            var stack = new StackPanel { Spacing=6 };
            stack.Children.Add(body); stack.Children.Add(error); stack.Children.Add(footer);
            Container = new Border
            {
                Child=stack, HorizontalAlignment=user?HorizontalAlignment.Right:HorizontalAlignment.Stretch,
                Padding=user?new Thickness(12,8,12,8):new Thickness(0), CornerRadius=new CornerRadius(12), Background=user?window.bubble:null,
                MaxWidth=user?540:double.PositiveInfinity
            };
            Container.Tag = this;
            if(text.Length>0) body.Children.Add(Label(text,14,user?window.ink:window.muted));
        }

        private static TextBlock Label(string text,double size,Brush color) => new() { Text=text,FontSize=size,Foreground=color,TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true };
        public void SetError(string text) { error.Text=text; error.Visibility=Visibility.Visible; }

        /// `live` is true while the reply is still streaming: the last code block then follows its newest lines.
        public void Show(JsonNode? message, bool live = false)
        {
            string? current=message?.ToJsonString() + (live ? "+" : "");
            if(current == previous) return;
            previous=current;
            error.Visibility=Visibility.Collapsed;
            if(Presentation.Text(message?["error"]) is { } failure) SetError(failure);
            var blocks=message?["blocks"] as JsonArray ?? message?["content"] as JsonArray;
            if(user || blocks is not { Count: > 0 })
            {
                plain=Protocol.MessageText(message);
                body.Children.Clear(); parts.Clear();
                if(user) body.Children.Add(Label(plain,14,window.ink));
                else if(plain.Length>0) body.Children.Add(window.MarkdownView(plain,null,live));
                else if(live) body.Children.Add(Label("正在回复…",14,window.muted));
            }
            else
            {
                if(parts.Count==0) body.Children.Clear();
                plain=string.Join("\n\n",blocks.Where(b=>Presentation.Text(b?["type"])=="text").Select(b=>Presentation.Text(b?["text"])));
                for(int i=0;i<blocks.Count;i++)
                {
                    var block=blocks[i]!; var type=Presentation.Text(block["type"]) ?? "";
                    var key=type+":"+(Presentation.Text(block["id"]) ?? i.ToString());
                    bool last=live && i==blocks.Count-1;
                    var json=block.ToJsonString()+(last?"+":"");
                    if(i<parts.Count && parts[i].Key==key)
                    {
                        if(parts[i].Json==json) continue;
                        if(parts[i].Tool is { } card && card.Matches(block)) { card.Update(block); parts[i]=parts[i] with { Json=json }; continue; }
                        var replaced=Build(type,block,last);
                        body.Children[i]=replaced.View; parts[i]=replaced with { Key=key, Json=json };
                        continue;
                    }
                    while(parts.Count>i) { parts.RemoveAt(parts.Count-1); body.Children.RemoveAt(body.Children.Count-1); }
                    var part=Build(type,block,last) with { Key=key, Json=json };
                    parts.Add(part); body.Children.Add(part.View);
                }
                while(parts.Count>blocks.Count) { parts.RemoveAt(parts.Count-1); body.Children.RemoveAt(body.Children.Count-1); }
            }
            checkpoint=Presentation.Text(message?["checkpointId"]);
            ShowFooter(live, message?["interrupted"] is JsonValue stopped && stopped.TryGetValue<bool>(out var yes) && yes);
        }

        private Part Build(string type,JsonNode block,bool live)
        {
            switch(type)
            {
                case "tool" or "tool_use":
                    var card=new ToolCard(window,block);
                    return new("", "", card.View, card);
                case "thinking":
                    var text=Presentation.Text(block["text"]) ?? Presentation.Text(block["thinking"]) ?? "";
                    return new("", "", window.Disclosure("\uE9CE","思考过程",Presentation.FirstLine(text,70),null,false,()=>Label(text,13,window.muted)), null);
                case "user":
                    // A message sent while this reply was running, shown where Claude read it.
                    bool cancelled=block["cancelled"]?.GetValue<bool>()==true, pending=block["pending"]?.GetValue<bool>()==true;
                    var said=Label(Presentation.Text(block["text"]) ?? "",14,window.ink);
                    if(cancelled) said.TextDecorations=Windows.UI.Text.TextDecorations.Strikethrough;
                    var steered=new StackPanel { Spacing=3, HorizontalAlignment=HorizontalAlignment.Right, MaxWidth=540 };
                    steered.Children.Add(new Border { Child=said, Background=window.bubble, CornerRadius=new CornerRadius(12), Padding=new Thickness(12,8,12,8), Opacity=cancelled||pending?.6:1, HorizontalAlignment=HorizontalAlignment.Right });
                    if(cancelled||pending) { var note=Label(cancelled?"未送达":"等待读取…",12,window.muted); note.HorizontalAlignment=HorizontalAlignment.Right; steered.Children.Add(note); }
                    return new("", "", steered, null);
                case "notice":
                    return new("", "", Label(Presentation.Text(block["text"]) ?? "",13,Presentation.Text(block["level"])=="error"?window.danger:window.muted), null);
                default:
                    var content=Presentation.Text(block["text"]) ?? "";
                    return new("", "", Presentation.Text(block["format"])=="command" ? window.CodePanel(content,"",live,"命令输出") : window.MarkdownView(content,null,live), null);
            }
        }

        private void ShowFooter(bool live,bool interrupted)
        {
            footer.Children.Clear();
            footer.Visibility=user || live || plain.Length==0 && checkpoint is null ? Visibility.Collapsed : Visibility.Visible;
            if(footer.Visibility==Visibility.Collapsed) return;
            if(interrupted) footer.Children.Add(new TextBlock { Text="已停止",FontSize=12,Foreground=window.muted,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(0,0,6,0) });
            if(plain.Length>0) footer.Children.Add(window.ActionButton("复制回复","\uE8C8",()=>{ Copy(plain); return Task.CompletedTask; }));
            if(plain.Length>0) footer.Children.Add(window.ActionButton("跨消息选择文本","\uE8B3",window.TranscriptAsync));
            if(checkpoint is { } id) footer.Children.Add(window.ActionButton("回退文件改动","\uE7A7",()=>window.RewindAsync(id)));
        }
    }

    /// A one-line row that opens to show details: tool calls and thinking share it.
    private Border Disclosure(string glyph,string title,string? subject,FrameworkElement? status,bool open,Func<FrameworkElement> content)
    {
        var chevron=new FontIcon { Glyph=open?"\uE70D":"\uE76C",FontSize=10,Foreground=muted,VerticalAlignment=VerticalAlignment.Center };
        var head=new Grid { ColumnSpacing=7 };
        foreach(var width in new[] { GridLength.Auto,GridLength.Auto,GridLength.Auto,new GridLength(1,GridUnitType.Star),GridLength.Auto }) head.ColumnDefinitions.Add(new ColumnDefinition { Width=width });
        var icon=new FontIcon { Glyph=glyph,FontSize=13,Foreground=muted,VerticalAlignment=VerticalAlignment.Center };
        var name=new TextBlock { Text=title,FontSize=12,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,Foreground=ink,VerticalAlignment=VerticalAlignment.Center };
        var detail=new TextBlock { Text=subject ?? "",FontSize=12,Foreground=muted,TextTrimming=TextTrimming.CharacterEllipsis,TextWrapping=TextWrapping.NoWrap,VerticalAlignment=VerticalAlignment.Center };
        Grid.SetColumn(icon,1); Grid.SetColumn(name,2); Grid.SetColumn(detail,3);
        head.Children.Add(chevron); head.Children.Add(icon); head.Children.Add(name); head.Children.Add(detail);
        if(status is not null) { Grid.SetColumn(status,4); head.Children.Add(status); }
        // A quiet line in the reply, not a card: only what it opens is framed.
        var toggle=Flat(new Button { Content=head,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch,Padding=new Thickness(4,3,8,3) });
        AutomationProperties.SetName(toggle,subject is null ? title : title+" "+subject);
        var holder=new ContentControl { HorizontalContentAlignment=HorizontalAlignment.Stretch,Margin=new Thickness(20,4,0,6),Visibility=Visibility.Collapsed };
        void Set(bool show)
        {
            if(show && holder.Content is null) holder.Content=content(); // Built on first open: most cards are never opened.
            holder.Visibility=show?Visibility.Visible:Visibility.Collapsed; chevron.Glyph=show?"\uE70D":"\uE76C";
        }
        toggle.Click+=(_,_)=>Set(holder.Visibility==Visibility.Collapsed);
        if(open) Set(true);
        var panel=new StackPanel(); panel.Children.Add(toggle); panel.Children.Add(holder);
        return new Border { Child=panel,Margin=new Thickness(-4,0,0,0),Tag=holder };
    }

    /// A tool call: what it is and on which file, whether it is running or failed, and its input and output when opened.
    private sealed class ToolCard
    {
        private readonly MainWindow window;
        private readonly Grid status=new() { VerticalAlignment=VerticalAlignment.Center };
        private readonly string key;
        private JsonNode block;
        public Border View { get; }

        public ToolCard(MainWindow window,JsonNode block)
        {
            this.window=window; this.block=block; key=Shape(block);
            View=Make();
        }

        private static string Shape(JsonNode block) => Presentation.Text(block["name"])+"\n"+block["input"]?.ToJsonString();

        public bool Matches(JsonNode next) => Shape(next)==key;

        /// Status, output and sub-agent steps change while a tool runs; the row itself stays so it does not close under the reader.
        public void Update(JsonNode next)
        {
            block=next;
            ShowStatus();
            if(View.Tag is ContentControl { Content: not null } holder) holder.Content=Details();
        }

        private Border Make()
        {
            var tool=new ToolPresentation(Presentation.Text(block["name"]),block["input"]);
            var subject=tool.File is { } file ? (tool.Subject is { } extra ? ShortDirectory(file)+" · "+extra : ShortDirectory(file)) : tool.Subject;
            ShowStatus();
            return window.Disclosure(Glyph(Presentation.Text(block["name"])),tool.Title,subject,status,tool.StartsOpen,Details);
        }

        private static string Glyph(string? name) => name switch
        {
            "Bash" => "\uE756", "Read" => "\uE8A5", "Write" or "Edit" or "MultiEdit" or "NotebookEdit" => "\uE70F", "Grep" or "Glob" or "WebSearch" => "\uE721",
            "LS" => "\uE8B7", "WebFetch" => "\uE774", "TodoWrite" => "\uE9D5", "Task" or "Agent" => "\uE99A", "AskUserQuestion" => "\uE897", _ => "\uE90F"
        };

        private void ShowStatus()
        {
            status.Children.Clear();
            switch(Presentation.Text(block["status"]))
            {
                case "running": status.Children.Add(new ProgressRing { IsActive=true,Width=14,Height=14,Foreground=window.amber }); AutomationProperties.SetName(status,"运行中"); break;
                case "error": status.Children.Add(new TextBlock { Text="失败",FontSize=12,Foreground=window.danger }); break;
                case "stopped": status.Children.Add(new TextBlock { Text="已停止",FontSize=12,Foreground=window.muted }); break;
                case "done": status.Children.Add(new FontIcon { Glyph="\uE73E",FontSize=12,Foreground=window.sage }); AutomationProperties.SetName(status,"完成"); break;
            }
        }

        private FrameworkElement Details()
        {
            var tool=new ToolPresentation(Presentation.Text(block["name"]),block["input"]);
            var panel=new StackPanel { Spacing=8 };
            if(tool.File is { } file)
            {
                var open=new HyperlinkButton { Content=file,Padding=new Thickness(0),FontSize=12 };
                open.Click+=async (_,_)=>await window.RunAsync(()=>window.PreviewAsync(file));
                panel.Children.Add(open);
            }
            switch(tool.Body)
            {
                case ToolBodyKind.Command: panel.Children.Add(window.CodePanel(tool.Text,"bash",false,"命令")); break;
                case ToolBodyKind.Code: panel.Children.Add(window.CodePanel(tool.Text,Path.GetExtension(tool.File ?? "").TrimStart('.'),false,tool.File is null?"内容":null)); break;
                case ToolBodyKind.Diff: panel.Children.Add(window.DiffPanel(tool.Diff)); break;
                case ToolBodyKind.Markdown: panel.Children.Add(window.MarkdownView(tool.Text)); break;
                case ToolBodyKind.Todos:
                    foreach(var todo in tool.Todos)
                    {
                        bool done=todo.Status=="completed", active=todo.Status=="in_progress";
                        var row=new StackPanel { Orientation=Orientation.Horizontal,Spacing=8 };
                        row.Children.Add(new FontIcon { Glyph=done?"\uE73A":active?"\uE768":"\uE739",FontSize=13,Foreground=done?window.sage:active?window.amber:window.muted,VerticalAlignment=VerticalAlignment.Top,Margin=new Thickness(0,3,0,0) });
                        row.Children.Add(new TextBlock { Text=todo.Text,FontSize=13,Foreground=done?window.muted:window.ink,TextWrapping=TextWrapping.Wrap,TextDecorations=done?Windows.UI.Text.TextDecorations.Strikethrough:Windows.UI.Text.TextDecorations.None,MaxWidth=560 });
                        panel.Children.Add(row);
                    }
                    break;
            }
            foreach(var child in block["children"] as JsonArray ?? [])
            {
                var step=new ToolPresentation(Presentation.Text(child?["name"]),child?["input"]);
                var state=Presentation.Text(child?["status"]);
                var line=new TextBlock { FontSize=12,TextTrimming=TextTrimming.CharacterEllipsis,TextWrapping=TextWrapping.NoWrap,Foreground=state=="error"?window.danger:state=="running"?window.amber:window.muted };
                line.Text=step.Title+"  "+(step.File is { } path ? ShortDirectory(path) : step.Subject ?? "");
                panel.Children.Add(line);
            }
            bool failed=Presentation.Text(block["status"])=="error";
            var output=Presentation.Output(block["output"]);
            if(output.Length>0 && (!tool.HidesOutput || failed))
                panel.Children.Add(window.CodePanel(output.Length>20000 ? output[..20000]+"\n…（输出过长，其余已省略）" : output,"",false,failed?"错误输出":"输出"));
            if(panel.Children.Count==0) panel.Children.Add(new TextBlock { Text=Presentation.Text(block["status"])=="running"?"正在运行…":"没有输出",FontSize=12,Foreground=window.muted });
            return panel;
        }
    }

    private const int DiffRowLimit = 400;
    /// Added and removed lines on tinted rows; long lines scroll sideways together.
    private FrameworkElement DiffPanel(IReadOnlyList<DiffRow> rows)
    {
        var lines=new StackPanel();
        foreach(var row in rows.Take(DiffRowLimit))
        {
            var mark=row.Kind switch { DiffKind.Added=>"+",DiffKind.Removed=>"-",_=>" " };
            lines.Children.Add(new Border
            {
                Background=row.Kind switch { DiffKind.Added=>added,DiffKind.Removed=>removed,_=>null },Padding=new Thickness(8,1,12,1),
                Child=new TextBlock { Text=mark+" "+row.Text,FontFamily=Mono,FontSize=13,Foreground=row.Kind==DiffKind.Hunk?muted:ink,TextWrapping=TextWrapping.NoWrap,IsTextSelectionEnabled=true }
            });
        }
        if(rows.Count>DiffRowLimit) lines.Children.Add(new TextBlock { Text=$"还有 {rows.Count-DiffRowLimit} 行未显示",FontSize=12,Foreground=muted,Margin=new Thickness(8,6,8,2) });
        if(rows.Count==0) lines.Children.Add(new TextBlock { Text="没有改动",FontSize=12,Foreground=muted,Margin=new Thickness(8,4,8,4) });
        var box=new ScrollViewer { Content=lines,MaxHeight=CodeHeightLimit,HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollMode=ScrollMode.Auto,VerticalScrollBarVisibility=ScrollBarVisibility.Auto };
        return new Border { Child=box,BorderBrush=edge,BorderThickness=new Thickness(1),CornerRadius=new CornerRadius(8),Background=canvas,Padding=new Thickness(0,6,0,6) };
    }
}
