#include <QKeyEvent>
// Render harness: loads the REAL module/qml/Main.qml with a mock `logos` (answers from fixture.json,
// presets from the core's aigw_presets.hpp), renders each page offscreen, saves screenshots and counts
// QML errors. usage: harness <Main.qml> <fixture.json> <outdir>
#include <QGuiApplication>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickView>
#include <QImage>
#include <QTimer>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QJSValue>
#include <QVariantMap>
#include <cstdio>
#include "aigw_presets.hpp"

static int g_errors = 0;
static void handler(QtMsgType t, const QMessageLogContext&, const QString& m) {
    if ((t == QtWarningMsg || t == QtCriticalMsg) && (m.contains("TypeError") || m.contains("ReferenceError") || m.contains("is not a type")
        || m.contains("Cannot assign") || m.contains("Unable to assign") || m.contains("Error:"))) g_errors++;
    fprintf(stderr, "[%s] %s\n", t == QtWarningMsg ? "W" : t == QtDebugMsg ? "D" : "E", m.toUtf8().constData());
}
class MockLogos : public QObject {
    Q_OBJECT
public:
    QJsonObject fx;
    QStringList responses;
    QMap<QString, QString> lastArgs;
    Q_INVOKABLE QString callModule(const QString& mod, const QString& method, const QVariantList& args) {
        fprintf(stderr, "CALL %s.%s(%d)\n", mod.toUtf8().constData(), method.toUtf8().constData(), (int)args.size());
        if (mod != "ai_gateway_core") return "";
        if (!args.isEmpty()) lastArgs[method] = args.last().toString();
        if (method == "presets") return QString::fromUtf8(aigw::kPresets);
        if (fx.contains(method)) return QString::fromUtf8(QJsonDocument::fromVariant(fx[method].toVariant()).toJson(QJsonDocument::Compact));
        return "{\"ok\":true}";
    }
    Q_INVOKABLE void callModuleAsync(const QString& mod, const QString& method, const QVariantList& args, const QJSValue& cb, int) {
        // like Basecamp: the answer arrives JSON-quoted (a string holding the JSON text)
        const QString r = QString::fromUtf8(QJsonDocument(QJsonArray{callModule(mod, method, args)}).toJson(QJsonDocument::Compact)).mid(1).chopped(1);
        QJSValue c = cb;
        QTimer::singleShot(0, this, [c, r]() mutable { if (c.isCallable()) c.call({QJSValue(r)}); });
    }
    Q_INVOKABLE void respond(const QString& id, bool ok, const QVariant& data, const QString& err) {
        const QVariant v = data.canConvert<QJSValue>() ? data.value<QJSValue>().toVariant() : data;
        responses << QString("%1 %2 %3 %4").arg(id).arg(ok).arg(QString::fromUtf8(QJsonDocument::fromVariant(v).toJson(QJsonDocument::Compact))).arg(err);
        fprintf(stderr, "RESPOND %s\n", responses.last().toUtf8().constData());
    }
signals:
    void moduleEventReceived(const QString& module, const QString& event, const QVariant& data);
    void intentRequested(const QString& requestId, const QString& intent, const QVariantMap& params, const QString& requesterName);
};

