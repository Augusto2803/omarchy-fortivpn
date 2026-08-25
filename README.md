# FortiVPN for Omarchy

A FortiGate SSL VPN indicator for the [Omarchy](https://omarchy.org/) bar,
built on [openfortivpn](https://github.com/adrienverge/openfortivpn).

The icon **is only in the bar while the tunnel is up**. No VPN, nothing in the
bar. One click tears the tunnel down; connecting happens from the Omarchy menu
or the CLI, in a floating terminal.

| | |
|---|---|
| Plugin id | `io.github.augusto2803.fortivpn` |
| Kind | `bar-widget` |
| Requires | Omarchy 4, `openfortivpn`, `jq`, `openssl`, `gum` |

## Why it works this way

Authentication with 2FA needs a human typing a token that rotates every 30
seconds. That does not fit in a config file, and it does not fit in a systemd
unit that starts at boot. So:

- **Connect** opens a floating terminal to collect the password and the token,
  because a terminal is the only place to ask for them. It then starts
  `openfortivpn` as a transient systemd unit and closes as soon as the tunnel
  is up. The window holds nothing the connection needs — the tunnel outlives
  it, and `fortivpn down` is what ends it.
- The secrets reach the detached process through a copy of the profile written
  to `$XDG_RUNTIME_DIR/fortivpn/<name>.conf` (tmpfs, mode 600) with `password`
  and `otp` appended. It is deleted as soon as the handshake settles; the
  profile itself never gains a password it did not already have.
- The handshake is logged to `~/.local/state/fortivpn/<name>.log`, shown live
  in the window while it connects and left behind for when it fails.
- **Disconnect** sends `SIGINT`, which is openfortivpn's clean shutdown: it
  removes the routes and the DNS registration before exiting.
- The bar widget only **reads** state — does the `fortivpn0` interface have an
  address? — so it needs no privilege at all.

## Install

```bash
omarchy plugin add https://github.com/Augusto2803/omarchy-fortivpn.git --enable
```

That is enough for the bar widget. To also get the `fortivpn` command on your
`PATH` and the **VPN** section in the Omarchy menu, run the installer from the
plugin directory:

```bash
~/.config/omarchy/plugins/io.github.augusto2803.fortivpn/install.sh
```

Or, from a clone anywhere on disk, `./install.sh` does both steps at once. It
copies the plugin into `~/.config/omarchy/plugins/`, links the command, enables
the widget, and merges the menu entries.

It prints every file it will change and asks before touching any of them, so
you can say no. `--yes` accepts without prompting (and is required when there
is no terminal to ask in), `--no-menu` skips the menu entries, and `--link`
symlinks instead of copying for development. Re-running it is safe: it replaces
its own menu block rather than duplicating keys, and leaves a widget you have
already positioned where it is. [`uninstall.sh`](#uninstall) reverses all of it.

## First profile

```bash
fortivpn new
```

The wizard asks for a name, gateway host, port, and username, writes
`~/.config/fortivpn/profiles/<name>.conf` at mode 600, and offers to pin the
gateway's certificate. Non-interactively:

```bash
fortivpn new work --host vpn.example.com --username your.user
fortivpn trust work
```

`fortivpn trust` reads the gateway's certificate and pins its SHA256 digest as
`trusted-cert`. It is the same value openfortivpn prints after refusing an
unknown certificate on a first connection — this just gets it out of the way
beforehand. Skip it and your first connection will fail with a certificate
error, which is expected; run `fortivpn trust <profile>` then and reconnect.

One `.conf` per gateway. See [`config/profile.conf.example`](config/profile.conf.example)
for every option with commentary.

## Usage

From the Omarchy menu (`Super`), under **VPN**: Connect, Disconnect, Status,
and a **Profiles** submenu with Set Default, New, Edit, Pin Certificate,
Rename, and Delete.

From the terminal:

```
Connection
  fortivpn up [profile]        Connect in a floating terminal (password + 2FA token)
  fortivpn down                Disconnect, tearing down routes and DNS cleanly
  fortivpn toggle [profile]    Connect when down, disconnect when up
  fortivpn status [--json]     Profile, tunnel address, uptime
  fortivpn is-up               Exit 0 while the tunnel is up

Profiles  (~/.config/fortivpn/profiles/<name>.conf, mode 600)
  fortivpn list                List profiles
  fortivpn new [name] [opts]   Create a profile  (--host --port --username --split-tunnel)
  fortivpn edit [profile]      Open a profile in $EDITOR
  fortivpn delete [profile]    Delete a profile  (--yes to skip the prompt)
  fortivpn rename <old> [new]  Rename a profile
  fortivpn use [profile]       Set the default profile
  fortivpn trust [profile]     Pin the gateway's certificate fingerprint
```

Omitting `[profile]` opens a `gum` picker when there is a terminal to show it
in, and falls back to the default profile everywhere else.

On the bar icon: **left click** toggles the tunnel — disconnect while it is up,
and connect when the icon is showing at all while down (`alwaysShow`) — **right
click** opens status in a terminal, **middle click** forces a re-read.

`fortivpn status --json` is what the widget consumes:

```json
{"state":"connected","profile":"work","ip":"10.212.134.9","iface":"fortivpn0","uptime":3720}
```

`state` is one of `disconnected`, `connecting`, `connected`.

## Widget settings

In `~/.config/omarchy/shell.json`, on the widget's layout entry:

```json
{ "id": "io.github.augusto2803.fortivpn", "refreshIntervalSec": 5, "alwaysShow": false }
```

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `5` | How often state is re-read. During a connection in progress the widget re-reads every second on its own. |
| `alwaysShow` | `false` | Keep the icon in the bar while disconnected, dimmed, so a click connects instead of doing nothing. |

The widget also registers an IPC target:

```bash
omarchy-shell io.github.augusto2803.fortivpn refresh
omarchy-shell io.github.augusto2803.fortivpn toggle
```

## DNS

Omarchy runs `systemd-resolved`, and `/usr/bin/resolvconf` is the `resolvectl`
shim. With `use-resolvconf = 1` in the profile, the company's DNS servers are
registered **against the `fortivpn0` interface** — real split-DNS, rather than
overwriting the system's `/etc/resolv.conf`. To see what the tunnel pushed:

```bash
resolvectl status fortivpn0
```

## The sudo password

Two commands in this plugin cross a privilege boundary, and these are them in
full:

```bash
# Connect — sudo prompts in the floating terminal, then hands the tunnel to PID 1
sudo systemd-run --quiet --collect --unit=fortivpn-tunnel \
  --property=Type=exec --property=KillSignal=SIGINT \
  --property=StandardOutput=append:$HOME/.local/state/fortivpn/<name>.log \
  --property=StandardError=append:$HOME/.local/state/fortivpn/<name>.log \
  /usr/bin/openfortivpn -c "$XDG_RUNTIME_DIR/fortivpn/<name>.conf" --pppd-ifname=fortivpn0

# Disconnect — sudo -n when a cached credential allows it, pkexec otherwise
pkill -INT -f -- '^(/[^ ]*/)?openfortivpn( .*)? --pppd-ifname[= ]fortivpn0( |$)'
```

Nothing else needs root: creating, editing, deleting and pinning profiles never
do, and the bar widget only reads whether `fortivpn0` has an address.

`Connect` runs in a terminal, so `sudo` asks for the password right there.
`Disconnect` has no terminal: it uses `sudo -n` when it can and falls back to
`pkexec` (the polkit dialog) otherwise.

**Why `systemd-run` and not just `sudo openfortivpn &`.** Since sudo 1.9.14,
`use_pty` is the default: sudo runs its command in a pseudo-terminal, and when
that command exits it tears the pty down and kills whatever is left in its
session. A tunnel detached with `setsid` under sudo is therefore killed before
it writes its first line — which looks exactly like a connection that failed
for no reason at all. `systemd-run` sidesteps it: sudo only asks PID 1 to start
a transient unit and returns, and the tunnel belongs to systemd, outliving both
sudo and the window. `Type=exec` makes that ask wait until `openfortivpn` has
actually been exec'd, so a launch that never got off the ground is reported
here rather than as a process that mysteriously fails to appear.

Disconnecting describes its target **by pattern**, inside the privileged call,
rather than looking up a PID first and handing that number to `sudo`. A PID
looked up a moment earlier can be recycled onto an unrelated process, and the
signal would then land on it as root. Resolving the target at signal time closes
that window.

The pattern is deliberately narrow. It is anchored at the start of the command
line, so the `sudo openfortivpn …` parent and any other program that merely
mentions the flag do not match, and it requires the interface this plugin
starts its own tunnels on — so a second user's tunnel, or one of your own on
another interface, is never signalled.

People often ask how to make the password prompt go away with a `NOPASSWD`
sudoers rule. **This plugin does not ship one and does not recommend writing
one.** `openfortivpn` accepts `--pppd-plugin`, which loads an arbitrary shared
object as root, so a passwordless rule on that binary hands every process
running as you a route to root. Pinning the exact command line narrows it, but
profiles live in your home directory and are writable by you, so the config
that rule points at is still attacker-controlled unless you also move it to a
root-owned path. Two prompts per session is a reasonable price; if you disagree,
read `sudoers(5)` and `openfortivpn(1)` in full and own the consequences.

## Known limitations

- **No automatic reconnect.** openfortivpn's `--persistent` is deliberately
  left out: with 2FA, a reconnect would need a fresh token, and by then there is
  no terminal left to type one in. If it drops, you reconnect.
- **One tunnel at a time, on `fortivpn0`.** Status, uptime and disconnect all
  match openfortivpn processes started with `--pppd-ifname=fortivpn0`, and take
  the first. A tunnel on another interface is invisible here — deliberately, so
  this plugin never touches one it did not start. `Connect` refuses while a
  handshake for this interface is already in flight.
- **Username + password (+ 2FA) only.** For SAML/SSO, openfortivpn has
  `--saml-login`; the connect path would need that flag and the browser would
  become part of the login.

## Uninstall

```bash
~/.config/omarchy/plugins/io.github.augusto2803.fortivpn/uninstall.sh
```

It disconnects an open tunnel first, removes the bar widget, the `fortivpn`
symlink, and the menu block, and tells you where everything it left behind is.
Your profiles survive by default.

| Flag | Also does |
|---|---|
| `--profiles` | deletes `~/.config/fortivpn` and every profile in it |
| `--plugin` | deletes the installed plugin directory |
| `--all` | both of the above |
| `--yes` | skips the confirmations |

To remove the plugin files without the script:

```bash
omarchy plugin remove io.github.augusto2803.fortivpn
```

## License

MIT. See [LICENSE](LICENSE).
