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
                } else { intentState = "error"; intentAnswer = u.error || u.state; finishIntent(false, {}, u.state === "cancelled" ? "cancelled" : "failed") }
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
        var req = { model: intentModel, minPrivacy: intentFloor(), messages: intentMessages() }
        if (intentName === "ai.chat") {
            if (typeof intentParams.temperature === "number") req.temperature = intentParams.temperature
            if (typeof intentParams.maxTokens === "number") req.max_tokens = intentParams.maxTokens
        }
        call("chat", [intentFrom, JSON.stringify(req)], function (r) {
            var v = parse(r)
            if (!v || !v.ok) { intentState = "error"; intentAnswer = v && v.error ? v.error : "AI Gateway core didn't answer"; return }
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
            if (intent !== "ai.ask" && intent !== "ai.chat") return
            root.startIntent(requestId, intent, params, requesterName)
        }
    }

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
                    ComboBox {
                        id: modelBox
                        Layout.preferredWidth: 420
                        model: root.modelList.map(function (m) { return m.name + "  ·  " + m.connectorName + "  ·  " + (root.tierNames[m.privacy] || m.privacy) })
                        currentIndex: { for (var i = 0; i < root.modelList.length; i++) if (root.modelList[i].id === root.chatModel) return i; return -1 }
                        onActivated: function (i) { root.chatModel = root.modelList[i].id }
                    }
                    Item { Layout.fillWidth: true }
                    Button { text: "New chat"; onClicked: { root.chatMessages = []; root.chatPartial = "" } }
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
                    TextArea {
                        id: chatInput
                        Layout.fillWidth: true; Layout.preferredHeight: 70; wrapMode: TextArea.Wrap
                        placeholderText: "Ask anything (Ctrl+Enter to send)"
                        Keys.onPressed: function (e) { if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && (e.modifiers & Qt.ControlModifier)) { root.sendChat(chatInput.text); chatInput.text = ""; e.accepted = true } }
                    }
                    ColumnLayout {
                        Button { text: root.chatJob ? "Stop" : "Send"; onClicked: { if (root.chatJob) root.call("cancel", [root.chatJob], null); else { root.sendChat(chatInput.text); chatInput.text = "" } } }
                    }
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
                                    Button { text: "Test"; onClicked: root.call("testConnector", [modelData.id], function () { root.toast("Testing " + modelData.name + "…") }) }
                                    Button { text: "Edit"; onClicked: { root.editId = modelData.id; root.editPreset = root.presetById(modelData.preset) } }
                                    Button { text: "Remove"; onClicked: root.call("removeConnector", [modelData.id], function () { root.refresh() }) }
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
                        Button { text: "← Back"; onClicked: root.editPreset = null }
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
                            delegate: Button { text: modelData; onClicked: Qt.openUrlExternally(edCol.p.links[modelData]) }
                        }
                    }
                    Text { text: "Base URL"; color: root.cSec; Layout.topMargin: 8 }
                    TextField { id: edUrl; Layout.fillWidth: true; text: edCol.p.baseUrl || ""; placeholderText: "https://…/v1" }
                    Text { text: edCol.p.needsKey ? "API key" : "API key (optional)"; color: root.cSec }
                    TextField { id: edKey; Layout.fillWidth: true; echoMode: TextInput.Password; placeholderText: root.editId ? "leave empty to keep the stored key" : "paste the key" }
                    RowLayout {
                        visible: edCol.p.id === "custom"
                        Text { text: "Privacy tier"; color: root.cSec }
                        ComboBox { id: edTier; model: root.tierOrder.map(function (t) { return root.tierNames[t] }) }
                    }
                    RowLayout {
                        Layout.topMargin: 8
                        Button {
                            text: root.editId ? "Save" : "Add and test"
                            onClicked: {
                                var c = { preset: edCol.p.id, baseUrl: edUrl.text.trim(), apiKey: edKey.text.trim() }
                                if (root.editId) c.id = root.editId
                                if (edCol.p.id === "custom") c.privacy = root.tierOrder[edTier.currentIndex]
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
                    ComboBox {
                        model: root.tierOrder.map(function (t) { return root.tierNames[t] })
                        currentIndex: Math.max(0, root.tierRank(root.settingsObj.minPrivacy || "standard"))
                        onActivated: function (i) { root.call("setSettings", [JSON.stringify({ minPrivacy: root.tierOrder[i] })], function () { root.refresh() }) }
                    }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cTert; font.pixelSize: 12; text: root.tierHelp[root.settingsObj.minPrivacy || "standard"] || "" }
                    Text { text: "Default model"; color: root.cSec; Layout.topMargin: 8 }
                    ComboBox {
                        Layout.preferredWidth: 420
                        model: ["(the most private available)"].concat(root.modelList.map(function (m) { return m.name + "  ·  " + m.connectorName }))
                        currentIndex: { for (var i = 0; i < root.modelList.length; i++) if (root.modelList[i].id === root.settingsObj.defaultModel) return i + 1; return 0 }
                        onActivated: function (i) { root.call("setSettings", [JSON.stringify({ defaultModel: i === 0 ? "" : root.modelList[i - 1].id })], function () { root.refresh() }) }
                    }
                    Text { text: "Local OpenAI endpoint"; color: root.cText; font.bold: true; Layout.topMargin: 14 }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec; font.pixelSize: 12
                           text: "Lets tools outside Basecamp (editors, agents, scripts) use these models as an OpenAI endpoint on this computer only (127.0.0.1), with the token below." }
                    CheckBox {
                        text: "Enabled"; checked: !!root.serverObj.enabled
                        onToggled: root.call("setSettings", [JSON.stringify({ server: { enabled: checked } })], function () { root.refresh() })
                    }
                    Text { visible: !!root.serverObj.enabled; color: root.serverObj.running ? root.cGood : root.cBad; textFormat: Text.PlainText
                           text: root.serverObj.running ? ("Base URL " + root.serverObj.url) : ("Not running: " + (root.serverObj.error || "starting…")) }
                    RowLayout {
                        visible: !!root.serverObj.enabled
                        TextField { id: tokField; Layout.preferredWidth: 360; readOnly: true; text: root.serverObj.token || "" }
                        Button { text: "Copy"; onClicked: { tokField.selectAll(); tokField.copy(); root.toast("Token copied") } }
                        Button { text: "New token"; onClicked: root.call("rotateServerToken", [], function () { root.refresh() }) }
                    }
                }
            }

            // ── an app asks (ai.ask / ai.chat) ──
            Flickable {
                anchors.fill: parent; anchors.margins: 18; contentHeight: inCol.implicitHeight; clip: true
                visible: root.page === "intent"
                ColumnLayout {
                    id: inCol; width: Math.min(parent.width, 760); spacing: 8
                    Text { text: root.intentFrom + " asks AI"; color: root.cText; font.pixelSize: 18; font.bold: true }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: root.cSec
                           text: "This is exactly what will be sent to the model you choose. Nothing is sent until you press Run." }
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
                        ComboBox {
                            Layout.preferredWidth: 440
                            property var opts: root.modelsAtLeast(root.intentFloor())
                            model: opts.map(function (m) { return m.name + "  ·  " + m.connectorName + "  ·  " + (root.tierNames[m.privacy] || m.privacy) })
                            currentIndex: { for (var i = 0; i < opts.length; i++) if (opts[i].id === root.intentModel) return i; return -1 }
                            onActivated: function (i) { root.intentModel = opts[i].id }
                            enabled: root.intentState === "ask"
                        }
                    }
                    Text { visible: root.modelsAtLeast(root.intentFloor()).length === 0; color: root.cBad; wrapMode: Text.Wrap; Layout.fillWidth: true
                           text: "No model you have set up is private enough for this request. Add a local runtime or a TEE provider in Connectors." }
                    RowLayout {
                        visible: root.intentState === "ask"
                        Button { text: "Run"; enabled: !!root.intentModel; onClicked: root.runIntent() }
                        Button { text: "Decline"; onClicked: root.declineIntent() }
                    }
                    Text { visible: root.intentState !== "ask" && root.intentState !== ""; text: root.intentState === "running" ? "Answering…" : root.intentState === "done" ? "Answer sent back to " + root.intentFrom : "Failed"; color: root.intentState === "error" ? root.cBad : root.cSec }
                    TextEdit { visible: root.intentAnswer !== ""; Layout.fillWidth: true; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; color: root.cText; font.pixelSize: 14; text: root.intentAnswer }
                    Button { visible: root.intentState === "running"; text: "Stop"; onClicked: root.declineIntent() }
                    Button { visible: root.intentState === "done" || root.intentState === "error"; text: "Close"; onClicked: { root.intentState = ""; root.page = "chat" } }
                }
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
