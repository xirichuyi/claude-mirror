using ClaudeMirror.Core;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    /// A conversation the user left while it was replying, waiting for an answer, or holding queued prompts.
    /// Its remote task stays watched, its queue keeps sending, and its messages are kept as they were on screen.
    private sealed class Parked
    {
        public required Conversation Conversation;
        public required string TaskId;
        public string? TaskKey;
        public required SendQueue Queue;
        public required string PermissionMode;
        public required string ExecutionUser;
        public required List<UIElement> Views;
        public MessageView? Reply;
        public JsonObject? State;
        public JsonArray Tasks = [];
        public bool Busy, Sending, Unread, Done;
        public bool Active => Busy || Sending || Queue.Items.Count > 0;
        public string? Label => Turn.Label(Busy, Busy && Turn.NeedsAnswer(State), Queue.Paused, Queue.Items.Count, Unread);
    }

    private readonly Dictionary<string, Parked> parked = [];

    private Parked? ParkedFor(Conversation c) =>
        parked.Values.FirstOrDefault(p => ReferenceEquals(p.Conversation, c) || (c.SessionId is not null && p.Conversation.SessionId == c.SessionId && p.Conversation.Directory == c.Directory));

    /// Whether this conversation has work under way, on screen or in the background.
    private bool Active(Conversation c) => IsCurrent(c) ? busy || queue.Items.Count > 0 : ParkedFor(c)?.Active == true;

    /// Leaves the open conversation without stopping it: one that is replying, waiting for an answer or holding queued prompts
    /// carries on in the background. Declining to drop prompts that have no task to run in keeps the conversation and stops the caller.
    private async Task LeaveConversationAsync()
    {
        if (sending) throw new IOException("消息正在发送，请稍候再切换对话");
        if (taskId is null) await ConfirmLeavingQueueAsync();
        else if (busy || queue.Items.Count > 0 || Turn.NeedsAnswer(lastState))
        {
            parked[taskId] = new Parked
            {
                Conversation = conversation ?? new Conversation(newTitle ?? "新对话", directory.Text, null, null, executionUser.Length > 0 ? executionUser : null),
                TaskId = taskId, TaskKey = taskKey, Queue = queue, PermissionMode = permissionMode, ExecutionUser = executionUser,
                Views = messages.Children.ToList(), Reply = reply, State = lastState, Tasks = backgroundTasks, Busy = busy
            };
        }
        else if (agent?.Connected == true)
        {
            try { await agent.UnwatchAsync(taskId); } catch (IOException) { } // The connection just dropped; there is nothing left to cancel.
        }
        conversation = null; taskId = null; taskKey = null; reply = null; lastState = null; newTitle = null; busy = false; stopping = false;
        queue = new SendQueue(); backgroundTasks = []; messages.Children.Clear();
    }

    /// Puts a background conversation back on screen exactly as it was left, then brings it up to its latest state.
    private async Task RestoreAsync(Parked p)
    {
        parked.Remove(p.TaskId);
        conversation = p.Conversation; taskId = p.Done ? null : p.TaskId; taskKey = p.TaskKey; queue = p.Queue; reply = p.Reply;
        lastState = p.State; backgroundTasks = p.Tasks; busy = p.Busy; stopping = false; newTitle = p.Conversation.Name;
        executionUser = p.ExecutionUser; permissionMode = p.PermissionMode; UpdatePermissionTitle();
        directory.Text = p.Conversation.Directory;
        messages.Children.Clear(); foreach (var view in p.Views) messages.Children.Add(view);
        RenderQueue(); RenderPermissions(null, null); RefreshWorkbench(); RenderHistory();
        if (taskId is not null && lastState is not null) await ApplyStateAsync(taskId, lastState);
        else if (reply is not null && lastState is not null) reply.Show(lastState["message"], false);
        DispatcherQueue.TryEnqueue(() => scroll.ChangeView(null, scroll.ScrollableHeight, null, true));
        await RefreshCapabilitiesAsync();
    }

    private async Task BackgroundStateAsync(Parked p, JsonObject state)
    {
        bool wasBusy = p.Busy; var label = p.Label;
        p.State = state; p.Busy = Turn.Busy(state, p.Sending);
        if (state["tasks"] is JsonArray tasks) p.Tasks = (JsonArray)tasks.DeepClone();
        if (wasBusy && !p.Busy)
        {
            // A reply that failed or was stopped keeps the queue until the user opens the conversation and says to go on.
            if (Turn.Failed(state)) p.Queue.Pause();
            p.Unread = true;
        }
        if (state["remoteSessionId"] is JsonValue session && session.GetValue<string>() is var sessionId && p.Conversation.SessionId != sessionId && host is not null)
        {
            p.Conversation = p.Conversation with { SessionId = sessionId };
            local.Tasks[LocalState.HostKey(host) + "|" + sessionId] = p.TaskId; local.Save();
        }
        if (state["done"]?.GetValue<bool>() == true)
        {
            foreach (var key in local.Tasks.Where(pair => pair.Value == p.TaskId).Select(pair => pair.Key).ToList()) local.Tasks.Remove(key);
            local.Save(); p.Done = true; p.Busy = false; p.Queue.Pause();
        }
        if (!p.Done && p.Queue.Next(p.Busy) is { } next) await SendParkedAsync(p, next.Text);
        if (label == p.Label || !parked.ContainsKey(p.TaskId)) return;
        RenderHistory();
        if (p.Busy && Turn.NeedsAnswer(p.State)) status.Text = $"“{p.Conversation.Name}”在等你确认";
        else if (!p.Busy && wasBusy) status.Text = p.Queue.Paused ? $"“{p.Conversation.Name}”的回复中断了，排队的消息已暂停" : $"“{p.Conversation.Name}”已回复完";
    }

    /// Sends the next queued prompt of a conversation that is not on screen.
    private async Task SendParkedAsync(Parked p, string text)
    {
        p.Reply?.Show(p.State?["message"], false);
        p.Busy = true; p.Sending = true;
        p.Views.Add(new MessageView(this, true, text).Container);
        p.Reply = new MessageView(this, false, "正在回复…"); p.Views.Add(p.Reply.Container);
        var message = new { id = Guid.NewGuid().ToString(), role = "assistant", blocks = Array.Empty<object>() };
        try
        {
            var remote = RequireAgent();
            await remote.TaskCommandAsync(p.TaskId, new { kind = "control", action = "permission", value = p.PermissionMode });
            await remote.TaskCommandAsync(p.TaskId, new { kind = "send", prompt = text, message });
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException)
        {
            p.Busy = false; p.Queue.Pause();
            status.Text = $"“{p.Conversation.Name}”的排队消息未确认送达";
        }
        finally { p.Sending = false; }
    }

    /// Follows every background conversation again after a reconnect.
    private async Task RewatchParkedAsync(RemoteAgent remote)
    {
        foreach (var p in parked.Values.Where(p => !p.Done).ToList())
        {
            try { await remote.WatchAsync(p.TaskId, state => OnState(p.TaskId, state)); }
            catch (IOException) { p.Done = true; p.Busy = false; p.Queue.Pause(); } // The task ended while the connection was down.
        }
        RenderHistory();
    }

    /// What happened to background replies is unknown once the connection is gone, so their queues wait for the user.
    private void PauseParked()
    {
        foreach (var p in parked.Values) { p.Busy = false; p.Queue.Pause(); }
    }

    /// Stops following a background conversation that is being removed from this computer's list.
    private async Task ForgetParkedAsync(Parked p)
    {
        parked.Remove(p.TaskId);
        if (agent?.Connected == true) try { await agent.UnwatchAsync(p.TaskId); } catch (IOException) { }
    }

    private Button ParkedRow(Parked p)
    {
        var row = Flat(Button(p.Conversation.Name, () => SelectAsync(p.Conversation)));
        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = p.Conversation.Name, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(new TextBlock { Text = (p.Label ?? "空闲") + " · " + (ShortDirectory(p.Conversation.Directory) ?? p.Conversation.Directory), FontSize = 11, Foreground = p.Busy && Turn.NeedsAnswer(p.State) ? amber : muted, TextTrimming = TextTrimming.CharacterEllipsis });
        var content = Row(RowIcon(p.Busy ? "\uE895" : p.Queue.Paused ? "\uE769" : "\uE8BD"), text); content.Spacing = 6; row.Content = content;
        row.HorizontalAlignment = HorizontalAlignment.Stretch; row.HorizontalContentAlignment = HorizontalAlignment.Left;
        row.Padding = new Thickness(8, 5, 8, 5);
        ToolTipService.SetToolTip(row, p.Conversation.Name + "\n" + p.Conversation.Directory);
        return row;
    }
}
