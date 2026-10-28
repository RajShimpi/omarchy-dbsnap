import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// DB Snapshots. scripts/dbsnap finds databases in project .env files,
// ~/.config/omarchy/dbsnap.json, running Docker containers and the local
// PostgreSQL server, and only ever dumps or restores ones on this machine.
// Restore asks first and saves a "before restore" snapshot. Every monitor has
// its own bar running this file: the helper's lock makes them take turns, and
// `list` reports an operation started anywhere (another bar, omnisearch).
Panel {
  id: root
  moduleName: "techspawn.dbsnap"
  ipcTarget: "techspawn.dbsnap"
  manageIpc: true

  readonly property string helper: Qt.resolvedUrl("scripts/dbsnap").toString().replace(/^file:\/\//, "")
  readonly property string home: Quickshell.env("HOME")
  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(root.fg, 1.6)
  readonly property string font: root.bar ? root.bar.fontFamily : Style.font.family

  // Nerd Font (Material Design) glyphs: md-database, md-database_clock, md-camera, md-restore,
  // md-database_plus, md-delete, md-history, md-web, md-folder_open, md-pencil, md-refresh,
  // md-docker, md-server, md-file_document_outline, md-alert_circle_outline, md-shield_lock_outline, md-reload.
  readonly property var glyphs: ({ db: 0xf01bc, dbBusy: 0xf163f, snap: 0xf0100, restore: 0xf099b, copy: 0xf01ba,
                                   del: 0xf01b4, history: 0xf02da, remote: 0xf059f, folder: 0xf0770, edit: 0xf03eb,
                                   refresh: 0xf0450, docker: 0xf0868, server: 0xf048b, file: 0xf09ee,
                                   alert: 0xf05d6, shield: 0xf0ccc, spin: 0xf0453 })
  function glyph(name) { return String.fromCodePoint(glyphs[name]) }

  property var targets: []
  property var snaps: []
  property var running: null       // { op, id, file, started } of an operation in progress anywhere
  property var listErrors: []
  property string store: ""
  property int keep: 10
  property bool loaded: false
  property string busy: ""         // what this bar started: a target id or a snapshot file
  property string busyText: ""
  property string armed: ""        // "delete:<file>" waiting for the second click
  property string status: ""
  property bool statusIsError: false
  property bool showRemote: false
  property bool showErrors: false
  property var expanded: ({})
  property var confirm: null       // { mode: "restore" | "copy", snap, target } while the dialog is up
  property real nowSec: Date.now() / 1000

  readonly property bool working: busy !== "" || running !== null
  readonly property var localTargets: targets.filter(function(t) { return t.local })
  readonly property var remoteTargets: targets.filter(function(t) { return !t.local })
  readonly property var sections: {
    var groups = [{ title: "PROJECTS", kinds: ["env", "config"] },
                  { title: "DOCKER CONTAINERS", kinds: ["docker"] },
                  { title: "OTHER DATABASES ON THIS MACHINE", kinds: ["server"] }]
    return groups.map(function(g) {
      return { title: g.title, items: root.localTargets.filter(function(t) { return g.kinds.indexOf(t.kind) >= 0 }) }
    }).filter(function(g) { return g.items.length > 0 })
  }
  readonly property var orphans: snaps.filter(function(s) { return !root.targets.some(function(t) { return t.id === s.id }) })
  readonly property real totalBytes: snaps.reduce(function(sum, s) { return sum + s.size }, 0)
  readonly property string storeShort: store.indexOf(home + "/") === 0 ? "~" + store.slice(home.length) : store

  readonly property string runningText: {
    if (running) {
      const t = targets.filter(function(x) { return x.id === running.id })[0]
      const name = t ? t.db : (running.id || "").split(":").pop()
      const verb = running.op === "restore" ? "Restoring " + name
               : running.op === "snapshot" ? "Saving a snapshot of " + name
               : running.op === "delete" ? "Deleting a snapshot" : "Pruning " + name
      const secs = Math.max(0, Math.round(nowSec - (running.started || nowSec)))
      return verb + " · " + (secs < 60 ? secs + " s" : Math.floor(secs / 60) + " min " + (secs % 60) + " s")
    }
    return busy !== "" ? busyText : ""
  }

  readonly property string confirmMessage: {
    if (!confirm) return ""
    var t = confirm.target, s = confirm.snap
    var from = "the snapshot from " + when(s.at) + (s.label ? " (" + s.label + ")" : "")
    if (confirm.mode === "copy")
      return "Restore " + from + " into a new " + (t.engine === "sqlite" ? "file" : "database") + " next to " + t.db
             + "?\n\n" + t.db + " itself is not changed."
    return "Replace " + t.db + " (" + t.project + ") with " + from + "?\n\nEverything in it now is replaced. "
           + "A 'before restore' snapshot of the current data is saved first. Stop the app that uses it before you restore."
  }

  function refresh() { if (!listProc.running) listProc.running = true }

  function run(args, key, text) {
    if (actProc.running) return
    busy = key
    busyText = text
    armed = ""
    status = ""
    statusIsError = false
    actProc.command = [helper].concat(args)
    actProc.running = true
  }

  function snapshot(t) {
    var note = noteField.text.trim()
    run(["snapshot", t.id].concat(note ? [note] : []), t.id, "Saving a snapshot of " + t.db + "…")
    noteField.text = ""
  }

  function askRestore(snap, target, mode) {
    confirm = { mode: mode, snap: snap, target: target }
    confirmDialog.selectedIndex = 0  // Enter on its own cancels
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }
  function closeConfirm() {
    confirm = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function doConfirm() {
    var c = confirm
    closeConfirm()
    if (!c) return
    if (c.mode === "copy")
      run(["restore", c.snap.file, "--yes", "--copy"], c.snap.file, "Restoring into a new " + (c.target.engine === "sqlite" ? "file" : "database") + "…")
    else
      run(["restore", c.snap.file, "--yes"], c.snap.file, "Saving a safety snapshot, then restoring " + c.target.db + "…")
  }

  function arm(key) { armed = key; disarm.restart() }
  function toggleExpanded(id) { var e = Object.assign({}, expanded); e[id] = !e[id]; expanded = e }
  function snapsFor(id) { return snaps.filter(function(s) { return s.id === id }) }
  function engineName(e) { return e === "postgres" ? "PostgreSQL" : e === "mysql" ? "MySQL/MariaDB" : e === "sqlite" ? "SQLite" : e }
  function kindGlyph(t) { return glyph(t.kind === "docker" ? "docker" : t.kind === "server" ? "server" : t.engine === "sqlite" ? "file" : "db") }

  function size(b) {
    if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GB"
    if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB"
    return Math.max(1, Math.round(b / 1024)) + " KB"
  }
  function when(ts) {
    var d = new Date(ts * 1000), s = Date.now() / 1000 - ts
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + " min ago"
    if (s < 86400) return Math.floor(s / 3600) + " h ago · " + Qt.formatDateTime(d, "HH:mm")
    if (s < 7 * 86400) return Qt.formatDateTime(d, "ddd HH:mm")
    return Qt.formatDateTime(d, "d MMM yyyy, HH:mm")
  }

  onOpenedChanged: {
    if (opened) {
      armed = ""
      confirm = null
      if (!actProc.running) status = ""
      nowSec = Date.now() / 1000
      refresh()
    }
  }

  Process {
    id: listProc
    command: [root.helper, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          const d = JSON.parse(text)
          if (d.error) { root.status = d.error; root.statusIsError = true; return }
          root.targets = d.targets || []
          root.snaps = d.snapshots || []
          root.running = d.running || null
          root.listErrors = d.errors || []
          root.store = d.store || ""
          root.keep = d.keep === undefined ? 10 : d.keep
          root.loaded = true
        } catch (e) {
          root.status = "Couldn't read the list of databases. Run scripts/dbsnap list in a terminal to see why."
          root.statusIsError = true
        }
      }
    }
  }

  Process {
    id: actProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = null
        try { d = JSON.parse(text) } catch (e) {}
        root.statusIsError = !d || !!d.error
        if (!d) root.status = "Something went wrong. Run scripts/dbsnap in a terminal to see why."
        else if (d.error) root.status = d.error
        else if (d.into !== undefined) root.status = "Restored into " + d.into + ". The original was not changed."
        else if (d.safety !== undefined) root.status = "Restored" + (d.warnings ? " with " + d.warnings + " warnings" : "") + ". The data from before is kept as a 'before restore' snapshot."
        else if (d.file) root.status = "Snapshot saved (" + root.size(d.size) + ")" + (d.pruned ? ". " + d.pruned + " older one" + (d.pruned > 1 ? "s" : "") + " pruned." : ".")
        else root.status = ""
      }
    }
    onExited: { root.busy = ""; root.refresh() }
  }

  Timer { id: disarm; interval: 4000; onTriggered: root.armed = "" }
  // While something runs, follow it (it may have been started by the other bar or omnisearch).
  Timer {
    interval: 1500
    repeat: true
    running: root.opened && root.working
    onTriggered: { root.nowSec = Date.now() / 1000; root.refresh() }
  }
  Component.onCompleted: refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph(root.working ? "dbBusy" : "db")
    tooltipText: root.working ? root.runningText
                              : "DB snapshots · " + root.localTargets.length + " local databases · " + root.snaps.length + " saved"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(580))
    contentHeight: panel.fittedContentHeight(Math.max(column.implicitHeight, root.confirm ? Style.space(240) : 0))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.confirm !== null || noteField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy) list.contentY = Math.max(0, Math.min(list.contentHeight - list.height, list.contentY + dy * Style.space(60)))
      }
      onTextKey: function(t) {
        if (t === "r") root.refresh()
        else if (t === "n") noteField.forceActiveFocus()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ---------- header ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(hero.implicitHeight, tools.implicitHeight)
          Row {
            id: hero
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(14)
            Text { textFormat: Text.PlainText; text: root.glyph("db"); color: root.fg; font.family: root.font; font.pixelSize: Style.font.display; anchors.verticalCenter: parent.verticalCenter }
            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text { textFormat: Text.PlainText; text: "DB Snapshots"; color: root.fg; font.family: root.font; font.pixelSize: Style.font.title; font.bold: true }
              Text {
                textFormat: Text.PlainText
                text: (root.localTargets.length + " local databases · " + root.snaps.length + " snapshots"
                       + (root.snaps.length ? " · " + root.size(root.totalBytes) : "")).toUpperCase()
                color: Qt.darker(root.fg, 1.4); font.family: root.font; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.2
              }
            }
          }
          Row {
            id: tools
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            Button {
              iconText: root.glyph("folder"); tooltipText: "Open the snapshot folder"
              foreground: root.fg; fontFamily: root.font
              onClicked: { Quickshell.execDetached([root.helper, "open"]); root.close() }
            }
            Button {
              iconText: root.glyph("edit"); tooltipText: "Settings: folders to scan, how many to keep, Docker, extra databases"
              foreground: root.fg; fontFamily: root.font
              onClicked: { Quickshell.execDetached([root.helper, "edit"]); root.close() }
            }
            Button {
              iconText: root.glyph("refresh"); tooltipText: "Look again (r)"
              iconSpinning: listProc.running
              foreground: root.fg; fontFamily: root.font
              onClicked: root.refresh()
            }
          }
        }

        TextField {
          id: noteField
          width: parent.width
          placeholderText: "Note for the next snapshot (optional, n) · noted snapshots are never pruned"
          foreground: root.fg
          font.family: root.font
          font.pixelSize: Style.font.bodySmall
          maximumLength: 120
          Keys.onEscapePressed: function(event) { keyCatcher.forceActiveFocus(); event.accepted = true }
          Keys.onReturnPressed: function(event) { keyCatcher.forceActiveFocus(); event.accepted = true }
          Keys.onEnterPressed: function(event) { keyCatcher.forceActiveFocus(); event.accepted = true }
        }

        // ---------- what's happening ----------
        Row {
          visible: root.working
          width: parent.width
          spacing: Style.space(8)
          Text {
            id: spinner
            textFormat: Text.PlainText
            text: root.glyph("spin"); color: Commons.Color.accent; font.family: root.font; font.pixelSize: Style.font.bodySmall
            transformOrigin: Item.Center
            RotationAnimation on rotation { from: 0; to: 360; duration: 900; loops: Animation.Infinite; running: root.working && root.opened }
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width - spinner.width - parent.spacing
            text: root.runningText
            color: Commons.Color.accent; font.family: root.font; font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.status !== ""
          width: parent.width
          wrapMode: Text.Wrap
          text: root.status
          color: root.statusIsError ? Commons.Color.urgent : Commons.Color.accent
          font.family: root.font; font.pixelSize: Style.font.bodySmall
        }

        // ---------- databases ----------
        Flickable {
          id: list
          width: parent.width
          height: Math.min(listCol.implicitHeight, Style.space(520))
          contentHeight: listCol.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: listCol
            width: list.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              visible: !root.loaded && root.status === ""
              text: "Looking for databases…"
              color: root.dim; font.family: root.font; font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.sections
              delegate: Column {
                id: section
                required property var modelData
                width: listCol.width
                spacing: Style.space(6)

                PanelSectionHeader { text: section.modelData.title; foreground: root.fg; fontFamily: root.font }

                Repeater {
                  model: section.modelData.items
                  delegate: Rectangle {
                    id: card
                    required property var modelData
                    readonly property var t: modelData
                    readonly property var mine: root.snapsFor(t.id)
                    readonly property bool showAll: !!root.expanded[t.id]
                    readonly property bool cardBusy: root.busy === t.id || (root.running !== null && root.running.id === t.id)
                    width: section.width
                    implicitHeight: cardCol.implicitHeight + Style.space(16)
                    radius: Style.cornerRadius
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
                    border.width: 1
                    border.color: card.cardBusy ? Commons.Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

                    Column {
                      id: cardCol
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Style.space(8)
                      spacing: Style.space(5)

                      Item {
                        width: parent.width
                        implicitHeight: Math.max(head.implicitHeight, snapBtn.implicitHeight)
                        Column {
                          id: head
                          anchors.left: parent.left
                          anchors.right: snapBtn.left
                          anchors.rightMargin: Style.space(8)
                          anchors.verticalCenter: parent.verticalCenter
                          spacing: Style.space(1)
                          Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            text: root.kindGlyph(card.t) + "  " + card.t.db + "   ·   " + card.t.project
                            color: root.fg; font.family: root.font; font.pixelSize: Style.font.bodySmall; font.bold: true
                            elide: Text.ElideRight
                          }
                          Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            text: root.engineName(card.t.engine) + " · " + card.t.where + " · " + card.t.origin
                            color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
                            elide: Text.ElideMiddle
                          }
                        }
                        Button {
                          id: snapBtn
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          iconText: root.glyph(card.cardBusy ? "spin" : "snap")
                          iconSpinning: card.cardBusy
                          text: card.cardBusy ? (root.running && root.running.op === "restore" ? "Restoring…" : "Working…") : "Snapshot"
                          tooltipText: card.t.ready ? "Save a snapshot of " + card.t.db + " now" + (noteField.text.trim() ? " with your note" : "") : card.t.problem
                          fontSize: Style.font.caption
                          foreground: root.fg; fontFamily: root.font; bordered: true
                          enabled: card.t.ready && !root.working
                          opacity: enabled || card.cardBusy ? 1 : 0.45
                          onClicked: root.snapshot(card.t)
                        }
                      }

                      Text {
                        textFormat: Text.PlainText
                        visible: card.t.problem !== ""
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: root.glyph("alert") + "  " + card.t.problem
                        color: Commons.Color.urgent; font.family: root.font; font.pixelSize: Style.font.caption
                      }

                      Text {
                        textFormat: Text.PlainText
                        visible: card.mine.length === 0 && card.t.problem === ""
                        text: "No snapshots yet"
                        color: Qt.darker(root.fg, 1.8); font.family: root.font; font.pixelSize: Style.font.caption
                      }

                      Repeater {
                        model: card.showAll ? card.mine : card.mine.slice(0, 3)
                        delegate: Item {
                          id: snapRow
                          required property var modelData
                          readonly property var s: modelData
                          readonly property bool deleteArmed: root.armed === "delete:" + s.file
                          width: cardCol.width
                          implicitHeight: Math.max(snapText.implicitHeight, snapActions.implicitHeight)
                          opacity: root.busy === s.file || (root.running !== null && root.running.file === s.file) ? 0.5 : 1

                          Text {
                            id: snapText
                            textFormat: Text.PlainText
                            anchors.left: parent.left
                            anchors.right: snapActions.left
                            anchors.rightMargin: Style.space(6)
                            anchors.verticalCenter: parent.verticalCenter
                            text: "  " + root.glyph("history") + " " + root.when(snapRow.s.at)
                                  + (snapRow.s.label ? "  ·  " + snapRow.s.label : "") + "  ·  " + root.size(snapRow.s.size)
                            color: snapRow.s.auto ? root.dim : root.fg
                            font.family: root.font; font.pixelSize: Style.font.caption; font.italic: snapRow.s.auto
                            elide: Text.ElideRight
                          }
                          Row {
                            id: snapActions
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(4)
                            Button {
                              iconText: root.glyph("restore")
                              text: "Restore"
                              tooltipText: "Replace " + card.t.db + " with this snapshot (asks first, saves the current data first)"
                              fontSize: Style.font.caption
                              foreground: root.fg; fontFamily: root.font; bordered: true
                              enabled: card.t.ready && !root.working
                              opacity: enabled ? 1 : 0.45
                              onClicked: root.askRestore(snapRow.s, card.t, "restore")
                            }
                            Button {
                              iconText: root.glyph("copy")
                              tooltipText: "Restore into a new " + (card.t.engine === "sqlite" ? "file" : "database") + " and leave " + card.t.db + " as it is"
                              fontSize: Style.font.caption
                              foreground: root.fg; fontFamily: root.font; bordered: true
                              enabled: card.t.ready && !root.working
                              opacity: enabled ? 1 : 0.45
                              onClicked: root.askRestore(snapRow.s, card.t, "copy")
                            }
                            Button {
                              iconText: root.glyph("del")
                              text: snapRow.deleteArmed ? "Sure?" : ""
                              tooltipText: "Delete this snapshot (click twice)"
                              fontSize: Style.font.caption
                              foreground: snapRow.deleteArmed ? Commons.Color.urgent : root.fg; fontFamily: root.font; bordered: true
                              active: snapRow.deleteArmed
                              enabled: !root.working
                              opacity: enabled ? 1 : 0.45
                              onClicked: snapRow.deleteArmed ? root.run(["delete", snapRow.s.file], snapRow.s.file, "Deleting a snapshot…")
                                                             : root.arm("delete:" + snapRow.s.file)
                            }
                          }
                        }
                      }

                      Button {
                        visible: card.mine.length > 3
                        text: card.showAll ? "Show fewer" : "Show " + (card.mine.length - 3) + " older"
                        fontSize: Style.font.caption
                        foreground: root.dim; fontFamily: root.font
                        onClicked: root.toggleExpanded(card.t.id)
                      }
                    }
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.loaded && root.localTargets.length === 0
              width: listCol.width
              wrapMode: Text.Wrap
              text: "No local databases found. dbsnap reads DATABASE_URL-style settings from .env files under ~/Projects, ~/Work, ~/Code and similar folders, "
                    + "and also lists running Docker databases and the local PostgreSQL server. The pencil opens the settings to add folders or databases."
              color: Qt.darker(root.fg, 1.4); font.family: root.font; font.pixelSize: Style.font.bodySmall
            }

            // ---------- snapshots whose database isn't around ----------
            Column {
              visible: root.orphans.length > 0
              width: listCol.width
              spacing: Style.space(4)
              PanelSectionHeader { text: "SNAPSHOTS WITHOUT A DATABASE RIGHT NOW"; foreground: root.fg; fontFamily: root.font }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.Wrap
                text: "Their project, setting or container isn't found at the moment, so they can't be restored until it is back. You can still delete them."
                color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
              }
              Repeater {
                model: root.orphans
                delegate: Item {
                  id: orphanRow
                  required property var modelData
                  readonly property bool deleteArmed: root.armed === "delete:" + modelData.file
                  width: listCol.width
                  implicitHeight: Math.max(orphanText.implicitHeight, orphanDel.implicitHeight)
                  Text {
                    id: orphanText
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.right: orphanDel.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "  " + root.glyph("history") + " " + orphanRow.modelData.id + "  ·  " + root.when(orphanRow.modelData.at)
                          + (orphanRow.modelData.label ? "  ·  " + orphanRow.modelData.label : "") + "  ·  " + root.size(orphanRow.modelData.size)
                    color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                  Button {
                    id: orphanDel
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: root.glyph("del")
                    text: orphanRow.deleteArmed ? "Sure?" : ""
                    tooltipText: "Delete this snapshot (click twice)"
                    fontSize: Style.font.caption
                    foreground: orphanRow.deleteArmed ? Commons.Color.urgent : root.fg; fontFamily: root.font; bordered: true
                    active: orphanRow.deleteArmed
                    enabled: !root.working
                    onClicked: orphanRow.deleteArmed ? root.run(["delete", orphanRow.modelData.file], orphanRow.modelData.file, "Deleting a snapshot…")
                                                     : root.arm("delete:" + orphanRow.modelData.file)
                  }
                }
              }
            }

            // ---------- databases dbsnap will not touch ----------
            Button {
              visible: root.remoteTargets.length > 0
              width: listCol.width
              leftAlign: true
              iconText: root.glyph("shield")
              text: (root.showRemote ? "Hide " : "Show ") + root.remoteTargets.length + " not on this machine (never touched)"
              fontSize: Style.font.caption
              foreground: Qt.darker(root.fg, 1.3); fontFamily: root.font
              onClicked: root.showRemote = !root.showRemote
            }
            Repeater {
              model: root.showRemote ? root.remoteTargets : []
              delegate: Text {
                textFormat: Text.PlainText
                required property var modelData
                width: listCol.width
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: "  " + root.glyph("remote") + " " + modelData.db + " · " + modelData.project + " — " + modelData.where + " · " + modelData.reason
                color: Qt.darker(root.fg, 1.8); font.family: root.font; font.pixelSize: Style.font.caption
              }
            }

            // ---------- settings that couldn't be read ----------
            Button {
              visible: root.listErrors.length > 0
              width: listCol.width
              leftAlign: true
              iconText: root.glyph("alert")
              text: root.listErrors.length + (root.listErrors.length === 1 ? " setting" : " settings") + " couldn't be read" + (root.showErrors ? "" : " · show")
              fontSize: Style.font.caption
              foreground: Qt.darker(root.fg, 1.3); fontFamily: root.font
              onClicked: root.showErrors = !root.showErrors
            }
            Repeater {
              model: root.showErrors ? root.listErrors : []
              delegate: Text {
                textFormat: Text.PlainText
                required property var modelData
                width: listCol.width
                wrapMode: Text.Wrap
                text: "  " + modelData
                color: Qt.darker(root.fg, 1.6); font.family: root.font; font.pixelSize: Style.font.caption
              }
            }

            Text {
              textFormat: Text.PlainText
              width: listCol.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              text: (root.storeShort ? "Saved in " + root.storeShort + " · " : "")
                    + (root.keep > 0 ? "keeps the newest " + root.keep + " per database, noted ones always" : "keeps every snapshot")
                    + " · only databases on this machine · r refreshes"
              color: Qt.darker(root.fg, 1.9); font.family: root.font; font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // Keys go here while the dialog is up, so Esc closes the dialog and not the panel.
      Item {
        id: confirmKeys
        Keys.onPressed: function(event) { confirmDialog.handleKey(event); event.accepted = true }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirm !== null
        message: root.confirmMessage
        confirmText: root.confirm && root.confirm.mode === "copy" ? "Create" : "Restore"
        foreground: root.fg
        fontFamily: root.font
        onCanceled: root.closeConfirm()
        onConfirmed: root.doConfirm()
      }
    }
  }
}
