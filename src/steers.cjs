// Messages sent while Claude is replying join the running turn (Codex calls this "steering").
// The CLI takes a priority 'next' message at its next tool boundary, or as its own turn right
// after the current one ends; command_lifecycle frames report when it was actually taken.
class Steers {
  constructor(session) {
    this.session = session;
    session.steers = [];
  }

  // Returns false for a replay of a steer that is already pending or already delivered.
  add(command, message) {
    if (typeof command.id !== 'string' || !command.id || typeof command.prompt !== 'string' || !command.prompt.trim())
      throw new Error('插入的消息无效');
    if (command.prompt.length > 200_000) throw new Error('消息不能超过 20 万字符');
    if (this.session.steers.some(item => item.id === command.id) || message?.blocks?.some(block => block.type === 'user' && block.id === command.id)) return false;
    if (this.session.steers.length >= 20) throw new Error('最多同时插入 20 条消息');
    this.session.steers.push({ id: command.id, text: typeof command.text === 'string' && command.text ? command.text : command.prompt });
    return true;
  }

  // `run` is the active reply, or null between turns. Returns true when the state changed.
  lifecycle(event, run) {
    if (event?.type !== 'command_lifecycle') return false;
    const index = this.session.steers.findIndex(item => item.id === event.command_uuid);
    if (index < 0) return false;
    const steer = this.session.steers[index];
    if (event.state === 'queued') { steer.queued = true; return true; }
    if (event.state === 'started') {
      this.session.steers.splice(index, 1);
      run?.message.blocks.push({ type: 'user', id: steer.id, text: steer.text });
      return true;
    }
    if (event.state === 'cancelled') {
      this.session.steers.splice(index, 1);
      run?.message.blocks.push({ type: 'notice', level: 'error', text: '插入的消息已被取消，未发送给 Claude：' + steer.text.slice(0, 200) });
      return true;
    }
    return false;
  }

  // Called on a turn's result. While a steer is pending the CLI runs it next, so the reply stays
  // open and the follow-up turn streams into the same message instead of being dropped.
  holdTurn(run) {
    if (!this.session.steers.length) return false;
    // An older CLI reports no lifecycle; its next turn is simply the oldest pending message.
    for (const steer of this.session.steers.filter(item => !item.queued)) this.lifecycle({ type: 'command_lifecycle', command_uuid: steer.id, state: 'started' }, run);
    if (run.stopped) {
      // As in Codex, interrupting sends pending messages immediately instead of discarding them.
      run.stopped = false;
      run.message.blocks.push({ type: 'notice', level: 'info', text: '已中断，继续处理插入的消息' });
    }
    this.session.status = 'working';
    return true;
  }
}

module.exports = { Steers };
