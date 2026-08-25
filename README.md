# FortiVPN for Omarchy

A FortiGate SSL VPN indicator for the [Omarchy](https://omarchy.org/) bar,
built on [openfortivpn](https://github.com/adrienverge/openfortivpn).

The icon **is only in the bar while the tunnel is up**. No VPN, nothing in the
bar. One click tears the tunnel down; connecting happens from the Omarchy menu
or the CLI, in a floating terminal.

| | |
|---|---|
| Plugin id | `augusto2803.fortivpn` |
| Kind | `bar-widget` |
| Requires | Omarchy 4, `openfortivpn`, `jq`, `openssl`, `gum` |

## Why it works this way

Authentication with 2FA needs a human typing a token that rotates every 30
seconds. That does not fit in a config file, and it does not fit in a systemd
unit that starts at boot. So:

- **Connect** opens a floating terminal and runs `openfortivpn` in the
  foreground. You type the password and the token there. That window holds the
  connection — closing it or pressing `Ctrl+C` brings the VPN down.
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
~/.config/omarchy/plugins/augusto2803.fortivpn/install.sh
```

Or, from a clone anywhere on disk, `./install.sh` does both steps at once. It
copies the plugin into `~/.config/omarchy/plugins/`, links the command, enables
the widget, and merges the menu entries. `--link` symlinks instead of copying
for development, and `--no-menu` skips the menu.

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

On the bar icon: **left click** disconnects, **right click** opens status in a
terminal, **middle click** forces a re-read.

`fortivpn status --json` is what the widget consumes:

```json
{"state":"connected","profile":"work","ip":"10.212.134.9","iface":"fortivpn0","uptime":3720}
```

`state` is one of `disconnected`, `connecting`, `connected`.

## Widget settings

In `~/.config/omarchy/shell.json`, on the widget's layout entry:

```json
{ "id": "augusto2803.fortivpn", "refreshIntervalSec": 5, "alwaysShow": false }
```

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `5` | How often state is re-read. During a connection in progress the widget re-reads every second on its own. |
| `alwaysShow` | `false` | Keep the icon in the bar while disconnected, dimmed, so a click connects instead of doing nothing. |

The widget also registers an IPC target:

```bash
omarchy-shell augusto2803.fortivpn refresh
omarchy-shell augusto2803.fortivpn toggle
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

`Connect` runs in a terminal, so `sudo` asks for the password right there. It
is the only step that needs root — creating, editing, and deleting profiles
never do. `Disconnect` has no terminal: it uses `sudo -n` when it can and falls
back to `pkexec` (the polkit dialog) otherwise.

You can remove both prompts with a sudoers rule, but **weigh it first**:
`openfortivpn` accepts `--pppd-plugin`, which loads an arbitrary `.so` as root.
A `NOPASSWD` rule that is too broad on that binary is privilege escalation.
Profiles live in your home directory and are writable by you, so a rule that
lets any config through is equally an escalation. If you do it, pin the whole
command line, with no wildcard:

```
# /etc/sudoers.d/fortivpn  (edit with: visudo -f /etc/sudoers.d/fortivpn)
you ALL=(root) NOPASSWD: /usr/bin/openfortivpn -c /etc/openfortivpn/work.conf --pppd-ifname\=fortivpn0
```

Note that this means keeping that particular profile under `/etc`, root-owned,
rather than in `~/.config/fortivpn/profiles`.

## Known limitations

- **No automatic reconnect.** openfortivpn's `--persistent` is deliberately
  left out: with 2FA, a reconnect would hang waiting for a fresh token that
  nobody is there to type. If it drops, you reconnect.
- **One tunnel at a time.** `pgrep -x openfortivpn` assumes a single process.
- **Username + password (+ 2FA) only.** For SAML/SSO, openfortivpn has
  `--saml-login`; the connect path would need that flag and the browser would
  become part of the login.

## License

MIT. See [LICENSE](LICENSE).
