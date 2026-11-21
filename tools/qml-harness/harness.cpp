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
    Q_INVOKABLE QString callModule(const QString& mod, const QString& method, const QVariantList& args) {
        fprintf(stderr, "CALL %s.%s(%d)\n", mod.toUtf8().constData(), method.toUtf8().constData(), (int)args.size());
        if (mod != "ai_gateway_core") return "";
        if (method == "presets") return QString::fromUtf8(aigw::kPresets);
        if (fx.contains(method)) return QString::fromUtf8(QJsonDocument::fromVariant(fx[method].toVariant()).toJson(QJsonDocument::Compact));
        return "{\"ok\":true}";
    }
    Q_INVOKABLE void callModuleAsync(const QString& mod, const QString& method, const QVariantList& args, const QJSValue& cb, int) {
        const QString r = callModule(mod, method, args);
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
    // a chat round trip (the mock's job answers "done")
    root->setProperty("page", "chat");
    QMetaObject::invokeMethod(root, "sendChat", Q_ARG(QVariant, QVariant("Summarize my zine")));
    settle(100);
    emit logos.moduleEventReceived("ai_gateway_core", "jobUpdate", QVariantMap{{"arg0", "job-1"}, {"arg1", "{\"id\":\"job-1\",\"state\":\"running\",\"delta\":\"Here is\"}"}});
    settle(50);
    const QString partial = root->property("chatPartial").toString();
    fprintf(stderr, "event delta seen: %s\n", partial == "Here is" ? "yes" : qPrintable("NO (" + partial + ")"));
    if (partial != "Here is") g_errors++;
    settle(1600);
    view.grabWindow().save(out + "/chat-answer.png");
    // an app asks: ai.ask with a privacy floor
    QVariantMap params{{"prompt", "Summarize this in three bullet points"}, {"content", "Gardens in the city: a zine about growing food on balconies..."}, {"minPrivacy", "no-retention"}};
    emit logos.intentRequested("req-1", "ai.ask", params, "wb_feedback_demo");
    settle(300);
    view.grabWindow().save(out + "/intent-ask.png");
    QMetaObject::invokeMethod(root, "runIntent");
    settle(1600);
    view.grabWindow().save(out + "/intent-done.png");
    const bool responded = !logos.responses.isEmpty() && logos.responses.last().startsWith("req-1 1 ") && logos.responses.last().contains("\"privacy\":\"local\"");
    fprintf(stderr, "QML errors: %d, intent answered: %s\n", g_errors, responded ? "yes" : "no");
    return (g_errors == 0 && responded) ? 0 : 1;
}
#include "harness.moc"
