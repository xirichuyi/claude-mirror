A="@AGENT@"
M="$HOME/.local/share/claude-mirror/node/bin"
if [ -x "$M/node" ]; then
  PATH="$M:$PATH"
elif ! command -v node >/dev/null 2>&1; then
  for N in "$HOME"/.nvm/versions/node/*/bin/node "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node "$HOME"/.fnm/node-versions/*/installation/bin/node "$HOME"/.volta/bin/node "$HOME"/.asdf/shims/node /usr/local/bin/node /opt/homebrew/bin/node; do
    [ -x "$N" ] && PATH="$(dirname "$N"):$PATH"
  done
fi
PATH="$PATH:$HOME/.local/bin:$HOME/.claude/local:$HOME/.npm-global/bin"
export PATH
command -v node >/dev/null 2>&1 || { echo __RCC_NO_NODE__; exit 0; }
V="$(node --version 2>/dev/null)"; V="${V#v}"; J="${V%%.*}"; R="${V#*.}"; R="${R%%.*}"
case "$J$R" in *[!0-9]*|"") ;; *) if [ "$J" -lt 18 ] || { [ "$J" -eq 18 ] && [ "$R" -lt 14 ]; }; then echo "__RCC_OLD_NODE__ v$V"; exit 0; fi ;; esac
[ -f "$A" ] || { echo __RCC_INSTALL__; exit 0; }
exec node "$A"
