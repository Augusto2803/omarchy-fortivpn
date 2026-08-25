#!/usr/bin/env bash
# Install the io.github.augusto2803.fortivpn plugin on this machine.
#
# The bar widget alone needs nothing but this repo sitting in
# ~/.config/omarchy/plugins/ — `omarchy plugin add` does that much on its own.
# This script adds the parts that live outside the plugin folder: the
# `fortivpn` command on PATH and the VPN section of the Omarchy menu.
#
# It lists everything it will change and asks before touching anything.
#
#   ./install.sh            copy the plugin into place, then wire it up
#   ./install.sh --yes      accept the changes without prompting
#   ./install.sh --link     symlink instead (development; see the warning below)
#   ./install.sh --no-menu  skip the Omarchy menu entries

set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ID=$(jq -r .id "$SRC/manifest.json")
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"
BIN_DIR="$HOME/.local/bin"
MENU_FILE="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
BEGIN_MARK="// >>> $PLUGIN_ID — managed by install.sh, edits here are overwritten"
END_MARK="// <<< $PLUGIN_ID"

MODE=copy
WITH_MENU=1
ASSUME_YES=0

while (($# > 0)); do
  case $1 in
    --link) MODE=link; shift ;;
    --no-menu) WITH_MENU=0; shift ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    -h | --help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's|^# \?||'; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------- dependencies

for tool in jq openssl; do
  command -v "$tool" >/dev/null || { echo "install.sh: '$tool' is required" >&2; exit 1; }
done

# ---------------------------------------------------------------- consent

# Everything below writes outside this repo — into your shell config, your bar
# layout, your menu and your PATH. Say so plainly first and let the answer be
# no; nothing here is worth doing behind your back.
cat <<SUMMARY

This will change the following on this machine:

  $PLUGIN_DIR
      the plugin files ($MODE)
  $BIN_DIR/fortivpn
      a symlink to the bundled fortivpn command
  ~/.config/omarchy/shell.json
      adds the FortiVPN widget to the bar, if it is not already there
SUMMARY

if ((WITH_MENU)); then
  cat <<SUMMARY
  $MENU_FILE
      adds a VPN section, in a marked block, after backing the file up
SUMMARY
fi

if ! command -v openfortivpn >/dev/null; then
  cat <<SUMMARY
  system packages
      installs openfortivpn with 'omarchy pkg add'
SUMMARY
fi

cat <<'SUMMARY'

Nothing else is touched, and uninstall.sh reverses all of it.

SUMMARY

if ((!ASSUME_YES)); then
  if [[ -t 0 && -t 1 ]]; then
    if command -v gum >/dev/null; then
      gum confirm "Proceed?" || { say "Nothing changed."; exit 0; }
    else
      read -rp "Proceed? [y/N] " reply
      [[ $reply =~ ^[Yy] ]] || { say "Nothing changed."; exit 0; }
    fi
  else
    echo "install.sh: refusing to change your configuration without confirmation; pass --yes" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- packages

if ! command -v openfortivpn >/dev/null; then
  say "Installing openfortivpn"
  omarchy pkg add openfortivpn
fi

# ---------------------------------------------------------------- plugin files

if [[ $SRC == "$PLUGIN_DIR" || $SRC == "$(readlink -f "$PLUGIN_DIR" 2>/dev/null)" ]]; then
  say "Plugin already installed at $PLUGIN_DIR"
elif [[ $MODE == link ]]; then
  # Omarchy rejects symlinks inside a plugin folder (`omarchy plugin validate`
  # refuses them, and a copied plugin could otherwise point back at arbitrary
  # files). Linking the folder itself is not that, and the running shell does
  # load it — but it will not pass validation, so it is a development
  # convenience only, never how a published plugin should be installed.
  warn "Linking $PLUGIN_DIR -> $SRC (development mode; will not pass 'omarchy plugin validate')"
  mkdir -p "$PLUGINS_DIR"
  [[ -e $PLUGIN_DIR && ! -L $PLUGIN_DIR ]] &&
    { echo "install.sh: $PLUGIN_DIR exists and is not a symlink; remove it first" >&2; exit 1; }
  ln -sfn "$SRC" "$PLUGIN_DIR"
