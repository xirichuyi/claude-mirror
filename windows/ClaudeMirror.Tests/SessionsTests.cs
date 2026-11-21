using ClaudeMirror.Core;
using Xunit;

public class SessionsTests
{
    private const string Host = "dev@example:22";
    private static readonly Conversation[] History =
    [
        new("修复登录", "/srv/api", "s1", "r1"), new("加索引", "/srv/api", "s2", "r2"), new("首页优化", "/srv/web", "s3", "r3"), new("未保存", "/srv/web", null, null)
    ];
    private static LocalState State() => new(Path.Combine(Path.GetTempPath(), "claude-mirror-tests-" + Guid.NewGuid().ToString("N")));

    [Fact]
    public void LocalMarksShapeTheListAndSurviveARestart()
    {
        var folder = Path.Combine(Path.GetTempPath(), "claude-mirror-tests-" + Guid.NewGuid().ToString("N"));
        var state = new LocalState(folder);
        Sessions.Rename(state, Host + "|s1", "  登录流程  ");
        Sessions.SetPinned(state, Host + "|s3", true);
        Sessions.SetArchived(state, Host + "|s2", true);
        state.Theme = "dark";
        state.Save();

        var saved = new LocalState(folder);
        Assert.Equal("dark", saved.Theme);
        Assert.Equal("system", State().Theme);
        var entries = Sessions.Visible(History, saved, Host);
        Assert.Equal(["登录流程", "首页优化"], entries.Select(entry => entry.Conversation.Name));
        Assert.True(entries[1].Pinned);
        Assert.Equal("加索引", Assert.Single(Sessions.Visible(History, saved, Host, archived: true)).Conversation.Name);
        Assert.Equal(["/srv/api", "/srv/web"], Sessions.Projects(entries).Select(project => project.Directory));
        Assert.DoesNotContain(Sessions.Visible(History, saved, "other@host:22"), entry => entry.Pinned);
    }

    [Fact]
    public void SearchUsesTheLocalNameAndRemovedConversationsStayGone()
    {
        var state = State();
        Sessions.Rename(state, Host + "|s1", "认证");
        Assert.Equal("认证", Assert.Single(Sessions.Visible(History, state, Host, "认证")).Conversation.Name);
        Assert.Empty(Sessions.Visible(History, state, Host, "修复登录"));
        Sessions.SetPinned(state, Host + "|s1", true);
        Sessions.Hide(state, Host + "|s1");
        Assert.DoesNotContain(Sessions.Visible(History, state, Host), entry => entry.Key == Host + "|s1");
        Assert.Empty(state.Pinned); Assert.Empty(state.Names);
    }

    [Fact]
    public void ArchivingUnpinsAndNamesAreLimited()
    {
        var state = State();
        Sessions.SetPinned(state, Host + "|s1", true);
        Sessions.SetArchived(state, Host + "|s1", true);
        Assert.Empty(state.Pinned);
        Assert.Throws<ArgumentException>(() => Sessions.Rename(state, Host + "|s1", "   "));
        Assert.Throws<ArgumentException>(() => Sessions.Rename(state, Host + "|s1", new string('x', 81)));
    }
}
