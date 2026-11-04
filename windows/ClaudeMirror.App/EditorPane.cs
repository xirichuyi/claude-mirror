using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using System.Text;
using System.Text.Json.Nodes;
using Windows.System;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    private readonly Grid split = new();
    private readonly TabView editorTabs = new() { IsAddTabButtonVisible=false, TabWidthMode=TabViewWidthMode.SizeToContent };
    private readonly List<EditorFile> openFiles = [];
    private FrameworkElement chatArea = null!;
    private bool showEditor;
    private sealed class EditorFile(string path, string owner, JsonNode preview)
    {
        public readonly string Path=path, Owner=owner;
        public readonly TabViewItem Tab=new();
        public readonly Border Container=new();

        public JsonNode Preview=preview;
        public string Original => Preview["text"]?.GetValue<string>() ?? "";
        public string? Draft;
        public bool Editing, Saving, Source;
        public bool Dirty => Editing && Draft!=Original;
    }
    private void BuildSplit(FrameworkElement chat)
    {
        chatArea=chat; split.ColumnDefinitions.Add(new ColumnDefinition());split.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(0)});
        split.Children.Add(chat);Grid.SetColumn(editorTabs,1);split.Children.Add(editorTabs);
        Grid.SetColumn(split,1);root.Children.Add(split);
        editorTabs.TabCloseRequested+=async (_,e)=>await RunAsync(async ()=>{
            var file=openFiles.FirstOrDefault(x=>x.Tab==e.Tab);if(file==null || file.Saving)return;
            if(file.Dirty && !await ConfirmDiscardAsync(file)) return;
            openFiles.Remove(file);editorTabs.TabItems.Remove(file.Tab);LayoutSplit();
        });
        split.SizeChanged+=(_,_)=>LayoutSplit();
        AppWindow.Closing+=(_,e)=>{ if(openFiles.Any(f=>f.Dirty || f.Saving)){e.Cancel=true;showEditor=true;LayoutSplit();status.Text="文件仍有更改或正在保存，请先保存或关闭标签。";} };
        LayoutSplit();
    }
    private void LayoutSplit()
    {
        bool visible=showEditor && openFiles.Count>0, narrow=split.ActualWidth<710;
        editorTabs.Visibility=visible?Visibility.Visible:Visibility.Collapsed;
        chatArea.Visibility=visible && narrow?Visibility.Collapsed:Visibility.Visible;
        split.ColumnDefinitions[0].Width=new GridLength(visible && narrow?0:1,GridUnitType.Star);
        split.ColumnDefinitions[1].Width=new GridLength(visible?1:0,GridUnitType.Star);
    }
    private async Task<bool> ConfirmDiscardAsync(EditorFile file) =>
        await new ContentDialog {XamlRoot=root.XamlRoot,Title="放弃未保存的更改？",Content=file.Path,PrimaryButtonText="放弃更改",CloseButtonText="继续编辑"}.ShowAsync()==ContentDialogResult.Primary;

    private void OpenTextEditor(string path,string owner,JsonNode preview)
    {
        var file=openFiles.FirstOrDefault(f=>f.Path==path && f.Owner==owner);
        if(file==null)
        {
            file=new EditorFile(path,owner,preview);
            file.Tab.Content=file.Container;openFiles.Add(file);editorTabs.TabItems.Add(file.Tab);RenderEditor(file);
        }
        editorTabs.SelectedItem=file.Tab;showEditor=true;LayoutSplit();
    }
    private void RenderEditor(EditorFile f)
    {
        void Header() => f.Tab.Header=(f.Dirty?"● ":"")+Path.GetFileName(f.Path);
        Header();ToolTipService.SetToolTip(f.Tab,f.Owner+" · "+f.Path);
        var area=Rows(GridLength.Auto,GridLength.Auto,new GridLength(1,GridUnitType.Star)); area.Background=canvas;
        var buttons=new StackPanel {Orientation=Orientation.Horizontal,Spacing=4,Margin=new Thickness(6)};
        buttons.Children.Add(ActionButton("返回对话","\uE72B",()=>{showEditor=false;LayoutSplit();return Task.CompletedTask;}));
        bool writable=f.Preview["truncated"]?.GetValue<bool>()!=true && f.Preview["revision"]!=null;
        var edit=ActionButton(f.Editing?"保存到远端":"编辑",f.Editing?"\uE74E":"\uE70F",async ()=>{
            if(f.Editing) await SaveEditorAsync(f);
            else { f.Draft=f.Original;f.Editing=true;RenderEditor(f); }
        },true);
        edit.IsEnabled=writable && !f.Saving;buttons.Children.Add(edit);
        buttons.Children.Add(ActionButton("重新加载","\uE72C",async ()=>{
            if(f.Saving || (f.Dirty && !await ConfirmDiscardAsync(f)))return;
            var remote=FileAgent(f);var fresh=await remote.CallAsync("file",new {operation="preview",path=f.Path});
            if((string?)fresh["kind"]!="text") throw new IOException("远端文件已不再是文本文件");
            f.Preview=fresh;f.Draft=null;f.Editing=false;RenderEditor(f);
        }));
        if(!f.Editing && Path.GetExtension(f.Path).ToLowerInvariant() is ".md" or ".markdown") buttons.Children.Add(Button(f.Source?"渲染":"源码",()=>{f.Source=!f.Source;RenderEditor(f);return Task.CompletedTask;}));
        buttons.Children.Add(ActionButton("下载","\uE896",()=>DownloadEditorAsync(f)));
        var title=new TextBlock {Text=f.Path,Foreground=muted,FontSize=12,TextTrimming=TextTrimming.CharacterEllipsis,Margin=new Thickness(10,0,10,4)};
        var top=new StackPanel();top.Children.Add(buttons);top.Children.Add(title);At(area,top,0);
        var notice=new TextBlock {TextWrapping=TextWrapping.Wrap,Foreground=muted,Margin=new Thickness(10,0,10,4)};
        notice.Text=writable?"":"仅预览文件的前 1 MB";At(area,notice,1);f.Container.Child=area;
        if(f.Editing)
        {
            var box=new TextBox {Text=f.Draft,AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,FontFamily=new FontFamily("Cascadia Mono, Consolas"),IsReadOnly=f.Saving};
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box,"文件内容");
            void Changed() {
                var eol=f.Original.Contains("\r\n")?"\r\n":f.Original.Contains('\r') && !f.Original.Contains('\n')?"\r":"\n";
                f.Draft=(box.Text ?? "").ReplaceLineEndings(eol);Header();
            }
            box.TextChanged+=(_,_)=>Changed();
            var saveKey=new KeyboardAccelerator {Key=VirtualKey.S,Modifiers=VirtualKeyModifiers.Control};
            saveKey.Invoked+=async (_,e)=>{e.Handled=true;await RunAsync(()=>SaveEditorAsync(f));};box.KeyboardAccelerators.Add(saveKey);
            At(area,box,2);box.Loaded+=(_,_)=>box.Focus(FocusState.Programmatic);
        }else{
            var ext=Path.GetExtension(f.Path).TrimStart('.').ToLowerInvariant();
            UIElement content=ext is "md" or "markdown" && writable && !f.Source?MarkdownView(f.Original,Path.GetDirectoryName(f.Path)?.Replace(Path.DirectorySeparatorChar,'/') ?? directory.Text):CodePanel(f.Original,ext);
            At(area,new ScrollViewer {Content=content,Padding=new Thickness(10)},2);
        }
        // Keep feedback in the active tab even when the sidebar is collapsed.
        f.Tab.Tag=notice;
    }
    private RemoteAgent FileAgent(EditorFile f)
    {
        if(host==null || LocalState.HostKey(host)!=f.Owner) throw new IOException("请重新连接此文件所属的主机："+f.Owner);
        return RequireAgent();
    }
    private async Task SaveEditorAsync(EditorFile f)
    {
        if(f.Saving || !f.Editing)return;
        var data=f.Draft ?? f.Original;
        if(Encoding.UTF8.GetByteCount(data)>1024*1024) throw new IOException("编辑上限为 1 MB");
        f.Saving=true;RenderEditor(f);
        try {
            var result=await FileAgent(f).CallAsync("file",new {operation="save",path=f.Path,revision=(string?)f.Preview["revision"],data});
            f.Preview=result;f.Editing=false;f.Draft=null;
        } catch(Exception ex) {
            f.Saving=false;RenderEditor(f);
            ((TextBlock)f.Tab.Tag).Text=ex.Message;
            return;
        } finally {f.Saving=false;}
        RenderEditor(f);((TextBlock)f.Tab.Tag).Text="已保存到远端";
    }
    private async Task DownloadEditorAsync(EditorFile f)
    {
        var remote=FileAgent(f);var picker=new Windows.Storage.Pickers.FileSavePicker {SuggestedFileName=Path.GetFileName(f.Path)};
        WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));
        var ext=Path.GetExtension(f.Path);picker.FileTypeChoices.Add("文件",new List<string>{ext.Length>0?ext:".txt"});
        var dest=await picker.PickSaveFileAsync();if(dest!=null)await remote.DownloadAsync(f.Path,dest.Path);
    }
}