else
  say "Copying the plugin to $PLUGIN_DIR"
  mkdir -p "$PLUGIN_DIR"
  # --delete keeps a reinstall from leaving files behind that the plugin no
  # longer ships; .git is excluded so the copy is plugin files only.
  if command -v rsync >/dev/null; then
    rsync -a --delete --exclude .git --exclude .gitignore "$SRC/" "$PLUGIN_DIR/"
  else
    rm -rf "${PLUGIN_DIR:?}"/*
    (cd "$SRC" && tar --exclude=.git --exclude=.gitignore -cf - .) | tar -xf - -C "$PLUGIN_DIR"
  fi
fi

if omarchy plugin validate "$PLUGIN_DIR"; then
  say "Manifest validates"
else
  warn "'omarchy plugin validate' rejected $PLUGIN_DIR; the bar widget may not load"
fi

# ---------------------------------------------------------------- fortivpn on PATH

# The bar widget calls the copy bundled next to its QML, so this link is purely
# for you and for the menu entries below.
say "Linking the fortivpn command into $BIN_DIR"
mkdir -p "$BIN_DIR"
chmod +x "$PLUGIN_DIR/bin/fortivpn"
ln -sfn "$PLUGIN_DIR/bin/fortivpn" "$BIN_DIR/fortivpn"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH; the menu entries need it there" ;;
esac

# ---------------------------------------------------------------- bar widget

# The widget stays hidden until a tunnel is up, so enabling it changes nothing
# visible until you connect.
#
# A running shell only learns about a plugin directory it has walked, and the
# copy above landed after the last walk, so enabling straight away asks it about
# an id it has never seen. Rescan first, and give the walk a moment to land
# before retrying.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

SHELL_JSON="$HOME/.config/omarchy/shell.json"

in_bar_layout() {
  [[ -f $SHELL_JSON ]] || return 1
  jq -e --arg id "$PLUGIN_ID" \
    '[.bar.layout[]?[]? | select(.id == $id)] | length > 0' "$SHELL_JSON" >/dev/null 2>&1
}

if in_bar_layout; then
  # Re-enabling would move the widget back to the top of its section and throw
  # away wherever it was dragged to. Already in the layout is already done.
  say "Bar widget already in the bar; leaving its position alone"
else
  # A VPN indicator belongs next to the network one, so aim for that and fall
  # back to the section default when there is no network widget to anchor on.
  placement=(--section right)
  if [[ -f $SHELL_JSON ]] && jq -e \
    '[.bar.layout[]?[]? | select(.id == "omarchy.network")] | length > 0' "$SHELL_JSON" >/dev/null 2>&1; then
    placement=(--before omarchy.network)
  fi

  enabled=0
  for attempt in 1 2 3; do
    if omarchy plugin enable "$PLUGIN_ID" "${placement[@]}" >/dev/null 2>&1; then
      enabled=1
      break
    fi
    sleep 1
  done

  if ((enabled)); then
    say "Bar widget enabled (${placement[*]})"
  else
    warn "Could not enable the widget automatically. Run:"
    warn "  omarchy-shell shell rescanPlugins && omarchy plugin enable $PLUGIN_ID --section right"
  fi
fi

# ---------------------------------------------------------------- menu entries

if ((WITH_MENU)); then
  say "Adding the VPN section to the Omarchy menu"
  mkdir -p "$(dirname "$MENU_FILE")"
  [[ -f $MENU_FILE ]] || printf '{\n}\n' >"$MENU_FILE"
  cp "$MENU_FILE" "$MENU_FILE.bak.$(date +%s)"

  block=$(grep -v '^[[:space:]]*//' "$SRC/menu/omarchy-menu.jsonc" | grep -v '^[[:space:]]*$')

  # Drop any block a previous run left behind, so reinstalling replaces the
  # entries instead of duplicating the keys.
  # Blank lines are held back so the separator inserted above our own block
  # leaves with it, instead of one more piling up on every reinstall.
  stripped=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; blanks = 0; next }
    $0 == e { skip = 0; next }
    skip { next }
    /^[[:space:]]*$/ { blanks++; next }
    { for (; blanks > 0; blanks--) print ""; print }
    END { for (; blanks > 0; blanks--) print "" }
  ' "$MENU_FILE")

  # Insert before the closing brace of the root object. The line above the
  # insertion point needs a trailing comma or the JSONC will not parse; a
  # trailing comma on our own last entry is fine, the parser allows those.
  printf '%s\n' "$stripped" | awk \
    -v block="$BEGIN_MARK"$'\n'"$block"$'\n'"$END_MARK" '
    { lines[NR] = $0; if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) close_line = NR }
    END {
      if (!close_line) { for (i = 1; i <= NR; i++) print lines[i]; exit 1 }
      for (j = close_line - 1; j >= 1; j--)
        if (lines[j] !~ /^[[:space:]]*$/ && lines[j] !~ /^[[:space:]]*\/\//) break
      if (j >= 1 && lines[j] !~ /[,{[][[:space:]]*$/) lines[j] = lines[j] ","
      for (i = 1; i < close_line; i++) print lines[i]
      print ""
      print block
      for (i = close_line; i <= NR; i++) print lines[i]
    }
  ' >"$MENU_FILE.new"

  if [[ -s $MENU_FILE.new ]]; then
    mv "$MENU_FILE.new" "$MENU_FILE"
  else
    rm -f "$MENU_FILE.new"
    warn "Could not merge the menu entries; paste $SRC/menu/omarchy-menu.jsonc into $MENU_FILE by hand"
  fi

  if grep -q '"vpn"' "$MENU_FILE"; then
    say "Menu entries in place (the shell picks them up on save)"
  else
    warn "The VPN section is not in $MENU_FILE; add it from $SRC/menu/omarchy-menu.jsonc"
  fi
fi

# ---------------------------------------------------------------- first profile

if [[ -z $("$PLUGIN_DIR/bin/fortivpn" list) ]]; then
  say "No VPN profiles yet. Create your first one with:"
  say "  fortivpn new"
fi

say "Done. Undo any of this with ./uninstall.sh"
