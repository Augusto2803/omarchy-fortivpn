.pragma library

// Turns `fortivpn status --json` into what the bar needs to draw. Kept out of
// the QML so it can be read — and exercised — without starting the shell.

var DISCONNECTED = {
  state: "disconnected",
  profile: "",
  ip: "",
  uptime: 0,
  connected: false,
  connecting: false
}

// An unreadable or malformed payload is reported as "disconnected" rather than
// as an error state: the CLI only fails to answer when there is nothing to
// answer about, and a widget stuck on an error glyph helps nobody.
function parse(raw) {
  if (!raw) return DISCONNECTED

  var data
  try {
    data = JSON.parse(String(raw).trim())
  } catch (e) {
    return DISCONNECTED
  }
  if (!data || !data.state) return DISCONNECTED

  return {
    state: String(data.state),
    profile: data.profile || "",
    ip: data.ip || "",
    uptime: data.uptime || 0,
    connected: data.state === "connected",
    connecting: data.state === "connecting"
  }
}

function tooltip(status) {
  if (status.connecting) return "FortiVPN · connecting…"
  if (!status.connected) return "FortiVPN · disconnected\nClick to connect"

  var parts = ["FortiVPN"]
  if (status.profile) parts.push(status.profile)
  if (status.ip) parts.push(status.ip)

  var line = parts.join(" · ")
  var elapsed = formatUptime(status.uptime)
  if (elapsed) line += " · " + elapsed

  return line + "\nClick to disconnect"
}

// Sub-minute uptimes are noise on a tunnel that just came up, so they read as
// no duration at all rather than as a number that changes every second.
function formatUptime(seconds) {
  seconds = Math.max(0, Math.floor(seconds || 0))
  if (seconds < 60) return ""

  var hours = Math.floor(seconds / 3600)
  var minutes = Math.floor((seconds % 3600) / 60)
  if (hours === 0) return minutes + "m"
  return hours + "h" + (minutes < 10 ? "0" : "") + minutes
}

// The bar hands commands to `bash -lc`, so any path that reaches it has to
// survive word splitting. Single quotes with the standard '\'' escape are the
// only form bash treats as fully literal.
function quote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}
