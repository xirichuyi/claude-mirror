// The Windows terminal page. Bytes come from the app as base64 and keys go back as text; the app owns the SSH channel and the clipboard.
{
  const page = globalThis as any;
  const host = page.chrome.webview;
  const element = document.getElementById('terminal');
  const term = new page.Terminal({ fontFamily: '"Cascadia Mono", Consolas, monospace', fontSize: 13, cursorBlink: true, scrollback: 5000 });
  const fit = new page.FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(element);
  const send = (message: object) => host.postMessage(message);
  const size = () => { try { fit.fit(); } catch { } return { c: term.cols, r: term.rows }; };

  term.onData((d: string) => send({ t: 'in', d }));
  term.onBinary((d: string) => send({ t: 'in', d, b: true }));
  term.onResize(({ cols, rows }: { cols: number, rows: number }) => send({ t: 'size', c: cols, r: rows }));
  new ResizeObserver(() => size()).observe(element);

  const copy = () => {
    if (!term.hasSelection()) return false;
    send({ t: 'copy', d: term.getSelection() });
    term.clearSelection();
    return true;
  };
  term.attachCustomKeyEventHandler((e: KeyboardEvent) => {
    if (e.type !== 'keydown') return true;
    const key = e.key.toLowerCase();
    if (e.ctrlKey && e.shiftKey && key === 'c') { copy(); return false; }
    if (e.ctrlKey && e.shiftKey && key === 'v') { send({ t: 'paste' }); return false; }
    if (e.ctrlKey && !e.shiftKey && key === 'c' && copy()) return false;
    if (e.ctrlKey && e.code === 'Backquote') { send({ t: 'toggle' }); return false; }
    return true;
  });
  // Right click copies a selection, otherwise pastes, as in Windows Terminal.
  document.addEventListener('contextmenu', e => { e.preventDefault(); if (!copy()) send({ t: 'paste' }); });

  const decode = (text: string) => Uint8Array.from(atob(text), c => c.charCodeAt(0));
  host.addEventListener('message', (e: MessageEvent) => {
    const m = e.data;
    if (m.o) term.write(decode(m.o));
    if (m.p !== undefined) term.paste(m.p);
    if (m.theme) term.options.theme = m.theme;
    if (m.reset) term.reset();
    if (m.focus) term.focus();
  });
  send({ t: 'ready', ...size() });
  term.focus();
}
