import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// FortiGate SSL VPN indicator.
//
// By default the widget takes no room in the bar until a tunnel is up: no VPN,
// no icon. Set `alwaysShow` to keep it there as a connect button.
//
// Connecting is deliberately not done from the click. openfortivpn asks for a
// password and then a 2FA token that rotates every 30 seconds, so it needs a
// terminal a human can type into — the CLI opens a floating one.
BarWidget {
  id: root
  moduleName: "io.github.augusto2803.fortivpn"

  property var status: Model.DISCONNECTED

  readonly property bool connected: status.connected === true
  readonly property bool connecting: status.connecting === true
  readonly property bool alwaysShow: setting("alwaysShow", false) === true

  // Countdown of fast re-reads owed after a click. A plain settle.restart()
  // would assign `running` imperatively and blow away its binding, so the
  // timer stays declarative and this is what it watches.
  property int settleTicks: 0
  readonly property int pollInterval: Math.max(2, setting("refreshIntervalSec", 5)) * 1000

  // The plugin is installed by cloning this repo, which puts no CLI on PATH.
  // Resolving the bundled script against this file's own location keeps the
  // widget working straight out of `omarchy plugin add`, with or without the
  // optional install.sh.
  readonly property string cli: {
    var url = String(Qt.resolvedUrl("bin/fortivpn"))
    return decodeURIComponent(url.indexOf("file://") === 0 ? url.substring(7) : url)
  }

  visible: connected || connecting || alwaysShow
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function connect() {
    if (root.bar) root.bar.run(Model.quote(root.cli) + " up")
    settleTicks = 8
  }

  function disconnect() {
    if (root.bar) root.bar.run(Model.quote(root.cli) + " down")
    settleTicks = 5
  }

  function toggle() {
    if (root.connected) root.disconnect()
    else if (!root.connecting) root.connect()
  }

  IpcHandler {
    target: "io.github.augusto2803.fortivpn"

    function refresh(): void { root.broadcast("refresh") }
    function connect(): void { root.broadcast("connect") }
    function disconnect(): void { root.broadcast("disconnect") }
    function toggle(): void { root.broadcast("toggle") }
  }

  Process {
    id: statusProc
    command: [root.cli, "status", "--json"]
    running: false
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.status = exitCode === 0 ? Model.parse(statusOut.text) : Model.DISCONNECTED
    }
  }

  Timer {
    interval: root.pollInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // While the state is in flight — mid-handshake, or the second right after a
  // click — it changes on a scale of seconds, so it is worth re-reading faster
  // than the configured interval until it settles.
  Timer {
    id: settle
    interval: 1000
    repeat: true
    running: root.connecting || root.settleTicks > 0
    triggeredOnStart: true
    onTriggered: {
      if (root.settleTicks > 0) root.settleTicks--
      root.refresh()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{F0582}"
    active: root.connected
    dimmed: root.connecting || (!root.connected && root.alwaysShow)
    tooltipText: Model.tooltip(root.status)
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
      else if (mouseButton === Qt.MiddleButton) root.refresh()
      else if (mouseButton === Qt.RightButton && root.bar)
        root.bar.run("omarchy-launch-floating-terminal-with-presentation "
          + Model.quote(Model.quote(root.cli) + " status"))
    }
  }
}
