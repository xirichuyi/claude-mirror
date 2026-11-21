namespace ClaudeMirror.Core;

/// <summary>The sidebar's view of the server's history: local names, pins, archive and removals applied on top.</summary>
public static class Sessions
{
    public sealed record Entry(Conversation Conversation, string Key, bool Pinned, bool Archived);
    public sealed record Project(string Directory, IReadOnlyList<Entry> Entries);

    /// <summary>Identifies a conversation on one host; null for a conversation the server has not given an ID yet.</summary>
    public static string? Key(string hostKey, Conversation conversation) =>
        (conversation.SessionId ?? conversation.Reference) is { } id ? hostKey + "|" + id : null;

    public static string Rename(LocalState state, string key, string name)
    {
        var value = name.Trim();
        if (value.Length is 0 or > 80) throw new ArgumentException("名称需为 1–80 个字符");
        state.Names[key] = value; return value;
    }

    public static void SetPinned(LocalState state, string key, bool value) { if (value) state.Pinned.Add(key); else state.Pinned.Remove(key); }
    public static void SetArchived(LocalState state, string key, bool value) { if (value) { state.Archived.Add(key); state.Pinned.Remove(key); } else state.Archived.Remove(key); }
    /// <summary>Takes a conversation out of the list. Its name, pin and archive marks go with it.</summary>
    public static void Hide(LocalState state, string key) { state.Hidden.Add(key); state.Names.Remove(key); state.Pinned.Remove(key); state.Archived.Remove(key); }

    /// <summary>Conversations with their local names, without removed ones; archived ones only on request. Server order is kept.</summary>
    public static List<Entry> Visible(IEnumerable<Conversation> history, LocalState state, string hostKey, string query = "", bool archived = false)
    {
        var entries = new List<Entry>();
        foreach (var conversation in history)
        {
            var key = Key(hostKey, conversation);
            if (key is null) continue;
            if (state.Hidden.Contains(key) || state.Archived.Contains(key) != archived) continue;
            var named = state.Names.TryGetValue(key, out var name) ? conversation with { Name = name } : conversation;
            if (query.Length > 0 && !(named.Name + " " + named.Directory).Contains(query, StringComparison.OrdinalIgnoreCase)) continue;
            entries.Add(new Entry(named, key, state.Pinned.Contains(key), archived));
        }
        return entries;
    }

    /// <summary>Entries grouped by working directory, in order of first appearance.</summary>
    public static List<Project> Projects(IEnumerable<Entry> entries) =>
        entries.GroupBy(entry => entry.Conversation.Directory).Select(group => new Project(group.Key, group.ToList())).ToList();
}
