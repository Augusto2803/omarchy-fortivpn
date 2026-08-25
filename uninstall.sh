#!/usr/bin/env bash
# Undo what install.sh did, on this machine.
#
# Removes the menu entries, the `fortivpn` command from PATH, and the bar
# widget. Your VPN profiles are left alone unless you ask for them to go.
#
#   ./uninstall.sh                remove the wiring, keep profiles and plugin files
#   ./uninstall.sh --profiles     also delete ~/.config/fortivpn and the logs in
#                                 ~/.local/state/fortivpn
#   ./uninstall.sh --plugin       also delete the installed plugin directory
#   ./uninstall.sh --all --yes    everything, no prompts

set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ID=$(jq -r .id "$SRC/manifest.json" 2>/dev/null || echo io.github.augusto2803.fortivpn)
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
BIN_LINK="$HOME/.local/bin/fortivpn"
MENU_FILE="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
PROFILE_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/fortivpn"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/fortivpn"
RUNTIME_ROOT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fortivpn"
BEGIN_MARK="// >>> $PLUGIN_ID — managed by install.sh, edits here are overwritten"
END_MARK="// <<< $PLUGIN_ID"

DROP_PROFILES=0
DROP_PLUGIN=0
ASSUME_YES=0

while (($# > 0)); do
  case $1 in
    --profiles) DROP_PROFILES=1; shift ;;
    --plugin) DROP_PLUGIN=1; shift ;;
    --all) DROP_PROFILES=1; DROP_PLUGIN=1; shift ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    -h | --help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's|^# \?||'; exit 0 ;;
    *) echo "uninstall.sh: unknown option $1" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

confirm() {
  ((ASSUME_YES)) && return 0
  [[ -t 0 && -t 1 ]] || { warn "not a terminal; pass --yes to confirm '$1'"; return 1; }
  if command -v gum >/dev/null; then gum confirm "$1"; else
    read -rp "$1 [y/N] " reply && [[ $reply =~ ^[Yy] ]]
  fi
}

# ---------------------------------------------------------------- tunnel first

# Removing the tooling while a tunnel is up would strand its routes and DNS
# with no convenient way left to take them down.
if [[ -x $SRC/bin/fortivpn ]] && [[ $("$SRC/bin/fortivpn" status --json 2>/dev/null | jq -r '.state? // "disconnected"') != disconnected ]]; then
  warn "A FortiVPN tunnel is still up."
  if confirm "Disconnect it before uninstalling?"; then
    "$SRC/bin/fortivpn" down || warn "Could not disconnect; do it by hand before removing the plugin"
    sleep 2
  fi
fi

# ---------------------------------------------------------------- bar widget

if omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1; then
  say "Bar widget disabled and removed from the bar"
else
  warn "Bar widget was not enabled (or the shell is not running)"
fi

# ---------------------------------------------------------------- command

if [[ -L $BIN_LINK ]]; then
  target=$(readlink -f "$BIN_LINK" 2>/dev/null || true)
  # Only reclaim a link that is actually ours; a `fortivpn` someone else put
  # there is theirs to remove.
  if [[ $target == *"/$PLUGIN_ID/bin/fortivpn" || $target == "$SRC/bin/fortivpn" ]]; then
    rm -f "$BIN_LINK"
    say "Removed $BIN_LINK"
  else
    warn "$BIN_LINK points somewhere else ($target); leaving it"
  fi
elif [[ -e $BIN_LINK ]]; then
  warn "$BIN_LINK is a real file, not our symlink; leaving it"
fi

# ---------------------------------------------------------------- menu entries

if [[ -f $MENU_FILE ]] && grep -qF "$BEGIN_MARK" "$MENU_FILE"; then
  cp "$MENU_FILE" "$MENU_FILE.bak.$(date +%s)"
  # Same held-back blanks as install.sh: the separator line above the block is
  # ours, so it goes when the block does.
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; blanks = 0; next }
    $0 == e { skip = 0; next }
    skip { next }
    /^[[:space:]]*$/ { blanks++; next }
    { for (; blanks > 0; blanks--) print ""; print }
    END { for (; blanks > 0; blanks--) print "" }
  ' "$MENU_FILE" >"$MENU_FILE.new" && mv "$MENU_FILE.new" "$MENU_FILE"
  say "Removed the VPN section from the Omarchy menu"
else
  warn "No managed menu block found; if you pasted the entries by hand, remove them yourself"
fi

# ---------------------------------------------------------------- profiles

if ((DROP_PROFILES)); then
  if [[ -d $PROFILE_ROOT ]] && confirm "Delete $PROFILE_ROOT and every VPN profile in it?"; then
    rm -rf "${PROFILE_ROOT:?}"
    say "Deleted $PROFILE_ROOT"
  fi
  # The connection logs are the other thing this plugin leaves in your home,
  # so they go with the profiles rather than outliving them.
  if [[ -d $STATE_ROOT ]]; then
    rm -rf "${STATE_ROOT:?}"
    say "Deleted $STATE_ROOT"
  fi
elif [[ -d $PROFILE_ROOT ]]; then
  say "Your profiles are untouched in $PROFILE_ROOT (remove them with --profiles)"
fi

# Whatever a killed connect left behind on tmpfs. It would go at logout anyway,
# but a file that once held a password should not wait for one.
if [[ -d $RUNTIME_ROOT ]]; then
  rm -rf "${RUNTIME_ROOT:?}"
fi

# ---------------------------------------------------------------- plugin files

if ((DROP_PLUGIN)); then
  if [[ $SRC == "$PLUGIN_DIR" ]]; then
    # Deleting the directory this script is running from is a good way to lose
    # the rest of the script, so hand the job to the tool built for it.
    warn "Running from inside $PLUGIN_DIR — finish with: omarchy plugin remove $PLUGIN_ID --yes"
  elif [[ -e $PLUGIN_DIR ]] && confirm "Delete $PLUGIN_DIR?"; then
    rm -rf "${PLUGIN_DIR:?}"
    say "Deleted $PLUGIN_DIR"
  fi
elif [[ -e $PLUGIN_DIR ]]; then
  say "Plugin files left in $PLUGIN_DIR (remove with: omarchy plugin remove $PLUGIN_ID)"
fi

say "Done."