int main(int argc, char** argv) {
    qInstallMessageHandler(handler);
    QGuiApplication app(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: harness Main.qml fixture.json outdir\n"); return 2; }
    QFile f(argv[2]);
    if (!f.open(QIODevice::ReadOnly)) { fprintf(stderr, "can't read %s\n", argv[2]); return 2; }
    MockLogos logos; logos.fx = QJsonDocument::fromJson(f.readAll()).object();
    QQuickView view; view.setResizeMode(QQuickView::SizeRootObjectToView); view.resize(1200, 800);
    view.engine()->rootContext()->setContextProperty("logos", &logos);
    view.setSource(QUrl::fromLocalFile(argv[1]));
    if (view.status() != QQuickView::Ready) { for (auto& e : view.errors()) fprintf(stderr, "LOAD %s\n", e.toString().toUtf8().constData()); return 1; }
    view.show();
    QQuickItem* root = view.rootObject();
    const QString out = argv[3];
    auto settle = [&](int ms) { QEventLoop l; QTimer::singleShot(ms, &l, &QEventLoop::quit); l.exec(); };
    settle(400);
    for (const char* p : {"chat", "connectors", "apps", "settings"}) {
        root->setProperty("page", p); settle(250);
        view.grabWindow().save(out + "/" + p + ".png");
    }
    // connector onboarding (Venice preset)
    root->setProperty("page", "connectors");
    QMetaObject::invokeMethod(root, "presetById", Q_RETURN_ARG(QVariant, *new QVariant), Q_ARG(QVariant, QVariant("venice")));
    QVariant pv; QMetaObject::invokeMethod(root, "presetById", Q_RETURN_ARG(QVariant, pv), Q_ARG(QVariant, QVariant("venice")));
    root->setProperty("editPreset", pv); settle(250);
    view.grabWindow().save(out + "/onboarding-venice.png");
    root->setProperty("editPreset", QVariant());
    // remote providers are hidden until the warning is acknowledged
    {
        root->setProperty("page", "connectors"); root->setProperty("editPreset", QVariant()); settle(200);
        QVariant lp, rp; QMetaObject::invokeMethod(root, "localPresets", Q_RETURN_ARG(QVariant, lp)); QMetaObject::invokeMethod(root, "remotePresets", Q_RETURN_ARG(QVariant, rp));
        const bool hidden = !root->property("showRemote").toBool() && lp.toList().size() == 4 && rp.toList().size() == 5;
        view.grabWindow().save(out + "/connectors-local.png");
        QMetaObject::invokeMethod(root, "revealRemote"); settle(150);
        const bool warned = root->property("remoteWarningOpen").toBool() && !root->property("showRemote").toBool();
        view.grabWindow().save(out + "/connectors-warning.png");
        QMetaObject::invokeMethod(root, "acknowledgeRemote"); settle(200);
        const bool shown = root->property("showRemote").toBool() && logos.lastArgs.value("setSettings").contains("remoteAcknowledged");
        view.grabWindow().save(out + "/connectors-remote.png");
        fprintf(stderr, "remote hidden by default: %s, warning first: %s, acknowledged + shown: %s\n", hidden ? "yes" : "NO", warned ? "yes" : "NO", shown ? "yes" : "NO");
        if (!hidden || !warned || !shown) g_errors++;
        root->setProperty("showRemote", false);
    }
    // a chat round trip (the mock's job answers "done")
    root->setProperty("page", "chat");
    QMetaObject::invokeMethod(root, "sendChat", Q_ARG(QVariant, QVariant("Summarize my zine")));
    settle(100);
    // events carry only the public watch id and the state; the view must read the answer with job() at once
    emit logos.moduleEventReceived("ai_gateway_core", "jobUpdate", QVariantMap{{"arg0", "w-1"}, {"arg1", "{\"id\":\"w-1\",\"state\":\"done\"}"}});
    settle(80);   // well before the 400 ms poll
    const QVariantList msgs = root->property("chatMessages").toList();
    const bool got = root->property("chatJob").toString().isEmpty() && !msgs.isEmpty() && msgs.last().toMap().value("content").toString().startsWith("Here is");
    fprintf(stderr, "event delta seen: %s\n", got ? "yes" : "NO");
    if (!got) g_errors++;
    settle(1600);
    view.grabWindow().save(out + "/chat-answer.png");
    // the model picker: pin, search, Enter picks
    QMetaObject::invokeMethod(root, "togglePin", Q_ARG(QVariant, QVariant("venice/venice-uncensored")));
    settle(100);
    const bool pinSaved = logos.lastArgs.value("setSettings").contains("venice/venice-uncensored");
    fprintf(stderr, "pin saved: %s\n", pinSaved ? "yes" : "NO");
    if (!pinSaved) g_errors++;
    QObject* picker = root->findChild<QObject*>("chatPicker");
    if (!picker) { fprintf(stderr, "no chatPicker\n"); g_errors++; }
    else {
        QMetaObject::invokeMethod(picker, "openList"); settle(250);
        view.grabWindow().save(out + "/picker-open.png");
        QObject* search = picker->findChild<QObject*>("pickerSearch");
        if (!search) { fprintf(stderr, "no pickerSearch\n"); g_errors++; }
        else {
            search->setProperty("text", "qwen"); settle(150);
            view.grabWindow().save(out + "/picker-search.png");
            QKeyEvent kp(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, "\r"); QCoreApplication::sendEvent(view.contentItem()->window(), &kp);
            settle(150);
            const QString cm = root->property("chatModel").toString();
            fprintf(stderr, "search+Enter picked: %s\n", qPrintable(cm));
            if (cm != "ollama/qwen3") g_errors++;
        }
    }
    // the chat input: Shift+Enter = new line, Enter = send
    QQuickItem* input = root->findChild<QQuickItem*>("chatInput");
    if (!input) { fprintf(stderr, "no chatInput\n"); g_errors++; }
    else {
        const int before = root->property("chatMessages").toList().size();
        input->forceActiveFocus(); input->setProperty("text", "line one"); input->setProperty("cursorPosition", 8);
        QKeyEvent se(QEvent::KeyPress, Qt::Key_Return, Qt::ShiftModifier, "\r"); QCoreApplication::sendEvent(&view, &se); settle(50);
        const bool newline = input->property("text").toString().contains("\n");
        QKeyEvent ee(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, "\r"); QCoreApplication::sendEvent(&view, &ee); settle(100);
        const int after = root->property("chatMessages").toList().size();
        const bool sent = after == before + 1 && input->property("text").toString().isEmpty();
        fprintf(stderr, "shift+enter newline: %s, enter sends: %s\n", newline ? "yes" : "NO", sent ? "yes" : "NO");
        if (!newline || !sent) g_errors++;
        settle(1600);
    }
    // an app asks: ai.ask with a privacy floor
    QVariantMap params{{"prompt", "Summarize this in three bullet points"}, {"content", "Gardens in the city: a zine about growing food on balconies..."}, {"minPrivacy", "no-retention"}};
    emit logos.intentRequested("req-1", "ai.ask", params, "wb_feedback_demo");
    settle(300);
    view.grabWindow().save(out + "/intent-ask.png");
    {   // the consent preview shows the user's own instructions (global + this app's), where the core puts them
        QVariant pm; QMetaObject::invokeMethod(root, "previewMessages", Q_RETURN_ARG(QVariant, pm));
        const QString pj = QString::fromUtf8(QJsonDocument::fromVariant(pm.value<QJSValue>().toVariant()).toJson(QJsonDocument::Compact));
        const bool shown = pj.contains("your instructions") && pj.contains("Answer in Czech.") && pj.contains("Use bullet points.");
        fprintf(stderr, "instructions in preview: %s\n", shown ? "yes" : qPrintable("NO " + pj));
        if (!shown) g_errors++;
    }
    root->setProperty("intentModel", "venice/venice-uncensored"); settle(150);
    view.grabWindow().save(out + "/intent-remote.png");
    root->setProperty("intentModel", "ollama/llama3.2"); settle(50);
    QMetaObject::invokeMethod(root, "runIntent");
    settle(1600);
    view.grabWindow().save(out + "/intent-done.png");
    const bool responded = !logos.responses.isEmpty() && logos.responses.last().startsWith("req-1 1 ") && logos.responses.last().contains("\"privacy\":\"local\"");
    // a chat session: allowed once, answered with a session id
    root->setProperty("intentState", ""); root->setProperty("page", "chat");
    QVariantMap sp{{"title", "Garden zine draft"}, {"purpose", "Chat about this document and suggest edits"}, {"system", "You help edit a zine."}, {"document", "# Gardens\nGrowing food on balconies."}};
    emit logos.intentRequested("req-2", "ai.session", sp, "fileverse_ui");
    settle(300);
    view.grabWindow().save(out + "/intent-session.png");
    QMetaObject::invokeMethod(root, "runIntent");
    settle(300);
    const bool sess = !logos.responses.isEmpty() && logos.responses.last().startsWith("req-2 1 ") && logos.responses.last().contains("ses-0123456789abcdef")
                      && logos.lastArgs.value("openSession").contains("Garden zine draft");
    fprintf(stderr, "session allowed: %s\n", sess ? "yes" : "NO");
    if (!sess) g_errors++;
    root->setProperty("page", "apps"); settle(250);
    view.grabWindow().save(out + "/apps.png");
    fprintf(stderr, "QML errors: %d, intent answered: %s\n", g_errors, responded ? "yes" : "no");
    return (g_errors == 0 && responded) ? 0 : 1;
}
#include "harness.moc"
