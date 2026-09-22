#!/bin/zsh
# Join the app-owned loopback server without putting its password in argv.
export OPENCODE_SERVER_USERNAME=opencode
export OPENCODE_SERVER_PASSWORD="$(<"$HOME/Library/Application Support/Agent Display/control-token")"
exec "$HOME/.opencode/bin/opencode" attach http://127.0.0.1:4096 --dir "$HOME"
