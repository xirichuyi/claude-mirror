using Markdig;
using Markdig.Extensions.Tables;
using Markdig.Extensions.TaskLists;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using System.Text.RegularExpressions;
using Windows.ApplicationModel.DataTransfer;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    private static readonly MarkdownPipeline MarkdownOptions = new MarkdownPipelineBuilder()
        .UsePipeTables().UseTaskLists().UseEmphasisExtras().UseAutoLinks().DisableHtml().Build();

    private StackPanel MarkdownView(string source,string? basePath=null,bool follow=false) => RenderBlocks(Markdown.Parse(source, MarkdownOptions),basePath ?? directory.Text,follow);

    private StackPanel RenderBlocks(ContainerBlock blocks,string basePath,bool follow=false)
    {
        var panel = new StackPanel { Spacing = 8 };
        foreach (var block in blocks)
        {
            switch (block)
            {
                case CodeBlock code:
                    panel.Children.Add(CodePanel(code.Lines.ToString(), (code as FencedCodeBlock)?.Info ?? "", follow && ReferenceEquals(block, blocks.LastChild)));
                    break;
                case LeafBlock { Inline: { } inline }:
                    var text = new TextBlock { Foreground = ink, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = 14, LineHeight = 22 };
                    if (block is HeadingBlock heading)
                    {
                        text.FontSize = heading.Level switch { 1 => 20, 2 => 17, 3 => 15, _ => 14 }; text.LineHeight = 0;
                        text.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
                    }
                    AddInlines(text.Inlines, inline,basePath);
                    panel.Children.Add(text);
                    break;
                case QuoteBlock quote:
                    panel.Children.Add(new Border { BorderBrush = dim, BorderThickness = new Thickness(3,0,0,0), Padding = new Thickness(10,0,0,0), Child = RenderBlocks(quote,basePath) });
                    break;
                case ListBlock list:
                    int number = int.TryParse(list.OrderedStart, out var first) ? first : 1;
                    foreach (var item in list.OfType<ListItemBlock>())
                    {
                        var row = new Grid { ColumnSpacing = 6 };
                        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                        row.ColumnDefinitions.Add(new ColumnDefinition());
                        var task = item.Descendants<TaskList>().FirstOrDefault();
                        row.Children.Add(new TextBlock { Text = task != null ? (task.Checked ? "☑" : "☐") : list.IsOrdered ? $"{number++}." : "•", Foreground=muted });
                        var inner = RenderBlocks(item,basePath); Grid.SetColumn(inner,1); row.Children.Add(inner);panel.Children.Add(row);
                    }
                    break;
                case Table table:
                    var grid = new Grid();
                    int y=0;
                    foreach(var row in table.OfType<TableRow>())
                    {
                        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); int x=0;
                        foreach(var cell in row.OfType<TableCell>())
                        {
                            if(grid.ColumnDefinitions.Count<=x) grid.ColumnDefinitions.Add(new ColumnDefinition { Width=GridLength.Auto, MaxWidth=380 });
                            var box = new Border { Child=RenderBlocks(cell,basePath), Padding=new Thickness(10,6,10,6), BorderBrush=edge, BorderThickness=new Thickness(.5), Background=row.IsHeader?rail:null };
                            Grid.SetColumn(box,x++);Grid.SetRow(box,y);grid.Children.Add(box);
                        }
                        y++;
                    }
                    panel.Children.Add(new ScrollViewer { Content=grid, HorizontalScrollBarVisibility=ScrollBarVisibility.Auto, HorizontalScrollMode=ScrollMode.Enabled, VerticalScrollBarVisibility=ScrollBarVisibility.Disabled });
                    break;
                case ThematicBreakBlock:
                    panel.Children.Add(new Border { Background=edge,Height=1 });break;
                case ContainerBlock nested: panel.Children.Add(RenderBlocks(nested,basePath));break;
            }
        }
        return panel;
    }
    private void AddInlines(InlineCollection target, ContainerInline source,string basePath)
    {
        foreach(var node in source)
        {
            switch(node)
            {
                case LiteralInline literal: target.Add(new Run {Text=literal.Content.ToString()}); break;
                case LineBreakInline br: if(br.IsHard) target.Add(new LineBreak()); else target.Add(new Run {Text=" "});break;
                case CodeInline code: target.Add(new Run {Text=code.Content,FontFamily=new FontFamily("Cascadia Mono, Consolas"),Foreground=sage});break;
                case HtmlEntityInline entity: target.Add(new Run {Text=entity.Transcoded.ToString()});break;
                case EmphasisInline em:
                    Span style = em.DelimiterChar=='~' ? new Span {TextDecorations=Windows.UI.Text.TextDecorations.Strikethrough} :
                        em.DelimiterCount==2 ? new Bold() : new Italic();
                    AddInlines(style.Inlines,em,basePath);target.Add(style);break;
                case LinkInline link:
                    if(!link.IsImage && WebLink(link.Url) is Uri url)
                    { var anchor=new Hyperlink {NavigateUri=url}; AddInlines(anchor.Inlines,link,basePath);target.Add(anchor); }
                    else if(!link.IsImage && link.Url is { Length: > 0 } file && !file.StartsWith('#') && !file.StartsWith("//") && !Regex.IsMatch(file, @"^[a-zA-Z][a-zA-Z0-9+.-]*:"))
                    {
                        var path=Uri.UnescapeDataString(file.Split('#')[0]);
                        if(!path.StartsWith('/'))path=basePath.TrimEnd('/')+"/"+path;
                        var origin=agent;var anchor=new Hyperlink();
                        anchor.Click+=async (_,_)=>await RunAsync(async ()=>{if(origin!=agent)throw new IOException("文件链接所属的连接已改变");await PreviewAsync(path);});
                        AddInlines(anchor.Inlines,link,basePath);target.Add(anchor);
                    }
                    else AddInlines(target,link,basePath);
                    break;
                case AutolinkInline auto:
                    if(WebLink(auto.Url) is Uri uri){var anchor=new Hyperlink {NavigateUri=uri};anchor.Inlines.Add(new Run{Text=auto.Url});target.Add(anchor);}
                    else target.Add(new Run {Text=auto.Url});break;
                case ContainerInline nested: AddInlines(target,nested,basePath);break;
            }
        }
    }
    private static Uri? WebLink(string? s) => Uri.TryCreate(s,UriKind.Absolute,out var u) && u.Scheme is "http" or "https" ? u : null;
    private static readonly HashSet<string> Languages = new(StringComparer.OrdinalIgnoreCase) {
        "js","javascript","jsx","ts","typescript","tsx","json","py","python","sh","bash","zsh","c","cpp","cs","csharp","go","rust","rs","java","swift","ps1","powershell" };
    private static readonly Regex Tokens = new("""(?<comment>//[^\r\n]*|\#[^\r\n]*|/\*[\s\S]*?\*/)|(?<str>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?<num>\b\d+(?:\.\d+)?\b)|(?<kw>\b(?:let|var|func|struct|class|enum|import|return|if|else|guard|for|while|await|async|try|throw|const|function|export|from|def|in|with|as|true|false|null|nil|None|self|public|private|static|switch|case|break|continue|new|using|namespace|interface|void)\b)""", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private const double CodeHeightLimit = 380;
    /// Long lines scroll sideways and tall blocks scroll inside a capped box; `follow` keeps the newest lines of a block that is still streaming in view.
    private FrameworkElement CodePanel(string code,string language,bool follow=false,string? title=null)
    {
        var text=new TextBlock {FontFamily=Mono,Foreground=ink,FontSize=12.5,LineHeight=19,IsTextSelectionEnabled=true,TextWrapping=TextWrapping.NoWrap};
        if(code.Length<80000 && Languages.Contains(language))
        {
            // The macOS palettes' syntax colours.
            bool dark=root.ActualTheme==ElementTheme.Dark;
            var str=dark?Brush(0x75,0xB1,0x8B):Brush(0x1D,0x69,0x1A);
            var num=dark?Brush(0xC2,0x8E,0xC4):Brush(0x58,0x30,0x9D);
            var kw=dark?Brush(0xD7,0x91,0x5C):Brush(0xA4,0x3E,0x3A);
            int offset=0;
            foreach(Match m in Tokens.Matches(code))
            {
                if(m.Index>offset)text.Inlines.Add(new Run {Text=code[offset..m.Index]});
                text.Inlines.Add(new Run {Text=m.Value,Foreground=m.Groups["comment"].Success?muted:m.Groups["str"].Success?str:m.Groups["num"].Success?num:kw});
                offset=m.Index+m.Length;
            }
            if(offset<code.Length)text.Inlines.Add(new Run{Text=code[offset..]});
        } else text.Text=code;
        // A header strip over the code: what it is on the left, its length and the copy action on the right.
        int lines=code.TrimEnd('\n').Count(c=>c=='\n')+1;
        var header=new Grid {Background=hover,BorderBrush=edge,BorderThickness=new Thickness(0,0,0,1),Padding=new Thickness(12,1,3,1)};
        header.Children.Add(new TextBlock {Text=title ?? (language.Length==0?"代码":language),FontFamily=title is null?Mono:null,Foreground=muted,FontSize=12,VerticalAlignment=VerticalAlignment.Center});
        var copy=ActionButton("复制","\uE8C8",()=>{var data=new DataPackage();data.SetText(code);Clipboard.SetContent(data);return Task.CompletedTask;},true);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(copy,"复制代码");copy.Foreground=muted;
        if(copy.Content is StackPanel label) { ((FontIcon)label.Children[0]).FontSize=12; ((TextBlock)label.Children[1]).FontSize=12; }
        var side=Row(copy);side.Spacing=6;side.HorizontalAlignment=HorizontalAlignment.Right;
        if(lines>1) side.Children.Insert(0,new TextBlock {Text=lines+" 行",FontSize=11,Foreground=dim,VerticalAlignment=VerticalAlignment.Center});
        header.Children.Add(side);
        var box=new ScrollViewer {Content=text,MaxHeight=CodeHeightLimit,HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollMode=ScrollMode.Auto,Padding=new Thickness(12,10,12,12)};
        if(follow) box.Loaded+=(_,_)=>box.ChangeView(null,box.ScrollableHeight,null,true);
        var panel=new StackPanel();panel.Children.Add(header);panel.Children.Add(box);
        return new Border {Child=panel,BorderBrush=edge,BorderThickness=new Thickness(1),CornerRadius=new CornerRadius(8),Background=surface};
    }
}
