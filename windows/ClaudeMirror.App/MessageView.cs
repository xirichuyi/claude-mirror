using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
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
    private sealed class MessageView
    {
        private readonly MainWindow window;
        private readonly StackPanel body = new() { Spacing = 8 };
        private readonly bool user;
        private readonly HashSet<int> expanded = [];
        private readonly TextBlock error = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        private string? previous;
        public Border Container { get; }

        public MessageView(MainWindow window,bool user,string text)
        {
            this.window = window; this.user = user;
            var stack = new StackPanel { Spacing=6 }; stack.Children.Add(body); stack.Children.Add(error);
            error.Visibility=Visibility.Collapsed;
            Container = new Border { Child=stack, HorizontalAlignment=user?HorizontalAlignment.Right:HorizontalAlignment.Stretch,
                Padding = user?new Thickness(14,10,14,10):new Thickness(0), CornerRadius=new CornerRadius(16),
                Background=user?window.bubble:null };
            if(!user) body.Children.Add(Label("Claude",12,window.muted));
            if(text.Length>0) body.Children.Add(Label(text,15,window.ink));
        }
        private static TextBlock Label(string text,double size,Brush color) => new() { Text=text,FontSize=size,Foreground=color,TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true };
        public void SetError(string text) { error.Text=text; error.Visibility=Visibility.Visible; }
        public void Show(JsonNode? message)
        {
            string? current=message?.ToJsonString();
            if(current == previous) return;
            previous=current; body.Children.Clear(); error.Visibility=Visibility.Collapsed;
            if(!user) body.Children.Add(Label("Claude",12,window.muted));
            var blocks=message?["blocks"] as JsonArray ?? message?["content"] as JsonArray;
            if(blocks is { Count: > 0 } && !user)
            {
                for(int i=0;i<blocks.Count;i++)
                {
                    var b=blocks[i]; var type=(string?)b?["type"];
                    if(type is "tool" or "tool_use" or "thinking") {
                        var details=type=="thinking" ? (string?)b?["text"] ?? (string?)b?["thinking"] : b?["input"]?.ToJsonString(new(){WriteIndented=true});
                        if(b?["output"] is JsonNode output) details+="\n"+output.ToString();
                        var section=new Expander {Header=type=="thinking"?"思考":((string?)b?["name"]??"工具调用"),Content=Code(details??""),IsExpanded=expanded.Contains(i),HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch};
                        int index=i;section.Expanding+=(_,_)=>expanded.Add(index);section.Collapsed+=(_,_)=>expanded.Remove(index);
                        body.Children.Add(section);
                    } else if((string?)b?["text"] is string text) AddText(text);
                }
            }
            else {
                var plain=Protocol.MessageText(message);
                if(user) body.Children.Add(Label(plain,15,window.ink)); else AddText(plain);
            }
        }
        private FrameworkElement Code(string text) => window.CodePanel(text, string.Empty);
        private void AddText(string text) => body.Children.Add(window.MarkdownView(text));
    }
}
