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

    private StackPanel MarkdownView(string source,string? basePath=null) => RenderBlocks(Markdown.Parse(source, MarkdownOptions),basePath ?? directory.Text);

    private StackPanel RenderBlocks(ContainerBlock blocks,string basePath)
    {
        var panel = new StackPanel { Spacing = 8 };
        foreach (var block in blocks)
        {
            switch (block)
            {
                case CodeBlock code:
                    panel.Children.Add(CodePanel(code.Lines.ToString(), (code as FencedCodeBlock)?.Info ?? ""));
                    break;
                case LeafBlock { Inline: { } inline }:
                    var text = new TextBlock { Foreground = ink, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = 15 };
                    if (block is HeadingBlock heading)
                    {
                        text.FontSize = heading.Level switch { 1 => 23, 2 => 19, 3 => 16, _ => 14 };
                        text.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
                    }
                    AddInlines(text.Inlines, inline,basePath);
                    panel.Children.Add(text);
                    break;
                case QuoteBlock quote:
                    panel.Children.Add(new Border { BorderBrush = edge, BorderThickness = new Thickness(3,0,0,0), Padding = new Thickness(12,0,0,0), Child = RenderBlocks(quote,basePath) });
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
    private FrameworkElement CodePanel(string code,string language)
    {
        var text=new TextBlock {FontFamily=new FontFamily("Cascadia Mono, Consolas"),Foreground=ink,FontSize=13,IsTextSelectionEnabled=true,TextWrapping=TextWrapping.Wrap};
        if(code.Length<80000 && Languages.Contains(language))
        {
            bool dark=root.ActualTheme==ElementTheme.Dark;
            var str=dark?Brush(159,205,156):Brush(41,108,64);
            var num=dark?Brush(243,181,121):Brush(149,75,21);
            var kw=dark?Brush(205,167,240):Brush(117,59,147);
            int offset=0;
            foreach(Match m in Tokens.Matches(code))
            {
                if(m.Index>offset)text.Inlines.Add(new Run {Text=code[offset..m.Index]});
                text.Inlines.Add(new Run {Text=m.Value,Foreground=m.Groups["comment"].Success?muted:m.Groups["str"].Success?str:m.Groups["num"].Success?num:kw});
                offset=m.Index+m.Length;
            }
            if(offset<code.Length)text.Inlines.Add(new Run{Text=code[offset..]});
        } else text.Text=code;
        var header=new Grid();
        header.Children.Add(new TextBlock {Text=language.Length==0?"代码":language,Foreground=muted,FontSize=12,VerticalAlignment=VerticalAlignment.Center});
        var copy=ActionButton("复制代码","\uE8C8",()=>{var data=new DataPackage();data.SetText(code);Clipboard.SetContent(data);return Task.CompletedTask;});
        copy.HorizontalAlignment=HorizontalAlignment.Right;header.Children.Add(copy);
        var panel=new StackPanel {Spacing=6};panel.Children.Add(header);panel.Children.Add(text);
        return new Border {Child=panel,Padding=new Thickness(12),BorderBrush=edge,BorderThickness=new Thickness(1),CornerRadius=new CornerRadius(8),Background=surface};
    }
}
