import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
// The Logos design system (bundled by Basecamp): its theme and controls. Only components Basecamp 0.3.2
// ships are used (tests render against the design system as of that release).
import Logos.Theme
import Logos.Controls

// AI Gateway - pure-QML view over ai_gateway_core (ADR 0001), and the provider of the ai.ask and
// ai.chat intents. Every call to the core is async (callModuleAsync): inference outlives the IPC
// timeout, so a chat is a job whose updates arrive as jobUpdate events.
Item {
    id: root
    anchors.fill: parent

    // ── palette: the Logos design system's theme (dark in Basecamp) ──
    readonly property color cBg: Theme.palette.background
    readonly property color cSurface: Theme.palette.backgroundSecondary
    readonly property color cRaised: Theme.palette.surface
    readonly property color cBorder: Theme.palette.border
    readonly property color cText: Theme.palette.text
    readonly property color cSec: Theme.palette.textSecondary
    readonly property color cTert: Theme.palette.textTertiary
    readonly property color cAccent: Theme.palette.primary
    readonly property color cGood: Theme.palette.success
    readonly property color cWarn: Theme.palette.warning
    readonly property color cBad: Theme.palette.error
    readonly property string issuesUrl: "https://github.com/vpavlin/ai-gateway-basecamp/issues"

    // ── state ──
    property string page: "chat"
    property var presetList: []
    property var connectorList: []
    property var modelList: []
    property var settingsObj: ({})
    property var serverObj: ({})
    property var usageObj: ({})
    property var sessionList: []
    // remote (non-local) providers: hidden until the user has read the warning once (settings.remoteAcknowledged)
    property bool showRemote: false
    property bool remoteWarningOpen: false
    readonly property bool remoteOk: settingsObj.remoteAcknowledged === true
    readonly property string remoteWarning: "These run the model on someone else's computer. Each provider makes privacy promises: some don't keep your prompts, some run in confidential hardware. None can guarantee full privacy. Your prompts leave this computer, and your IP address, timing, account and payment can identify you. Use them at your own risk."
    property string toastMsg: ""
    // chat
    property var chatMessages: []          // [{role, content, model?, privacy?}]
    property string chatModel: ""
    property string chatJob: ""
    property string chatWatch: ""          // the job's public id in jobUpdate events (they carry no content)
    property string chatPartial: ""
    // connector editor
    property var editPreset: null
    property string editId: ""
    // intent in progress
    property string intentId: ""
    property string intentName: ""
    property string intentFrom: ""
    property var intentParams: ({})
    property string intentModel: ""
    property string intentJob: ""
    property string intentWatch: ""
    property string intentAnswer: ""
    property string intentState: ""
    property var intentStats: null       // "", ask, running, done, error

    readonly property var tierNames: ({ "standard": "Standard", "no-retention": "No retention", "tee": "TEE", "tee-e2ee": "TEE + E2EE", "local": "On this device" })
    readonly property var tierHelp: ({
        "standard": "The provider makes no privacy promise.",
        "no-retention": "The provider promises not to keep your prompts (not verifiable).",
        "tee": "Runs in confidential computing (attested hardware); claimed by the provider, not yet verified here.",
        "tee-e2ee": "Encrypted end to end into attested hardware.",
        "local": "Runs on this computer; nothing leaves it."
    })
    readonly property var tierOrder: ["standard", "no-retention", "tee", "tee-e2ee", "local"]
    function tierColor(t) { return t === "local" ? cGood : (t === "tee" || t === "tee-e2ee") ? Theme.palette.info : t === "no-retention" ? cWarn : cTert }
    function tierRank(t) { return tierOrder.indexOf(t) }

    // ── core calls ──
    // Basecamp hands a core's answer back JSON-quoted, sometimes twice: unwrap the string layers, then
    // parse the object or array (a bare string must never become a model: Repeaters iterate its chars)
    function parse(raw) {
        var s = String(raw === undefined || raw === null ? "" : raw).trim()
        for (var i = 0; i < 3 && s.charAt(0) === "\""; i++) { try { s = String(JSON.parse(s)).trim() } catch (e) { return null } }
        if (s.charAt(0) !== "{" && s.charAt(0) !== "[") return null
        try { return JSON.parse(s) } catch (e) { return null }
    }
    function call(m, a, cb) {
        var done = function (r) { if (cb) { try { cb(r === undefined || r === null ? "" : String(r)) } catch (e) { console.warn("aigw callback", m, e) } } }
        if (typeof logos === "undefined" || !logos) { Qt.callLater(function () { done("") }); return }
        if (typeof logos.callModuleAsync === "function") {
            try { logos.callModuleAsync("ai_gateway_core", m, a || [], done, 20000) } catch (e) { Qt.callLater(function () { done("") }) }
            return
        }
        Qt.callLater(function () { try { done(logos.callModule("ai_gateway_core", m, a || [])) } catch (e) { done("") } })
    }
    function toast(t) { toastMsg = t; toastTimer.restart() }
    function refresh() {
        call("connectors", [], function (r) { var v = parse(r); if (v) connectorList = v })
        call("models", [], function (r) { var v = parse(r); if (v) { modelList = v; if (!chatModel && v.length) chatModel = bestModel("standard") } })
        call("settings", [], function (r) { var v = parse(r); if (v) settingsObj = v })
        call("serverInfo", [], function (r) { var v = parse(r); if (v) serverObj = v })
        call("usage", [], function (r) { var v = parse(r); if (v) usageObj = v })
        call("sessions", [], function (r) { var v = parse(r); if (v) sessionList = v })
    }
    function bestModel(minTier) {
        var def = settingsObj.defaultModel || ""
        var best = null
        for (var i = 0; i < modelList.length; i++) {
            var m = modelList[i]
            if (tierRank(m.privacy) < tierRank(minTier)) continue
            if (m.id === def) return m.id
            if (!best || m.privacyRank > best.privacyRank) best = m
        }
        return best ? best.id : ""
    }
    function modelById(id) { for (var i = 0; i < modelList.length; i++) if (modelList[i].id === id) return modelList[i]; return null }
    function modelsAtLeast(minTier) { var o = []; for (var i = 0; i < modelList.length; i++) if (tierRank(modelList[i].privacy) >= tierRank(minTier)) o.push(modelList[i]); return o }
    function pinnedList() { return settingsObj.pinnedModels || [] }
    function togglePin(id) {
        var p = pinnedList().slice(), i = p.indexOf(id)
        if (i >= 0) p.splice(i, 1); else p.push(id)
        var so = Object.assign({}, settingsObj); so.pinnedModels = p; settingsObj = so   // show it at once
        call("setSettings", [JSON.stringify({ pinnedModels: p })], function (r) { var v = parse(r); if (!v || !v.ok) { toast(v && v.error ? v.error : "couldn't save the pin"); refresh() } })
    }
    // is a URL's host this computer? (the core uses the same rule for the "On this device" tier)
    function isLoopback(url) {
        var m = /^https?:\/\/(\[[^\]]*\]|[^\/:]+)/i.exec(String(url || "")); if (!m) return false
        var h = m[1].toLowerCase()
        return h === "localhost" || h === "[::1]" || h.indexOf("127.") === 0
    }
    // speed of one answer: time to first token, tokens per second, total time
    function secs(ms) { ms = Number(ms || 0); return ms < 1000 ? ms + " ms" : (ms / 1000).toFixed(ms < 10000 ? 1 : 0) + " s" }
    function speedText(st) {
        if (!st) return ""
        var o = []
        if (st.ttftMs !== undefined && st.ttftMs !== null) o.push(secs(st.ttftMs) + " to first token")
        if (typeof st.tokensPerSec === "number") o.push((st.estimated ? "≈ " : "") + st.tokensPerSec + " tok/s")
        if (st.totalMs) o.push(secs(st.totalMs) + " total")
        return o.length ? "  ·  " + o.join("  ·  ") : ""
    }
    // a model's average speed from usage (models: {id: {runs, ttftSumMs, tpsRuns, tpsSumX10}})
    function modelSpeed(id) {
        var m = (usageObj.models || {})[id]; if (!m) return null
        return { runs: m.runs || 0, ttftMs: m.runs ? Math.round((m.ttftSumMs || 0) / m.runs) : null,
                 tps: m.tpsRuns ? Math.round((m.tpsSumX10 || 0) / m.tpsRuns) / 10 : null }
    }
    function speedMap() {
        var out = {}, ms = usageObj.models || {}
        for (var k in ms) { var s = modelSpeed(k); if (s && s.tps !== null) out[k] = s.tps }
        return out
    }
    function kchars(n) { n = Number(n || 0); return n < 1000 ? n + " chars" : (n < 1000000 ? Math.round(n / 1000) + " k chars" : (n / 1000000).toFixed(1) + " M chars") }
    function isLocalPreset(p) { return !!p && (p.kind === "local" || p.id === "custom") }
    function localPresets() { return presetList.filter(function (p) { return isLocalPreset(p) }) }
    function remotePresets() { return presetList.filter(function (p) { return !isLocalPreset(p) }) }
    function revealRemote() { if (remoteOk) showRemote = true; else remoteWarningOpen = true }
    function acknowledgeRemote() {
        var so = Object.assign({}, settingsObj); so.remoteAcknowledged = true; settingsObj = so
        remoteWarningOpen = false; showRemote = true
        call("setSettings", [JSON.stringify({ remoteAcknowledged: true })], function () { refresh() })
    }
    function presetById(id) { for (var i = 0; i < presetList.length; i++) if (presetList[i].id === id) return presetList[i]; return null }

    // ── chat ──
    function sendChat(text) {
        if (!text.trim() || chatJob) return
        if (!chatModel) { toast("Set up a connector first (Connectors)"); return }
        var msgs = chatMessages.slice(); msgs.push({ role: "user", content: text })
        chatMessages = msgs
        var req = { model: chatModel, messages: msgs.map(function (m) { return { role: m.role, content: m.content } }) }
        call("chat", ["ai_gateway", JSON.stringify(req)], function (r) {
            var v = parse(r)
            if (!v || !v.ok) { toast(v && v.error ? v.error : "AI Gateway core didn't answer"); return }
            chatJob = v.jobId; chatWatch = v.watchId || ""; chatPartial = ""
        })
    }
    function onJobUpdate(id, u) {
        if (id === chatJob) {
            if (u.delta) chatPartial += u.delta
            if (u.state && u.state !== "running") {
                var msgs = chatMessages.slice()
                if (u.state === "done") msgs.push({ role: "assistant", content: u.text || chatPartial, model: u.model, privacy: u.privacy, stats: u.stats || null })
                else msgs.push({ role: "error", content: u.state === "cancelled" ? "Stopped." : (u.error || "failed") })
                chatMessages = msgs; chatJob = ""; chatPartial = ""
                refresh()
            }
        }
        if (id === intentJob) {
            if (u.delta) intentAnswer += u.delta
            if (u.state && u.state !== "running") {
                intentJob = ""
                if (u.state === "done") {
                    intentAnswer = u.text || intentAnswer; intentState = "done"; intentStats = u.stats || null
                    var m = modelById(u.model)
                    finishIntent(true, { text: intentAnswer, model: u.model || "", connector: u.connector || "", privacy: u.privacy || "", usage: u.usage || {} }, "")
                } else { intentState = "error"; intentAnswer = u.error || u.state; finishIntent(false, { message: String(u.error || u.state).substring(0, 300) }, u.state === "cancelled" ? "cancelled" : "failed") }
                refresh()
            }
        }
    }
    // Answers are read with job(jobId): the jobUpdate event only says "something changed" (every module
    // can see events, so they carry no text). Poll while a job runs; an event polls at once.
    function pollJob(id) {
        if (!id) return
        call("job", [id], function (r) {
            var v = parse(r); if (!v || !v.ok) return
            if (id !== chatJob && id !== intentJob) return
            var known = id === chatJob ? chatPartial : intentAnswer
            var u = { state: v.state, text: v.text, model: v.model, connector: v.connector, privacy: v.privacy, error: v.error, usage: v.usage, stats: v.stats }
            if (v.state === "running" && v.text && v.text.length > known.length) u.delta = v.text.substring(known.length)
            if (v.state === "running" && !u.delta) return
            onJobUpdate(id, u)
        })
    }
    Timer {
        interval: 400; repeat: true; running: !!(root.chatJob || root.intentJob)
        onTriggered: { root.pollJob(root.chatJob); root.pollJob(root.intentJob) }
    }

    // ── intents (ai.ask / ai.chat) ──
    // the user's own instructions for an app (Settings): what the core adds to every request it sends
    function instructionsFor(app) {
        var ins = settingsObj.instructions || {}, g = String(ins.global || ""), a = String((ins.apps || {})[app] || "")
        return g && a ? g + "\n\n" + a : (g || a)
    }
    // the consent preview: exactly what goes to the model, including the user's own instructions,
    // placed where the core puts them (after the app's system prompt)
    function previewMessages() {
        var ms = intentMessages().slice(), mine = instructionsFor(intentFrom)
        if (!mine) return ms
        var i = 0; while (i < ms.length && ms[i].role === "system") i++
        ms.splice(i, 0, { role: "your instructions", content: mine })
        return ms
    }
    function saveInstructions(app, text) {
        var ins = app ? { apps: {} } : { global: String(text) }
        if (app) ins.apps[app] = String(text)
        call("setSettings", [JSON.stringify({ instructions: ins })], function (r) {
            var v = parse(r)
            if (v && v.ok) { toast(text ? "Instructions saved" : "Instructions removed"); refresh() } else toast(v && v.error ? v.error : "couldn't save")
        })
    }
    // apps that can have their own instructions: the built-in chat, apps that have asked, and any with instructions already
    function instructionApps() {
        var names = ["ai_gateway"], add = function (n) { if (n && names.indexOf(n) < 0) names.push(n) }
        for (var k in (usageObj.apps || {})) if (k !== "local endpoint") add(k)
        for (var a in ((settingsObj.instructions || {}).apps || {})) add(a)
        for (var i = 0; i < sessionList.length; i++) add(sessionList[i].caller)
        return names
    }
    function intentMessages() {
        var p = intentParams
        if (intentName === "ai.chat") return p.messages || []
        if (intentName === "ai.session") {
            var s = []
            if (p.system) s.push({ role: "system", content: String(p.system) })
            // the whole document: the preview must be exactly what is sent (it scrolls)
            if (p.document) s.push({ role: "document", content: String(p.document) })
            return s
        }
        var m = []
        if (p.system) m.push({ role: "system", content: String(p.system) })
        m.push({ role: "user", content: String(p.prompt || "") + (p.content ? "\n\n" + String(p.content) : "") })
        return m
    }
    function intentFloor() { var f = String(intentParams.minPrivacy || "standard"); return tierRank(f) < 0 ? "standard" : f }
    function startIntent(requestId, intent, params, requester) {
        if (intentId) finishIntent(false, {}, "cancelled")   // a new ask replaces the old
        intentId = requestId; intentName = intent; intentFrom = requester || "an app"; intentParams = params || {}
        intentAnswer = ""; intentJob = ""; intentState = "ask"; intentStats = null
        var want = params && params.model ? String(params.model) : ""
        var floor = intentFloor()
        var m = want ? modelById(want) : null
        intentModel = (m && tierRank(m.privacy) >= tierRank(floor)) ? m.id : bestModel(floor)
        page = "intent"
    }
    function runIntent() {
        if (!intentModel) { toast("No model meets the privacy this app asked for"); return }
        if (intentName === "ai.session") {
            var sp = intentParams
            var sj = { title: String(sp.title || ""), model: intentModel, minPrivacy: intentFloor(), system: String(sp.system || ""), document: String(sp.document || "") }
            call("openSession", [intentFrom, JSON.stringify(sj)], function (r) {
                var v = parse(r)
                if (!v || !v.ok) { intentState = "error"; intentAnswer = v && v.error ? v.error : "AI Gateway core didn't answer"; finishIntent(false, { message: intentAnswer.substring(0, 300) }, "failed"); return }
                intentState = "done"
                intentAnswer = intentFrom + " can now chat about \u201c" + sj.title + "\u201d with " + (v.model || "") + ", without asking each time. End it any time under Apps & usage."
                // provider + api: the provider-neutral contract (docs/ai-session-contract.md): the app calls
                // these core methods on the module named here, whoever provides ai.session
                finishIntent(true, { sessionId: v.sessionId, model: v.model || "", connector: v.connectorName || "", privacy: v.privacy || "",
                                     provider: "ai_gateway_core", api: "ai-session/1" }, "")
                refresh()
            })
            return
        }
        var req = { model: intentModel, minPrivacy: intentFloor(), messages: intentMessages() }
        if (intentName === "ai.chat") {
            if (typeof intentParams.temperature === "number") req.temperature = intentParams.temperature
            if (typeof intentParams.maxTokens === "number") req.max_tokens = intentParams.maxTokens
        }
        call("chat", [intentFrom, JSON.stringify(req)], function (r) {
            var v = parse(r)
            if (!v || !v.ok) { intentState = "error"; intentAnswer = v && v.error ? v.error : "AI Gateway core didn't answer"; finishIntent(false, { message: intentAnswer.substring(0, 300) }, "failed"); return }
            intentJob = v.jobId; intentWatch = v.watchId || ""; intentState = "running"
        })
    }
    function finishIntent(ok, data, err) {
        if (!intentId) return
        var rid = intentId; intentId = ""
        try { logos.respond(rid, ok, data, err) } catch (e) { console.warn("aigw respond", e) }
    }
    function declineIntent() {
        if (intentJob) call("cancel", [intentJob], null)
        finishIntent(false, {}, "cancelled"); intentState = ""; page = "chat"
    }
    Connections {
        target: (typeof logos !== "undefined") ? logos : null
        ignoreUnknownSignals: true
        function onModuleEventReceived(module, event, data) {
            if (module !== "ai_gateway_core") return
            if (event === "jobUpdate") {
                // {arg0: watchId, arg1: {id, state}} (logosctl 0.3.1); an array or named fields too
                var args = Array.isArray(data) ? data : null
                var w = args ? args[0] : (data && (data.arg0 || data.watchId || data.jobId))
                if (w && w === root.chatWatch) root.pollJob(root.chatJob)
                if (w && w === root.intentWatch) root.pollJob(root.intentJob)
            } else if (event === "modelsChanged") root.refresh()
        }
        function onIntentRequested(requestId, intent, params, requesterName) {
            if (intent !== "ai.ask" && intent !== "ai.chat" && intent !== "ai.session") return
            root.startIntent(requestId, intent, params, requesterName)
        }
    }

    Timer { interval: 4000; repeat: true; running: root.page === "apps"; onTriggered: root.refresh() }
    Timer { id: toastTimer; interval: 3500; onTriggered: root.toastMsg = "" }
    Timer { interval: 4000; running: true; repeat: true; onTriggered: if (!root.chatJob && !root.intentJob) root.refresh() }
    Component.onCompleted: {
        call("presets", [], function (r) { var v = parse(r); if (v) presetList = v })
        refresh()
    }

    // ── UI ──
    Rectangle { anchors.fill: parent; color: root.cBg }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        // sidebar
        Rectangle {
            Layout.fillHeight: true; Layout.preferredWidth: 200; color: root.cSurface
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 14; spacing: 4
                Text { textFormat: Text.PlainText; text: "AI Gateway"; color: root.cText; font.pixelSize: 18; font.bold: true; Layout.bottomMargin: 10 }
                Repeater {
                    model: [["chat", "Chat"], ["connectors", "Connectors"], ["apps", "Apps & usage"], ["settings", "Settings"]]
                    delegate: Rectangle {
                        Layout.fillWidth: true; height: 34; radius: 6
                        color: root.page === modelData[0] ? root.cRaised : "transparent"
                        Text { textFormat: Text.PlainText; anchors.verticalCenter: parent.verticalCenter; x: 10; text: modelData[1]; color: root.page === modelData[0] ? root.cText : root.cSec; font.pixelSize: 14 }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.page = modelData[0] }
                    }
                }
                Rectangle {
                    // only while a request waits or runs; a finished one leaves no entry behind
                    visible: root.intentState === "ask" || root.intentState === "running" || (root.page === "intent" && root.intentState !== "")
                    Layout.fillWidth: true; height: 34; radius: 6; color: root.page === "intent" ? root.cRaised : "transparent"; border.color: root.cAccent
                    Text { textFormat: Text.PlainText; anchors.verticalCenter: parent.verticalCenter; x: 10; text: "Request from " + root.intentFrom; color: root.cAccent; font.pixelSize: 13; elide: Text.ElideRight; width: parent.width - 16 }
                    MouseArea { anchors.fill: parent; onClicked: root.page = "intent" }
                }
                Item { Layout.fillHeight: true }
                Text { textFormat: Text.PlainText;
                    Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cTert; font.pixelSize: 11
                    text: root.modelList.length + " models from " + root.connectorList.length + " connectors"
                }
            }
        }
        // content
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true

            // ── Chat ──
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 18; spacing: 10
                visible: root.page === "chat"
                RowLayout {
                    Layout.fillWidth: true
                    Text { textFormat: Text.PlainText; text: "Model"; color: root.cSec }
                    ModelPicker {
                        objectName: "chatPicker"; Layout.preferredWidth: 460
                        models: root.modelList; pinned: root.pinnedList(); current: root.chatModel; speeds: root.speedMap()
                        onPicked: function (id) { root.chatModel = id }
                        onPinToggled: function (id) { root.togglePin(id) }
                    }
                    Item { Layout.fillWidth: true }
                    Btn { text: "New chat"; onClicked: { root.chatMessages = []; root.chatPartial = "" } }
                }
                Text { textFormat: Text.PlainText;
                    visible: root.modelList.length === 0
                    Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec
                    text: "No models yet. Open Connectors and set up a local runtime (Ollama is the easiest) or a private provider."
                }
                ListView {
                    id: chatView
                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 10
                    model: root.chatMessages.length + (root.chatJob ? 1 : 0)
                    onCountChanged: positionViewAtEnd()
                    delegate: Rectangle {
                        property var m: index < root.chatMessages.length ? root.chatMessages[index] : { role: "assistant", content: root.chatPartial || "…" }
                        width: chatView.width; radius: 8
                        color: m.role === "user" ? root.cRaised : m.role === "error" ? Theme.colors.getColor(root.cBad, 0.15) : root.cSurface
                        height: body.implicitHeight + meta.implicitHeight + 24
                        Text { textFormat: Text.PlainText; id: meta; x: 12; y: 8; color: root.cTert; font.pixelSize: 11
                               text: m.role === "user" ? "You" : m.role === "error" ? "Error" : ("AI" + (m.model ? "  ·  " + m.model : "") + (m.privacy ? "  ·  " + (root.tierNames[m.privacy] || m.privacy) : "") + root.speedText(m.stats)) }
                        TextEdit { id: body; x: 12; y: meta.y + meta.implicitHeight + 4; width: parent.width - 24; readOnly: true; selectByMouse: true
                                   wrapMode: TextEdit.Wrap; color: root.cText; font.pixelSize: 14; text: m.content }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    ScrollView {
                        Layout.fillWidth: true; Layout.preferredHeight: Math.min(Math.max(chatInput.implicitHeight, 46), 180)
                        LogosTextArea {
                            id: chatInput; objectName: "chatInput"
                            wrapMode: TextArea.Wrap
                            placeholderText: "Ask anything  (Enter sends, Shift+Enter for a new line)"
                            // Enter sends; Shift+Enter (and IME composition) inserts a new line as usual
                            Keys.onPressed: function (e) {
                                if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier) && chatInput.preeditText === "") {
                                    e.accepted = true
                                    if (!root.chatJob && chatInput.text.trim()) { root.sendChat(chatInput.text); chatInput.text = "" }
                                }
                            }
                        }
                    }
                    Btn { Layout.alignment: Qt.AlignBottom; Layout.preferredHeight: 46; primary: !root.chatJob; text: root.chatJob ? "Stop" : "Send"
                          onClicked: { if (root.chatJob) root.call("cancel", [root.chatJob], null); else { root.sendChat(chatInput.text); chatInput.text = "" } } }
                }
            }

            // ── Connectors ──
            Flickable {
                anchors.fill: parent; anchors.margins: 18; contentHeight: connCol.implicitHeight; clip: true
                visible: root.page === "connectors" && !root.editPreset
                ColumnLayout {
                    id: connCol; width: parent.width; spacing: 10
                    Text { textFormat: Text.PlainText; text: "Connectors"; color: root.cText; font.pixelSize: 18; font.bold: true }
                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec
                           text: "Where your AI runs. Local runtimes keep everything on this computer. Remote providers run the model elsewhere: they are hidden until you choose to see them, and the tier shows what each one promises. Keys stay on this computer and only ever go to their own provider." }
                    Repeater {
                        model: root.connectorList
                        delegate: Rectangle {
                            Layout.fillWidth: true; radius: 8; color: root.cSurface; border.color: root.cBorder
                            implicitHeight: cc.implicitHeight + 20
                            ColumnLayout {
                                id: cc; x: 12; y: 10; width: parent.width - 24; spacing: 4
                                RowLayout {
                                    Text { textFormat: Text.PlainText; text: modelData.name; color: root.cText; font.pixelSize: 15; font.bold: true }
                                    Rectangle { radius: 4; color: "transparent"; border.color: root.tierColor(modelData.privacy); implicitWidth: tl.implicitWidth + 10; implicitHeight: tl.implicitHeight + 4
                                                Text { textFormat: Text.PlainText; id: tl; anchors.centerIn: parent; text: modelData.privacyNote ? "Varies by model" : (root.tierNames[modelData.privacy] || modelData.privacy); color: root.tierColor(modelData.privacy); font.pixelSize: 11 } }
                                    LogosBadge { visible: !root.isLoopback(modelData.baseUrl); text: "Remote"; color: Theme.palette.textSecondary }
                                    ExperimentalBadge { visible: !!(root.presetById(modelData.preset) || {}).experimental }
                                    Item { Layout.fillWidth: true }
                                    Btn { text: "Test"; onClicked: root.call("testConnector", [modelData.id], function () { root.toast("Testing " + modelData.name + "…") }) }
                                    Btn { text: "Edit"; onClicked: { root.editId = modelData.id; root.editPreset = root.presetById(modelData.preset) } }
                                    Btn { danger: true; text: "Remove"; onClicked: root.call("removeConnector", [modelData.id], function () { root.refresh() }) }
                                }
                                Text { textFormat: Text.PlainText; color: root.cSec; font.pixelSize: 12; text: modelData.baseUrl + (modelData.hasKey ? "  ·  key " + modelData.apiKey : "") }
                                Text { textFormat: Text.PlainText; color: modelData.error ? root.cBad : root.cGood; font.pixelSize: 12
                                       text: modelData.error ? modelData.error : (modelData.models + " models available") }
                                Text { textFormat: Text.PlainText; visible: !!modelData.balance; color: root.cSec; font.pixelSize: 12
                                       text: { var b = modelData.balance || {}; var o = []; for (var k in b) o.push(k.replace("x-venice-balance-", "") + " " + b[k]); return "Balance: " + o.join(", ") } }
                            }
                        }
                    }
                    Text { textFormat: Text.PlainText; text: "Add a connector on this computer"; color: root.cText; font.pixelSize: 16; font.bold: true; Layout.topMargin: 10 }
                    GridLayout {
                        Layout.fillWidth: true; columns: 3; columnSpacing: 10; rowSpacing: 10
                        Repeater {
                            model: root.localPresets()
                            delegate: Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 104; radius: 8; color: root.cSurface; border.color: root.cBorder
                                ColumnLayout {
                                    x: 10; y: 8; width: parent.width - 20; spacing: 2
                                    Text { textFormat: Text.PlainText; text: modelData.name; color: root.cText; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { textFormat: Text.PlainText; text: modelData.privacyNote || root.tierNames[modelData.privacy] || modelData.privacy; color: root.tierColor(modelData.privacy); font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                                    ExperimentalBadge { visible: !!modelData.experimental }
                                    Text { textFormat: Text.PlainText; text: modelData.blurb; color: root.cSec; font.pixelSize: 11; wrapMode: Text.Wrap; maximumLineCount: modelData.experimental ? 1 : 2; elide: Text.ElideRight; Layout.fillWidth: true }
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.editId = ""; root.editPreset = modelData } }
                            }
                        }
                    }
                    // remote providers: behind a warning the user acknowledges once
                    Btn {
                        visible: !root.showRemote && !root.remoteWarningOpen; Layout.topMargin: 6
                        text: "Show remote providers…"
                        onClicked: root.revealRemote()
                    }
                    LogosNotice {
                        visible: root.remoteWarningOpen || root.showRemote; Layout.fillWidth: true; Layout.topMargin: 6; severity: LogosNotice.Warning
                        title: "Remote providers: not on this computer"
                        message: root.remoteWarning
                    }
                    RowLayout {
                        visible: root.remoteWarningOpen
                        Btn { primary: true; text: "I understand, show them"; onClicked: root.acknowledgeRemote() }
                        Btn { text: "Keep them hidden"; onClicked: root.remoteWarningOpen = false }
                    }
                    GridLayout {
                        visible: root.showRemote
                        Layout.fillWidth: true; columns: 3; columnSpacing: 10; rowSpacing: 10
                        Repeater {
                            model: root.remotePresets()
                            delegate: Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 104; radius: 8; color: root.cSurface; border.color: root.cBorder
                                ColumnLayout {
                                    x: 10; y: 8; width: parent.width - 20; spacing: 2
                                    Text { textFormat: Text.PlainText; text: modelData.name; color: root.cText; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { textFormat: Text.PlainText; text: modelData.privacyNote || root.tierNames[modelData.privacy] || modelData.privacy; color: root.tierColor(modelData.privacy); font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                                    ExperimentalBadge { visible: !!modelData.experimental }
                                    Text { textFormat: Text.PlainText; text: modelData.blurb; color: root.cSec; font.pixelSize: 11; wrapMode: Text.Wrap; maximumLineCount: modelData.experimental ? 1 : 2; elide: Text.ElideRight; Layout.fillWidth: true }
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.editId = ""; root.editPreset = modelData } }
                            }
                        }
                    }
                    Btn { visible: root.showRemote; text: "Hide remote providers"; onClicked: root.showRemote = false }
                }
            }

            // ── connector onboarding / editor ──
            Flickable {
                anchors.fill: parent; anchors.margins: 18; contentHeight: edCol.implicitHeight; clip: true
                visible: root.page === "connectors" && !!root.editPreset
                ColumnLayout {
                    id: edCol; width: Math.min(parent.width, 720); spacing: 8
                    property var p: root.editPreset || ({})
                    RowLayout {
                        Btn { text: "← Back"; onClicked: root.editPreset = null }
                        Text { textFormat: Text.PlainText; text: edCol.p.name || ""; color: root.cText; font.pixelSize: 18; font.bold: true }
                    }
                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec; text: edCol.p.blurb || "" }
                    LogosNotice {
                        visible: !root.isLocalPreset(edCol.p) || (edCol.p.id === "custom" && edUrl.text.trim() !== "" && !root.isLoopback(edUrl.text.trim()))
                        Layout.fillWidth: true; severity: LogosNotice.Warning
                        title: "A remote provider: not on this computer"
                        message: root.remoteWarning
                    }
                    LogosNotice {
                        visible: !!edCol.p.experimental; Layout.fillWidth: true; severity: LogosNotice.Warning
                        title: "Experimental: report issues!"
                        message: "This connector follows the provider's documentation but hasn't been tried with a real key yet. If something doesn't work, please open an issue: " + root.issuesUrl
                    }
                    Text { textFormat: Text.PlainText; color: root.tierColor(edCol.p.privacy); text: "Privacy: " + (edCol.p.privacyNote || ((root.tierNames[edCol.p.privacy] || "") + " — " + (root.tierHelp[edCol.p.privacy] || ""))); wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Text { textFormat: Text.PlainText; visible: (edCol.p.steps || []).length > 0; text: "How to set it up"; color: root.cText; font.bold: true; Layout.topMargin: 6 }
                    Repeater { model: edCol.p.steps || []
                               delegate: Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cText; text: (index + 1) + ". " + modelData } }
                    Text { textFormat: Text.PlainText; visible: (edCol.p.funding || []).length > 0; text: "Paying for it"; color: root.cText; font.bold: true; Layout.topMargin: 6 }
                    Repeater { model: edCol.p.funding || []
                               delegate: Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec; text: "• " + modelData } }
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        Repeater {
                            model: Object.keys(edCol.p.links || {})
                            delegate: Btn { text: modelData; onClicked: { var u = String(edCol.p.links[modelData] || ""); if (/^https?:\/\//.test(u)) Qt.openUrlExternally(u) } }
                        }
                    }
                    Text { textFormat: Text.PlainText; text: "Base URL"; color: root.cSec; Layout.topMargin: 8 }
                    Field { id: edUrl; Layout.fillWidth: true; text: edCol.p.baseUrl || ""; placeholderText: "https://…/v1" }
                    Text { textFormat: Text.PlainText; text: edCol.p.needsKey ? "API key" : "API key (optional)"; color: root.cSec }
                    Field { id: edKey; Layout.fillWidth: true; echoMode: TextInput.Password; placeholderText: root.editId ? "leave empty to keep the stored key" : "paste the key" }
                    RowLayout {
                        visible: edCol.p.id === "custom"
                        Text { textFormat: Text.PlainText; text: "Privacy tier"; color: root.cSec }
                        TierChips { id: edTier; Layout.fillWidth: true; onChosen: function (t) { value = t } }
                    }
                    RowLayout {
                        Layout.topMargin: 8
                        Btn {
                            primary: true
                            text: root.editId ? "Save" : "Add and test"
                            onClicked: {
                                var c = { preset: edCol.p.id, baseUrl: edUrl.text.trim(), apiKey: edKey.text.trim() }
                                if (root.editId) c.id = root.editId
                                if (edCol.p.id === "custom") c.privacy = edTier.value
                                root.call("saveConnector", [JSON.stringify(c)], function (r) {
                                    var v = root.parse(r)
                                    if (!v || !v.ok) { root.toast(v && v.error ? v.error : "couldn't save"); return }
                                    root.toast(v.keyCleared ? "Saved. The address moved, so the old key was forgotten: enter the key again." : "Saved - checking the models…")
                                    root.editPreset = null; edKey.text = ""; root.refresh()
                                })
                            }
                        }
                    }
                }
            }

            // ── Apps & usage ──
            Flickable {
                anchors.fill: parent; anchors.margins: 18; contentHeight: appCol.implicitHeight; clip: true
                visible: root.page === "apps"
                ColumnLayout {
                    id: appCol; width: parent.width; spacing: 8
                    Text { textFormat: Text.PlainText; text: "Apps & usage"; color: root.cText; font.pixelSize: 18; font.bold: true }
                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec
                           text: "Apps ask for AI with the ai.ask / ai.chat intents (you approve each request) or open a chat with ai.session (you approve it once, then end it here). \"Sent\" is how much text each app has sent to models. Names are what each app declares." }
                    Repeater {
                        model: Object.keys(root.usageObj.apps || {})
                        delegate: Text { textFormat: Text.PlainText; color: root.cText; property var u: root.usageObj.apps[modelData]
                                         text: modelData + ": " + (u.requests || 0) + " requests, sent " + root.kchars(u.sentChars) + ", " + ((u.promptTokens || 0) + (u.completionTokens || 0)) + " tokens" }
                    }
                    Text { textFormat: Text.PlainText; text: "Open chats"; color: root.cText; font.bold: true; Layout.topMargin: 10 }
                    Text { textFormat: Text.PlainText; visible: root.sessionList.length === 0; color: root.cTert; font.pixelSize: 12; text: "None. An app opens one with the ai.session intent, once you allow it." }
                    Repeater {
                        model: root.sessionList
                        delegate: Rectangle {
                            Layout.fillWidth: true; implicitHeight: 52; radius: 8; color: root.cSurface; border.color: root.cBorder
                            Column {
                                x: 12; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 120
                                Text { textFormat: Text.PlainText; width: parent.width; elide: Text.ElideRight; color: root.cText; font.pixelSize: 13
                                       text: modelData.caller + "  \u00b7  \u201c" + (modelData.title || "untitled") + "\u201d" + (modelData.busy ? "  \u00b7  answering…" : "") }
                                Text { textFormat: Text.PlainText; width: parent.width; elide: Text.ElideRight; color: root.cTert; font.pixelSize: 11
                                       text: modelData.model + "  \u00b7  " + modelData.turns + " turns  \u00b7  sent " + root.kchars(modelData.sentChars) + "  \u00b7  document " + root.kchars(modelData.documentChars) }
                            }
                            Btn { anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter; danger: true; text: "End"
                                  onClicked: root.call("closeSession", [modelData.handle], function () { root.refresh() }) }
                        }
                    }
                    Text { textFormat: Text.PlainText; visible: Object.keys(root.usageObj.models || {}).length > 0; text: "Speed by model (measured on this computer)"; color: root.cText; font.bold: true; Layout.topMargin: 10 }
                    Repeater {
                        model: Object.keys(root.usageObj.models || {})
                        delegate: Text { textFormat: Text.PlainText; color: root.cSec; property var sp: root.modelSpeed(modelData)
                                         text: modelData + ": " + (sp.tps !== null ? sp.tps + " tok/s average" : "speed not measured") + (sp.ttftMs !== null ? ", " + root.secs(sp.ttftMs) + " to first token" : "") + " (" + sp.runs + (sp.runs === 1 ? " answer)" : " answers)") }
                    }
                    Text { textFormat: Text.PlainText; text: "By connector"; color: root.cText; font.bold: true; Layout.topMargin: 10 }
                    Repeater {
                        model: Object.keys(root.usageObj.connectors || {})
                        delegate: Text { textFormat: Text.PlainText; color: root.cSec; property var u: root.usageObj.connectors[modelData]
                                         text: modelData + ": " + (u.requests || 0) + " requests, " + ((u.promptTokens || 0) + (u.completionTokens || 0)) + " tokens" }
                    }
                }
            }

            // ── Settings ──
            Flickable {
                anchors.fill: parent; anchors.margins: 18; contentHeight: setCol.implicitHeight; clip: true
                visible: root.page === "settings"
                ColumnLayout {
                    id: setCol; width: Math.min(parent.width, 720); spacing: 8
                    Text { textFormat: Text.PlainText; text: "Settings"; color: root.cText; font.pixelSize: 18; font.bold: true }
                    Text { textFormat: Text.PlainText; text: "Least private tier any app may use"; color: root.cSec }
                    TierChips {
                        Layout.fillWidth: true; value: root.settingsObj.minPrivacy || "standard"
                        onChosen: function (t) { root.call("setSettings", [JSON.stringify({ minPrivacy: t })], function () { root.refresh() }) }
                    }
                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cTert; font.pixelSize: 12; text: root.tierHelp[root.settingsObj.minPrivacy || "standard"] || "" }
                    Text { textFormat: Text.PlainText; text: "Default model"; color: root.cSec; Layout.topMargin: 8 }
                    ModelPicker {
                        Layout.preferredWidth: 460; noneLabel: "The most private model available"
                        models: root.modelList; pinned: root.pinnedList(); current: root.settingsObj.defaultModel || ""
                        onPicked: function (id) { root.call("setSettings", [JSON.stringify({ defaultModel: id })], function () { root.refresh() }) }
                        onPinToggled: function (id) { root.togglePin(id) }
                    }
                    // ── the user's own instructions ──
                    Text { textFormat: Text.PlainText; text: "Your instructions"; color: root.cText; font.bold: true; Layout.topMargin: 14 }
                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec; font.pixelSize: 12
                           text: "Added to every request after the app's own instructions, marked as yours, so they win where they conflict. Apps can't see or change them; they show in the preview when an app asks." }
                    Text { textFormat: Text.PlainText; text: "For everything"; color: root.cSec; font.pixelSize: 12; Layout.topMargin: 4 }
                    InstructionBox {
                        id: insGlobal; objectName: "insGlobal"; Layout.fillWidth: true; Layout.preferredHeight: 80
                        placeholderText: "e.g. Answer in Czech. Be brief. Never make up facts."
                        saved: (root.settingsObj.instructions || {}).global || ""
                    }
                    Btn { text: insGlobal.dirty ? "Save (not saved yet)" : "Save"; primary: insGlobal.dirty; onClicked: { root.saveInstructions("", insGlobal.text.trim()); insGlobal.dirty = false } }
                    Text { textFormat: Text.PlainText; text: "For one app"; color: root.cSec; font.pixelSize: 12; Layout.topMargin: 8 }
                    Repeater {
                        model: root.instructionApps()
                        delegate: ColumnLayout {
                            Layout.fillWidth: true; spacing: 4
                            Text { textFormat: Text.PlainText; text: modelData === "ai_gateway" ? "Chat here (AI Gateway)" : modelData; color: root.cText; font.pixelSize: 13 }
                            InstructionBox {
                                id: insApp; Layout.fillWidth: true; Layout.preferredHeight: 60
                                placeholderText: modelData === "ai_gateway" ? "e.g. You are my writing assistant." : "e.g. Keep suggestions short; British spelling."
                                saved: ((root.settingsObj.instructions || {}).apps || {})[modelData] || ""
                            }
                            Btn { text: insApp.dirty ? "Save (not saved yet)" : "Save"; primary: insApp.dirty; onClicked: { root.saveInstructions(modelData, insApp.text.trim()); insApp.dirty = false } }
                        }
                    }
                    Text { textFormat: Text.PlainText; text: "Local OpenAI endpoint"; color: root.cText; font.bold: true; Layout.topMargin: 14 }
                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec; font.pixelSize: 12
                           text: "Lets tools outside Basecamp (editors, agents, scripts) use these models as an OpenAI endpoint on this computer only (127.0.0.1), with the token below." }
                    LogosSwitch {
                        text: "Enabled"; checked: !!root.serverObj.enabled
                        onToggled: root.call("setSettings", [JSON.stringify({ server: { enabled: checked } })], function () { root.refresh() })
                    }
                    Text { visible: !!root.serverObj.enabled; color: root.serverObj.running ? root.cGood : root.cBad; textFormat: Text.PlainText
                           text: root.serverObj.running ? ("Base URL " + root.serverObj.url) : ("Not running: " + (root.serverObj.error || "starting…")) }
                    RowLayout {
                        visible: !!root.serverObj.enabled
                        Field { id: tokField; Layout.preferredWidth: 360; readOnly: true; text: root.serverObj.token || "" }
                        Btn { text: "Copy"; onClicked: { tokField.selectAll(); tokField.copy(); root.toast("Token copied") } }
                        Btn { text: "New token"; onClicked: root.call("rotateServerToken", [], function () { root.refresh() }) }
                    }
                }
            }

            // ── an app asks (ai.ask / ai.chat) ──
            Flickable {
                anchors.fill: parent; anchors.margins: 18; contentHeight: inCol.implicitHeight; clip: true
                visible: root.page === "intent"
                ColumnLayout {
                    id: inCol; width: Math.min(parent.width, 760); spacing: 8
                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cText; font.pixelSize: 18; font.bold: true
                           text: root.intentName === "ai.session" ? root.intentFrom + " wants to chat with AI about \u201c" + (root.intentParams.title || "") + "\u201d" : root.intentFrom + " asks AI" }
                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec
                           text: root.intentName === "ai.session"
                                 ? (root.intentParams.purpose ? String(root.intentParams.purpose) + "\n\n" : "") + "If you allow it, every message " + root.intentFrom + " sends in this chat goes to the model you choose here without asking again, until the app or you end it (Apps & usage). This is what it starts with:"
                                 : "This is exactly what will be sent to the model you choose. Nothing is sent until you press Run." }
                    Rectangle {
                        Layout.fillWidth: true; radius: 8; color: root.cSurface; border.color: root.cBorder
                        implicitHeight: Math.min(prev.implicitHeight + 20, 300)
                        Flickable { anchors.fill: parent; anchors.margins: 10; contentHeight: prev.implicitHeight; clip: true
                            TextEdit { id: prev; width: parent.width; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; color: root.cText; font.pixelSize: 13
                                       text: root.previewMessages().map(function (m) { return "[" + m.role + "] " + (typeof m.content === "string" ? m.content : JSON.stringify(m.content)) }).join("\n\n") } }
                    }
                    Text { textFormat: Text.PlainText; color: root.cSec; text: "The app asks for at least: " + (root.tierNames[root.intentFloor()] || root.intentFloor()) }
                    Text {
                        textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cWarn
                        visible: !!root.intentModel && ((root.modelById(root.intentModel) || {}).privacy || "") !== "local"
                        text: "This answer comes from a remote provider: your text leaves this computer."
                    }
                    RowLayout {
                        Text { textFormat: Text.PlainText; text: "Model"; color: root.cSec }
                        ModelPicker {
                            Layout.preferredWidth: 460; enabled: root.intentState === "ask"
                            models: root.modelsAtLeast(root.intentFloor()); pinned: root.pinnedList(); current: root.intentModel
                            onPicked: function (id) { root.intentModel = id }
                            onPinToggled: function (id) { root.togglePin(id) }
                        }
                    }
                    Text { textFormat: Text.PlainText; visible: root.modelsAtLeast(root.intentFloor()).length === 0; color: root.cBad; wrapMode: Text.Wrap; Layout.fillWidth: true
                           text: "No model you have set up is private enough for this request. Add a local runtime or a TEE provider in Connectors." }
                    RowLayout {
                        visible: root.intentState === "ask"
                        Btn { primary: true; text: root.intentName === "ai.session" ? "Allow this chat" : "Run"; enabled: !!root.intentModel; onClicked: root.runIntent() }
                        Btn { text: "Decline"; onClicked: root.declineIntent() }
                    }
                    Text { textFormat: Text.PlainText; visible: root.intentState !== "ask" && root.intentState !== ""; text: root.intentState === "running" ? "Answering…" : root.intentState === "done" ? (root.intentName === "ai.session" ? "Chat allowed" : "Answer sent back to " + root.intentFrom + root.speedText(root.intentStats)) : "Failed"; color: root.intentState === "error" ? root.cBad : root.cSec }
                    TextEdit { visible: root.intentAnswer !== ""; Layout.fillWidth: true; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; color: root.cText; font.pixelSize: 14; text: root.intentAnswer }
                    Btn { visible: root.intentState === "running"; text: "Stop"; onClicked: root.declineIntent() }
                    Btn { visible: root.intentState === "done" || root.intentState === "error"; text: "Close"; onClicked: { root.intentState = ""; root.page = "chat" } }
                }
            }
        }
    }


    // ── controls: thin wrappers over the design system's (Logos.Controls) ──
    component Btn: LogosButton {
        property bool primary: false
        property bool danger: false        // kept for call sites; the design system has no danger variant
        variant: primary ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
        compact: true
    }
    component Field: LogosTextField {
        function selectAll() { textInput.selectAll() }
        function copy() { textInput.copy() }
    }
    // A text box for the user's instructions. It shows the saved text, but never overwrites what the user is
    // typing: the view refreshes settings every few seconds, and a plain binding would reset the box.
    component InstructionBox: LogosTextArea {
        property string saved: ""
        property bool dirty: false
        wrapMode: TextArea.Wrap
        Component.onCompleted: text = saved
        onSavedChanged: if (!dirty) text = saved
        onTextChanged: if (text !== saved) dirty = true; else dirty = false
    }
    // the design system's badge, for connectors built from docs but not yet tried with a real key
    component ExperimentalBadge: LogosBadge {
        text: "Experimental: report issues!"
        color: Theme.palette.warning
    }
    // one chip per privacy tier; `value` is the chosen tier id
    component TierChips: Flow {
        id: tc
        property string value: "standard"
        signal chosen(string tier)
        spacing: 6
        Repeater {
            model: [["standard", "Standard"], ["no-retention", "No retention"], ["tee", "TEE"], ["tee-e2ee", "TEE + E2EE"], ["local", "On this device"]]
            delegate: Rectangle {
                property bool on: tc.value === modelData[0]
                width: ct.implicitWidth + 22; height: 28; radius: 14
                color: on ? Theme.palette.surfaceRaised : Theme.palette.backgroundSecondary; border.color: on ? Theme.palette.primary : Theme.palette.border
                Text { textFormat: Text.PlainText; id: ct; anchors.centerIn: parent; text: modelData[1]; font.pixelSize: 12; color: parent.on ? Theme.palette.text : Theme.palette.textSecondary }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tc.chosen(modelData[0]) }
            }
        }
    }
    // A model chooser: shows the current model, opens a searchable list with the pinned models on top.
    // The star pins/unpins (persisted by the core as settings.pinnedModels).
    component ModelPicker: Rectangle {
        id: mp
        property var models: []            // [{id, name, connectorName, privacy}]
        property var pinned: []            // [model id]
        property string current: ""
        property string noneLabel: ""      // if set, an extra first row that picks ""
        property var speeds: ({})          // model id -> average tokens/s measured here
        signal picked(string id)
        signal pinToggled(string id)
        function tierName(t) { return ({ "standard": "Standard", "no-retention": "No retention", "tee": "TEE", "tee-e2ee": "TEE + E2EE", "local": "On this device" })[t] || t || "" }
        function tierColor(t) { return t === "local" ? Theme.palette.success : (t === "tee" || t === "tee-e2ee") ? Theme.palette.info : t === "no-retention" ? Theme.palette.warning : Theme.palette.textTertiary }
        function find(id) { for (var i = 0; i < models.length; i++) if (models[i].id === id) return models[i]; return null }
        function rows(q) {
            q = (q || "").toLowerCase().trim()
            var match = function (m) { return !q || (m.name + " " + m.id + " " + m.connectorName + " " + tierName(m.privacy)).toLowerCase().indexOf(q) >= 0 }
            var pins = [], rest = [], out = []
            for (var i = 0; i < pinned.length; i++) { var p = find(pinned[i]); if (p && match(p)) pins.push(p) }
            for (var j = 0; j < models.length; j++) if (pinned.indexOf(models[j].id) < 0 && match(models[j])) rest.push(models[j])
            if (noneLabel && !q) out.push({ none: true })
            if (pins.length) { out.push({ header: "Pinned" }); out = out.concat(pins) }
            if (rest.length) { if (pins.length) out.push({ header: "All models" }); out = out.concat(rest) }
            return out
        }
        property var cur: find(current)
        function openList() { search.text = ""; list.currentIndex = -1; pop.open(); search.textInput.forceActiveFocus() }
        implicitWidth: 420; implicitHeight: 34; radius: 6
        color: pma.containsMouse ? Theme.palette.surface : Theme.palette.backgroundInset; border.color: pop.visible ? Theme.palette.primary : Theme.palette.border
        opacity: enabled ? 1 : 0.5
        Row {
            anchors.verticalCenter: parent.verticalCenter; x: 10; spacing: 8; width: parent.width - 40; clip: true
            Rectangle { visible: !!mp.cur; anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: mp.tierColor(mp.cur ? mp.cur.privacy : "") }
            Text { textFormat: Text.PlainText; anchors.verticalCenter: parent.verticalCenter; color: mp.cur || mp.noneLabel ? Theme.palette.text : Theme.palette.textTertiary; font.pixelSize: 13; elide: Text.ElideRight; width: parent.width - 16
                   text: mp.cur ? mp.cur.name + "   " + mp.cur.connectorName + " · " + mp.tierName(mp.cur.privacy) : (mp.noneLabel || (mp.models.length ? "Choose a model" : "No models")) }
        }
        Text { textFormat: Text.PlainText; anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter; text: "▾"; color: Theme.palette.textSecondary }
        MouseArea { id: pma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: if (mp.enabled) mp.openList() }
        Popup {
            id: pop
            y: mp.height + 4; width: Math.max(mp.width, 480); height: 420; padding: 8
            background: Rectangle { color: Theme.palette.backgroundSecondary; radius: 8; border.color: Theme.palette.border }
            property var shown: mp.rows(search.text)
            function firstModel(from, dir) { for (var i = from; i >= 0 && i < shown.length; i += dir) if (!shown[i].header) return i; return list.currentIndex }
            function choose(r) { if (!r || r.header) return; pop.close(); mp.picked(r.none ? "" : r.id) }
            ColumnLayout {
                anchors.fill: parent; spacing: 6
                LogosSearchBar {
                    id: search; objectName: "pickerSearch"; Layout.fillWidth: true; placeholderText: "Search models, providers, privacy…"
                    Keys.onDownPressed: list.currentIndex = pop.firstModel(list.currentIndex + 1, 1)
                    Keys.onUpPressed: list.currentIndex = pop.firstModel(list.currentIndex - 1, -1)
                    Keys.onEscapePressed: pop.close()
                    onSubmitted: pop.choose(pop.shown[list.currentIndex >= 0 ? list.currentIndex : pop.firstModel(0, 1)])
                }
                Text { textFormat: Text.PlainText; visible: pop.shown.length === 0; text: "No model matches."; color: Theme.palette.textTertiary; font.pixelSize: 12; Layout.leftMargin: 4 }
                ListView {
                    id: list; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; model: pop.shown
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Item {
                        property var r: modelData
                        width: list.width; height: r.header ? 26 : 38
                        Text { textFormat: Text.PlainText; visible: !!r.header; text: r.header || ""; color: Theme.palette.textTertiary; font.pixelSize: 11; font.bold: true; x: 8; anchors.bottom: parent.bottom; anchors.bottomMargin: 4 }
                        Rectangle {
                            visible: !r.header; anchors.fill: parent; radius: 6
                            color: index === list.currentIndex || rma.containsMouse ? Theme.palette.surfaceRaised : ((r.none ? "" === mp.current : r.id === mp.current) ? Theme.palette.backgroundSecondary : "transparent")
                            MouseArea { id: rma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pop.choose(r) }
                            Rectangle { visible: !r.none; x: 10; anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: mp.tierColor(r.privacy) }
                            Column {
                                x: 26; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 26 - 40
                                Text { textFormat: Text.PlainText; text: r.none ? mp.noneLabel : (r.name || ""); color: Theme.palette.text; font.pixelSize: 13; elide: Text.ElideRight; width: parent.width }
                                Text { textFormat: Text.PlainText; visible: !r.none; text: (r.connectorName || "") + " · " + mp.tierName(r.privacy) + (mp.speeds[r.id] !== undefined ? " · ≈ " + mp.speeds[r.id] + " tok/s" : "") + (r.name !== r.id ? " · " + r.id : ""); color: Theme.palette.textTertiary; font.pixelSize: 11; elide: Text.ElideRight; width: parent.width }
                            }
                            Text { textFormat: Text.PlainText;
                                visible: !r.none; anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                property bool on: mp.pinned.indexOf(r.id) >= 0
                                text: on ? "★" : "☆"; font.pixelSize: 17; color: on ? Theme.palette.warning : (sma.containsMouse ? Theme.palette.text : Theme.palette.textTertiary)
                                MouseArea { id: sma; anchors.fill: parent; anchors.margins: -8; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: mp.pinToggled(r.id) }
                            }
                        }
                    }
                }
                Text { textFormat: Text.PlainText; text: "★ pins a model to the top of every list.  ↑↓ Enter to pick."; color: Theme.palette.textTertiary; font.pixelSize: 11; Layout.leftMargin: 4 }
            }
        }
    }

    Rectangle {
        visible: root.toastMsg !== ""
        anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottomMargin: 20
        radius: 6; color: root.cRaised; border.color: root.cBorder
        width: toastText.implicitWidth + 24; height: toastText.implicitHeight + 14
        Text { textFormat: Text.PlainText; id: toastText; anchors.centerIn: parent; text: root.toastMsg; color: root.cText }
    }
}
