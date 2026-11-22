import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
// The host requires these imports for custom colours to apply; the view styles with its own palette.
import Logos.Theme
import Logos.Controls

// AI Gateway - pure-QML view over ai_gateway_core (ADR 0001), and the provider of the ai.ask and
// ai.chat intents. Every call to the core is async (callModuleAsync): inference outlives the IPC
// timeout, so a chat is a job whose updates arrive as jobUpdate events.
Item {
    id: root
    anchors.fill: parent

    // ── palette ──
    readonly property color cBg: "#0f1115"
    readonly property color cSurface: "#171a21"
    readonly property color cRaised: "#1f232c"
    readonly property color cBorder: "#2b303b"
    readonly property color cText: "#e6e8ee"
    readonly property color cSec: "#a3a9b8"
    readonly property color cTert: "#6d7486"
    readonly property color cAccent: "#7c9cff"
    readonly property color cGood: "#4fc28a"
    readonly property color cWarn: "#e6b450"
    readonly property color cBad: "#e66a6a"

    // ── state ──
    property string page: "chat"
    property var presetList: []
    property var connectorList: []
    property var modelList: []
    property var settingsObj: ({})
    property var serverObj: ({})
    property var usageObj: ({})
    property var sessionList: []
    property string toastMsg: ""
    // chat
    property var chatMessages: []          // [{role, content, model?, privacy?}]
    property string chatModel: ""
    property string chatJob: ""
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
    property string intentAnswer: ""
    property string intentState: ""       // "", ask, running, done, error

    readonly property var tierNames: ({ "standard": "Standard", "no-retention": "No retention", "tee": "TEE", "tee-e2ee": "TEE + E2EE", "local": "On this device" })
    readonly property var tierHelp: ({
        "standard": "The provider makes no privacy promise.",
        "no-retention": "The provider promises not to keep your prompts (not verifiable).",
        "tee": "Runs in confidential computing (attested hardware); claimed by the provider, not yet verified here.",
        "tee-e2ee": "Encrypted end to end into attested hardware.",
        "local": "Runs on this computer; nothing leaves it."
    })
    readonly property var tierOrder: ["standard", "no-retention", "tee", "tee-e2ee", "local"]
    function tierColor(t) { return t === "local" ? cGood : (t === "tee" || t === "tee-e2ee") ? cAccent : t === "no-retention" ? cWarn : cTert }
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
            chatJob = v.jobId; chatPartial = ""
        })
    }
    function onJobUpdate(id, u) {
        if (id === chatJob) {
            if (u.delta) chatPartial += u.delta
            if (u.state && u.state !== "running") {
                var msgs = chatMessages.slice()
                if (u.state === "done") msgs.push({ role: "assistant", content: u.text || chatPartial, model: u.model, privacy: u.privacy })
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
                    intentAnswer = u.text || intentAnswer; intentState = "done"
                    var m = modelById(u.model)
                    finishIntent(true, { text: intentAnswer, model: u.model || "", connector: u.connector || "", privacy: u.privacy || "", usage: u.usage || {} }, "")
                } else { intentState = "error"; intentAnswer = u.error || u.state; finishIntent(false, { message: String(u.error || u.state).substring(0, 300) }, u.state === "cancelled" ? "cancelled" : "failed") }
                refresh()
            }
        }
    }
    // poll as a fallback for hosts that don't forward module events
    Timer {
        interval: 700; repeat: true; running: !!(root.chatJob || root.intentJob)
        onTriggered: {
            [root.chatJob, root.intentJob].forEach(function (id) {
                if (!id) return
                root.call("job", [id], function (r) {
                    var v = root.parse(r); if (!v || !v.ok) return
                    var known = id === root.chatJob ? root.chatPartial : root.intentAnswer
                    var u = { state: v.state, text: v.text, model: v.model, connector: v.connector, privacy: v.privacy, error: v.error, usage: v.usage }
                    if (v.state === "running" && v.text && v.text.length > known.length) u.delta = v.text.substring(known.length)
                    if (v.state === "running" && !u.delta) return
                    root.onJobUpdate(id, u)
                })
            })
        }
    }

    // ── intents (ai.ask / ai.chat) ──
    function intentMessages() {
        var p = intentParams
        if (intentName === "ai.chat") return p.messages || []
        if (intentName === "ai.session") {
            var s = []
            if (p.system) s.push({ role: "system", content: String(p.system) })
            if (p.document) { var d = String(p.document); s.push({ role: "document", content: d.length > 4000 ? d.substring(0, 4000) + "\n… (" + d.length + " characters in all)" : d }) }
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
        intentAnswer = ""; intentJob = ""; intentState = "ask"
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
                finishIntent(true, { sessionId: v.sessionId, model: v.model || "", connector: v.connectorName || "", privacy: v.privacy || "" }, "")
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
            intentJob = v.jobId; intentState = "running"
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
                // the runtime delivers an event's arguments as {arg0, arg1} (seen with logosctl 0.3.1);
                // an array or named fields are accepted too
                var args = Array.isArray(data) ? data : null
                var id = args ? args[0] : (data && (data.arg0 || data.jobId))
                var raw = args ? args[1] : (data && (data.arg1 || data.updateJson))
                var u = typeof raw === "string" ? root.parse(raw) : raw
                if (id && u) root.onJobUpdate(id, u)
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
                Text { text: "AI Gateway"; color: root.cText; font.pixelSize: 18; font.bold: true; Layout.bottomMargin: 10 }
                Repeater {
                    model: [["chat", "Chat"], ["connectors", "Connectors"], ["apps", "Apps & usage"], ["settings", "Settings"]]
                    delegate: Rectangle {
                        Layout.fillWidth: true; height: 34; radius: 6
                        color: root.page === modelData[0] ? root.cRaised : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; x: 10; text: modelData[1]; color: root.page === modelData[0] ? root.cText : root.cSec; font.pixelSize: 14 }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.page = modelData[0] }
                    }
                }
                Rectangle {
                    visible: root.intentState !== ""
                    Layout.fillWidth: true; height: 34; radius: 6; color: root.page === "intent" ? root.cRaised : "transparent"; border.color: root.cAccent
                    Text { anchors.verticalCenter: parent.verticalCenter; x: 10; text: "Request from " + root.intentFrom; color: root.cAccent; font.pixelSize: 13; elide: Text.ElideRight; width: parent.width - 16 }
                    MouseArea { anchors.fill: parent; onClicked: root.page = "intent" }
                }
                Item { Layout.fillHeight: true }
                Text {
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
                    Text { text: "Model"; color: root.cSec }
                    ModelPicker {
                        objectName: "chatPicker"; Layout.preferredWidth: 460
                        models: root.modelList; pinned: root.pinnedList(); current: root.chatModel
                        onPicked: function (id) { root.chatModel = id }
                        onPinToggled: function (id) { root.togglePin(id) }
                    }
                    Item { Layout.fillWidth: true }
                    Btn { text: "New chat"; onClicked: { root.chatMessages = []; root.chatPartial = "" } }
                }
                Text {
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
                        color: m.role === "user" ? root.cRaised : m.role === "error" ? "#3a1f22" : root.cSurface
                        height: body.implicitHeight + meta.implicitHeight + 24
                        Text { id: meta; x: 12; y: 8; color: root.cTert; font.pixelSize: 11
                               text: m.role === "user" ? "You" : m.role === "error" ? "Error" : ("AI" + (m.model ? "  ·  " + m.model : "") + (m.privacy ? "  ·  " + (root.tierNames[m.privacy] || m.privacy) : "")) }
                        TextEdit { id: body; x: 12; y: meta.y + meta.implicitHeight + 4; width: parent.width - 24; readOnly: true; selectByMouse: true
                                   wrapMode: TextEdit.Wrap; color: root.cText; font.pixelSize: 14; text: m.content }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    ScrollView {
                        Layout.fillWidth: true; Layout.preferredHeight: Math.min(Math.max(chatInput.implicitHeight, 46), 180)
                        TextArea {
                            id: chatInput; objectName: "chatInput"
                            wrapMode: TextArea.Wrap; font.pixelSize: 14
                            color: root.cText; placeholderTextColor: root.cTert; selectionColor: "#3d4f80"; selectedTextColor: "#ffffff"
                            leftPadding: 12; rightPadding: 12; topPadding: 12; bottomPadding: 12
                            placeholderText: "Ask anything  (Enter sends, Shift+Enter for a new line)"
                            background: Rectangle { radius: 8; color: "#12151b"; border.color: chatInput.activeFocus ? root.cAccent : root.cBorder }
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
                    Text { text: "Connectors"; color: root.cText; font.pixelSize: 18; font.bold: true }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec
                           text: "Where your AI runs. Local runtimes keep everything on this computer; private providers promise more than usual, and the tier shows how much. Keys stay on this computer and only ever go to their own provider." }
                    Repeater {
                        model: root.connectorList
                        delegate: Rectangle {
                            Layout.fillWidth: true; radius: 8; color: root.cSurface; border.color: root.cBorder
                            implicitHeight: cc.implicitHeight + 20
                            ColumnLayout {
                                id: cc; x: 12; y: 10; width: parent.width - 24; spacing: 4
                                RowLayout {
                                    Text { text: modelData.name; color: root.cText; font.pixelSize: 15; font.bold: true }
                                    Rectangle { radius: 4; color: "transparent"; border.color: root.tierColor(modelData.privacy); implicitWidth: tl.implicitWidth + 10; implicitHeight: tl.implicitHeight + 4
                                                Text { id: tl; anchors.centerIn: parent; text: modelData.privacyNote ? "Varies by model" : (root.tierNames[modelData.privacy] || modelData.privacy); color: root.tierColor(modelData.privacy); font.pixelSize: 11 } }
                                    Item { Layout.fillWidth: true }
                                    Btn { text: "Test"; onClicked: root.call("testConnector", [modelData.id], function () { root.toast("Testing " + modelData.name + "…") }) }
                                    Btn { text: "Edit"; onClicked: { root.editId = modelData.id; root.editPreset = root.presetById(modelData.preset) } }
                                    Btn { danger: true; text: "Remove"; onClicked: root.call("removeConnector", [modelData.id], function () { root.refresh() }) }
                                }
                                Text { color: root.cSec; font.pixelSize: 12; text: modelData.baseUrl + (modelData.hasKey ? "  ·  key " + modelData.apiKey : "") }
                                Text { color: modelData.error ? root.cBad : root.cGood; font.pixelSize: 12
                                       text: modelData.error ? modelData.error : (modelData.models + " models available") }
                                Text { visible: !!modelData.balance; color: root.cSec; font.pixelSize: 12
                                       text: { var b = modelData.balance || {}; var o = []; for (var k in b) o.push(k.replace("x-venice-balance-", "") + " " + b[k]); return "Balance: " + o.join(", ") } }
                            }
                        }
                    }
                    Text { text: "Add a connector"; color: root.cText; font.pixelSize: 16; font.bold: true; Layout.topMargin: 10 }
                    GridLayout {
                        Layout.fillWidth: true; columns: 3; columnSpacing: 10; rowSpacing: 10
                        Repeater {
                            model: root.presetList
                            delegate: Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 92; radius: 8; color: root.cSurface; border.color: root.cBorder
                                ColumnLayout {
                                    x: 10; y: 8; width: parent.width - 20; spacing: 2
                                    Text { text: modelData.name; color: root.cText; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: modelData.privacyNote || root.tierNames[modelData.privacy] || modelData.privacy; color: root.tierColor(modelData.privacy); font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: modelData.blurb; color: root.cSec; font.pixelSize: 11; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; Layout.fillWidth: true }
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.editId = ""; root.editPreset = modelData } }
                            }
                        }
                    }
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
                        Text { text: edCol.p.name || ""; color: root.cText; font.pixelSize: 18; font.bold: true }
                    }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec; text: edCol.p.blurb || "" }
                    Text { color: root.tierColor(edCol.p.privacy); text: "Privacy: " + (edCol.p.privacyNote || ((root.tierNames[edCol.p.privacy] || "") + " — " + (root.tierHelp[edCol.p.privacy] || ""))); wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Text { visible: (edCol.p.steps || []).length > 0; text: "How to set it up"; color: root.cText; font.bold: true; Layout.topMargin: 6 }
                    Repeater { model: edCol.p.steps || []
                               delegate: Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cText; text: (index + 1) + ". " + modelData } }
                    Text { visible: (edCol.p.funding || []).length > 0; text: "Paying for it"; color: root.cText; font.bold: true; Layout.topMargin: 6 }
                    Repeater { model: edCol.p.funding || []
                               delegate: Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec; text: "• " + modelData } }
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        Repeater {
                            model: Object.keys(edCol.p.links || {})
                            delegate: Btn { text: modelData; onClicked: Qt.openUrlExternally(edCol.p.links[modelData]) }
                        }
                    }
                    Text { text: "Base URL"; color: root.cSec; Layout.topMargin: 8 }
                    Field { id: edUrl; Layout.fillWidth: true; text: edCol.p.baseUrl || ""; placeholderText: "https://…/v1" }
                    Text { text: edCol.p.needsKey ? "API key" : "API key (optional)"; color: root.cSec }
                    Field { id: edKey; Layout.fillWidth: true; echoMode: TextInput.Password; placeholderText: root.editId ? "leave empty to keep the stored key" : "paste the key" }
                    RowLayout {
                        visible: edCol.p.id === "custom"
                        Text { text: "Privacy tier"; color: root.cSec }
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
                                    root.toast("Saved - checking the models…"); root.editPreset = null; edKey.text = ""; root.refresh()
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
                    Text { text: "Apps & usage"; color: root.cText; font.pixelSize: 18; font.bold: true }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec
                           text: "Apps ask for AI with the ai.ask / ai.chat intents (you approve each request) or call the core directly. Names are what each app declares." }
                    Repeater {
                        model: Object.keys(root.usageObj.apps || {})
                        delegate: Text { color: root.cText; property var u: root.usageObj.apps[modelData]
                                         text: modelData + ": " + (u.requests || 0) + " requests, " + ((u.promptTokens || 0) + (u.completionTokens || 0)) + " tokens" }
                    }
                    Text { text: "Open chats"; color: root.cText; font.bold: true; Layout.topMargin: 10 }
                    Text { visible: root.sessionList.length === 0; color: root.cTert; font.pixelSize: 12; text: "None. An app opens one with the ai.session intent, once you allow it." }
                    Repeater {
                        model: root.sessionList
                        delegate: Rectangle {
                            Layout.fillWidth: true; implicitHeight: 52; radius: 8; color: root.cSurface; border.color: root.cBorder
                            Column {
                                x: 12; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 120
                                Text { width: parent.width; elide: Text.ElideRight; color: root.cText; font.pixelSize: 13
                                       text: modelData.caller + "  \u00b7  \u201c" + (modelData.title || "untitled") + "\u201d" + (modelData.busy ? "  \u00b7  answering…" : "") }
                                Text { width: parent.width; elide: Text.ElideRight; color: root.cTert; font.pixelSize: 11
                                       text: modelData.model + "  \u00b7  " + modelData.turns + " turns  \u00b7  document " + Math.round((modelData.documentChars || 0) / 1000) + " k chars" }
                            }
                            Btn { anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter; danger: true; text: "End"
                                  onClicked: root.call("closeSession", [modelData.id], function () { root.refresh() }) }
                        }
                    }
                    Text { text: "By connector"; color: root.cText; font.bold: true; Layout.topMargin: 10 }
                    Repeater {
                        model: Object.keys(root.usageObj.connectors || {})
                        delegate: Text { color: root.cSec; property var u: root.usageObj.connectors[modelData]
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
                    Text { text: "Settings"; color: root.cText; font.pixelSize: 18; font.bold: true }
                    Text { text: "Least private tier any app may use"; color: root.cSec }
                    TierChips {
                        Layout.fillWidth: true; value: root.settingsObj.minPrivacy || "standard"
                        onChosen: function (t) { root.call("setSettings", [JSON.stringify({ minPrivacy: t })], function () { root.refresh() }) }
                    }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cTert; font.pixelSize: 12; text: root.tierHelp[root.settingsObj.minPrivacy || "standard"] || "" }
                    Text { text: "Default model"; color: root.cSec; Layout.topMargin: 8 }
                    ModelPicker {
                        Layout.preferredWidth: 460; noneLabel: "The most private model available"
                        models: root.modelList; pinned: root.pinnedList(); current: root.settingsObj.defaultModel || ""
                        onPicked: function (id) { root.call("setSettings", [JSON.stringify({ defaultModel: id })], function () { root.refresh() }) }
                        onPinToggled: function (id) { root.togglePin(id) }
                    }
                    Text { text: "Local OpenAI endpoint"; color: root.cText; font.bold: true; Layout.topMargin: 14 }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec; font.pixelSize: 12
                           text: "Lets tools outside Basecamp (editors, agents, scripts) use these models as an OpenAI endpoint on this computer only (127.0.0.1), with the token below." }
                    Check {
                        text: "Enabled"; checked: !!root.serverObj.enabled
                        onToggled: function (on) { root.call("setSettings", [JSON.stringify({ server: { enabled: on } })], function () { root.refresh() }) }
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
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cText; font.pixelSize: 18; font.bold: true
                           text: root.intentName === "ai.session" ? root.intentFrom + " wants to chat with AI about \u201c" + (root.intentParams.title || "") + "\u201d" : root.intentFrom + " asks AI" }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec
                           text: root.intentName === "ai.session"
                                 ? (root.intentParams.purpose ? String(root.intentParams.purpose) + "\n\n" : "") + "If you allow it, every message " + root.intentFrom + " sends in this chat goes to the model you choose here without asking again, until the app or you end it (Apps & usage). This is what it starts with:"
                                 : "This is exactly what will be sent to the model you choose. Nothing is sent until you press Run." }
                    Rectangle {
                        Layout.fillWidth: true; radius: 8; color: root.cSurface; border.color: root.cBorder
                        implicitHeight: Math.min(prev.implicitHeight + 20, 300)
                        Flickable { anchors.fill: parent; anchors.margins: 10; contentHeight: prev.implicitHeight; clip: true
                            TextEdit { id: prev; width: parent.width; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; color: root.cText; font.pixelSize: 13
                                       text: root.intentMessages().map(function (m) { return "[" + m.role + "] " + (typeof m.content === "string" ? m.content : JSON.stringify(m.content)) }).join("\n\n") } }
                    }
                    Text { color: root.cSec; text: "The app asks for at least: " + (root.tierNames[root.intentFloor()] || root.intentFloor()) }
                    RowLayout {
                        Text { text: "Model"; color: root.cSec }
                        ModelPicker {
                            Layout.preferredWidth: 460; enabled: root.intentState === "ask"
                            models: root.modelsAtLeast(root.intentFloor()); pinned: root.pinnedList(); current: root.intentModel
                            onPicked: function (id) { root.intentModel = id }
                            onPinToggled: function (id) { root.togglePin(id) }
                        }
                    }
                    Text { visible: root.modelsAtLeast(root.intentFloor()).length === 0; color: root.cBad; wrapMode: Text.Wrap; Layout.fillWidth: true
                           text: "No model you have set up is private enough for this request. Add a local runtime or a TEE provider in Connectors." }
                    RowLayout {
                        visible: root.intentState === "ask"
                        Btn { primary: true; text: root.intentName === "ai.session" ? "Allow this chat" : "Run"; enabled: !!root.intentModel; onClicked: root.runIntent() }
                        Btn { text: "Decline"; onClicked: root.declineIntent() }
                    }
                    Text { visible: root.intentState !== "ask" && root.intentState !== ""; text: root.intentState === "running" ? "Answering…" : root.intentState === "done" ? (root.intentName === "ai.session" ? "Chat allowed" : "Answer sent back to " + root.intentFrom) : "Failed"; color: root.intentState === "error" ? root.cBad : root.cSec }
                    TextEdit { visible: root.intentAnswer !== ""; Layout.fillWidth: true; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; color: root.cText; font.pixelSize: 14; text: root.intentAnswer }
                    Btn { visible: root.intentState === "running"; text: "Stop"; onClicked: root.declineIntent() }
                    Btn { visible: root.intentState === "done" || root.intentState === "error"; text: "Close"; onClicked: { root.intentState = ""; root.page = "chat" } }
                }
            }
        }
    }


    // ── controls: dark, readable, ours (the default Qt style is light and ignores the palette) ──
    // Inline components can't see this file's ids, so the palette is repeated here.
    component Btn: Rectangle {
        id: b
        property string text: ""
        property bool primary: false
        property bool danger: false
        signal clicked()
        implicitWidth: bl.implicitWidth + 24; implicitHeight: 32; radius: 6
        opacity: enabled ? 1 : 0.45
        color: primary ? (ma.containsMouse ? "#93adff" : "#7c9cff") : (ma.containsMouse ? "#2a2f3a" : "#1f232c")
        border.color: primary ? "transparent" : (danger ? "#e66a6a" : "#2b303b")
        Text { id: bl; anchors.centerIn: parent; text: b.text; font.pixelSize: 13; font.bold: b.primary
               color: b.primary ? "#0f1115" : (b.danger ? "#e66a6a" : "#e6e8ee") }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (b.enabled) b.clicked() }
    }
    component Field: TextField {
        color: "#e6e8ee"; placeholderTextColor: "#6d7486"; selectionColor: "#3d4f80"; selectedTextColor: "#ffffff"
        font.pixelSize: 13; leftPadding: 10; rightPadding: 10; topPadding: 7; bottomPadding: 7
        background: Rectangle { radius: 6; color: "#12151b"; border.color: parent.activeFocus ? "#7c9cff" : "#2b303b" }
    }
    component Check: Row {
        id: ck
        property bool checked: false
        property string text: ""
        signal toggled(bool checked)
        spacing: 8
        Rectangle { width: 36; height: 20; radius: 10; color: ck.checked ? "#7c9cff" : "#2b303b"; anchors.verticalCenter: parent.verticalCenter
            Rectangle { width: 16; height: 16; radius: 8; y: 2; x: ck.checked ? 18 : 2; color: "#e6e8ee"; Behavior on x { NumberAnimation { duration: 120 } } } }
        Text { text: ck.text; color: "#e6e8ee"; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
        TapHandler { onTapped: ck.toggled(!ck.checked) }
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
                color: on ? "#25304d" : "#1f232c"; border.color: on ? "#7c9cff" : "#2b303b"
                Text { id: ct; anchors.centerIn: parent; text: modelData[1]; font.pixelSize: 12; color: parent.on ? "#e6e8ee" : "#a3a9b8" }
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
        signal picked(string id)
        signal pinToggled(string id)
        function tierName(t) { return ({ "standard": "Standard", "no-retention": "No retention", "tee": "TEE", "tee-e2ee": "TEE + E2EE", "local": "On this device" })[t] || t || "" }
        function tierColor(t) { return t === "local" ? "#4fc28a" : (t === "tee" || t === "tee-e2ee") ? "#7c9cff" : t === "no-retention" ? "#e6b450" : "#6d7486" }
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
        function openList() { search.text = ""; list.currentIndex = -1; pop.open(); search.forceActiveFocus() }
        implicitWidth: 420; implicitHeight: 34; radius: 6
        color: pma.containsMouse ? "#22262f" : "#12151b"; border.color: pop.visible ? "#7c9cff" : "#2b303b"
        opacity: enabled ? 1 : 0.5
        Row {
            anchors.verticalCenter: parent.verticalCenter; x: 10; spacing: 8; width: parent.width - 40; clip: true
            Rectangle { visible: !!mp.cur; anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: mp.tierColor(mp.cur ? mp.cur.privacy : "") }
            Text { anchors.verticalCenter: parent.verticalCenter; color: mp.cur || mp.noneLabel ? "#e6e8ee" : "#6d7486"; font.pixelSize: 13; elide: Text.ElideRight; width: parent.width - 16
                   text: mp.cur ? mp.cur.name + "   " + mp.cur.connectorName + " · " + mp.tierName(mp.cur.privacy) : (mp.noneLabel || (mp.models.length ? "Choose a model" : "No models")) }
        }
        Text { anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter; text: "▾"; color: "#a3a9b8" }
        MouseArea { id: pma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: if (mp.enabled) mp.openList() }
        Popup {
            id: pop
            y: mp.height + 4; width: Math.max(mp.width, 480); height: 420; padding: 8
            background: Rectangle { color: "#171a21"; radius: 8; border.color: "#2b303b" }
            property var shown: mp.rows(search.text)
            function firstModel(from, dir) { for (var i = from; i >= 0 && i < shown.length; i += dir) if (!shown[i].header) return i; return list.currentIndex }
            function choose(r) { if (!r || r.header) return; pop.close(); mp.picked(r.none ? "" : r.id) }
            ColumnLayout {
                anchors.fill: parent; spacing: 6
                Field {
                    id: search; objectName: "pickerSearch"; Layout.fillWidth: true; placeholderText: "Search models, providers, privacy…"
                    Keys.onDownPressed: list.currentIndex = pop.firstModel(list.currentIndex + 1, 1)
                    Keys.onUpPressed: list.currentIndex = pop.firstModel(list.currentIndex - 1, -1)
                    Keys.onReturnPressed: pop.choose(pop.shown[list.currentIndex >= 0 ? list.currentIndex : pop.firstModel(0, 1)])
                    Keys.onEnterPressed: pop.choose(pop.shown[list.currentIndex >= 0 ? list.currentIndex : pop.firstModel(0, 1)])
                    Keys.onEscapePressed: pop.close()
                }
                Text { visible: pop.shown.length === 0; text: "No model matches."; color: "#6d7486"; font.pixelSize: 12; Layout.leftMargin: 4 }
                ListView {
                    id: list; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; model: pop.shown
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Item {
                        property var r: modelData
                        width: list.width; height: r.header ? 26 : 38
                        Text { visible: !!r.header; text: r.header || ""; color: "#6d7486"; font.pixelSize: 11; font.bold: true; x: 8; anchors.bottom: parent.bottom; anchors.bottomMargin: 4 }
                        Rectangle {
                            visible: !r.header; anchors.fill: parent; radius: 6
                            color: index === list.currentIndex || rma.containsMouse ? "#25304d" : ((r.none ? "" === mp.current : r.id === mp.current) ? "#1f232c" : "transparent")
                            MouseArea { id: rma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pop.choose(r) }
                            Rectangle { visible: !r.none; x: 10; anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: mp.tierColor(r.privacy) }
                            Column {
                                x: 26; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 26 - 40
                                Text { text: r.none ? mp.noneLabel : (r.name || ""); color: "#e6e8ee"; font.pixelSize: 13; elide: Text.ElideRight; width: parent.width }
                                Text { visible: !r.none; text: (r.connectorName || "") + " · " + mp.tierName(r.privacy) + (r.name !== r.id ? " · " + r.id : ""); color: "#6d7486"; font.pixelSize: 11; elide: Text.ElideRight; width: parent.width }
                            }
                            Text {
                                visible: !r.none; anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                property bool on: mp.pinned.indexOf(r.id) >= 0
                                text: on ? "★" : "☆"; font.pixelSize: 17; color: on ? "#e6b450" : (sma.containsMouse ? "#e6e8ee" : "#6d7486")
                                MouseArea { id: sma; anchors.fill: parent; anchors.margins: -8; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: mp.pinToggled(r.id) }
                            }
                        }
                    }
                }
                Text { text: "★ pins a model to the top of every list.  ↑↓ Enter to pick."; color: "#6d7486"; font.pixelSize: 11; Layout.leftMargin: 4 }
            }
        }
    }

    Rectangle {
        visible: root.toastMsg !== ""
        anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottomMargin: 20
        radius: 6; color: root.cRaised; border.color: root.cBorder
        width: toastText.implicitWidth + 24; height: toastText.implicitHeight + 14
        Text { id: toastText; anchors.centerIn: parent; text: root.toastMsg; color: root.cText }
    }
}
