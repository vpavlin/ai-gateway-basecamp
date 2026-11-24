// AiGatewayCoreImpl - see ai_gateway_core_impl.h and docs/adr/0001-architecture.md.
//
// Threading: the module's methods may be called on the IPC thread. Everything that touches Qt
// network objects is posted to m_anchor, a QObject created on the module's own thread in
// onContextReady(), and runs there; shared state is under m_mtx. Methods answer at once: a chat is
// a job whose updates arrive as jobUpdate events (and from job()), never a blocking call.
#include "ai_gateway_core_impl.h"
#include "aigw_presets.hpp"
#include "aigw_server.hpp"

#include <QCoreApplication>
#include <QMetaObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QObject>
#include <QThread>
#include <QTimer>
#include <QRandomGenerator>
#include <QUrl>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <fstream>
#include <random>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

using json = nlohmann::json;

namespace {
const char* kVersion = "0.1.7";

long long nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}
// the OS CSPRNG (QRandomGenerator::system: getrandom / arc4random); ids, session capabilities, tokens
std::string randomHex(int bytes) {
    std::string out; char buf[3];
    for (int i = 0; i < bytes; i++) { std::snprintf(buf, sizeof buf, "%02x", (unsigned)(QRandomGenerator::system()->generate() & 0xff)); out += buf; }
    return out;
}
bool dirWritable(const std::string& d) {
    if (d.empty()) return false;
    std::string cmd;   // mkdir -p
    for (size_t i = 1; i <= d.size(); i++) if (i == d.size() || d[i] == '/') ::mkdir(d.substr(0, i).c_str(), 0700);
    return ::access(d.c_str(), W_OK) == 0;
}
json readJsonFile(const std::string& path, json fallback) {
    std::ifstream f(path);
    if (!f) return fallback;
    try { std::stringstream ss; ss << f.rdbuf(); json j = json::parse(ss.str()); return j; } catch (...) { return fallback; }
}
// written to a temp file, then renamed; private (0600): it holds API keys
// the temp file is created 0600 from the start (never readable under a lax umask), then renamed
void writePrivateFile(const std::string& path, const std::string& text) {
    const std::string tmp = path + ".tmp";
    ::unlink(tmp.c_str());
    const int fd = ::open(tmp.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_TRUNC, 0600);
    if (fd < 0) return;
    size_t off = 0;
    while (off < text.size()) { const ssize_t n = ::write(fd, text.data() + off, text.size() - off); if (n <= 0) break; off += (size_t)n; }
    ::fsync(fd);
    ::close(fd);
    if (off == text.size()) std::rename(tmp.c_str(), path.c_str()); else ::unlink(tmp.c_str());
}
const std::vector<std::string> kTiers = {"standard", "no-retention", "tee", "tee-e2ee", "local"};
int tierRank(const std::string& t) {
    for (size_t i = 0; i < kTiers.size(); i++) if (kTiers[i] == t) return (int)i;
    return -1;
}
std::string jstr(const json& o, const char* k, const std::string& def = "") {
    return o.is_object() && o.contains(k) && o[k].is_string() ? o[k].get<std::string>() : def;
}
// a dotted path into a JSON object ("model_spec.privacy")
json dig(const json& o, const std::string& path) {
    const json* cur = &o;
    size_t start = 0;
    while (start <= path.size()) {
        const size_t dot = path.find('.', start);
        const std::string k = path.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
        if (!cur->is_object() || !cur->contains(k)) return json();
        cur = &(*cur)[k];
        if (dot == std::string::npos) break;
        start = dot + 1;
    }
    return *cur;
}
bool startsWith(const std::string& s, const std::string& p) { return s.size() >= p.size() && s.compare(0, p.size(), p) == 0; }
std::string trimSlash(std::string s) { while (!s.empty() && s.back() == '/') s.pop_back(); return s; }
// only the last 4 characters, and only for keys long enough that 4 reveal little
std::string maskKey(const std::string& k) {
    if (k.empty()) return "";
    if (k.size() < 20) return "••••";
    return "••••" + k.substr(k.size() - 4);
}
std::string lowerStr(std::string v) { for (auto& ch : v) ch = (char)std::tolower((unsigned char)ch); return v; }
// a provider's token count: an integer in a sane range, anything else counts as 0 (AIGW-4)
long long safeCount(const json& o, const char* k) {
    if (!o.is_object() || !o.contains(k)) return 0;
    const json& v = o[k];
    if (v.is_number_unsigned()) return (long long)std::min<unsigned long long>(v.get<unsigned long long>(), 1000000000ULL);
    if (v.is_number_integer()) { const long long n = v.get<long long>(); return n < 0 ? 0 : std::min<long long>(n, 1000000000LL); }
    return 0;
}
json cleanUsage(const json& u) {
    if (!u.is_object()) return json();
    return json({{"prompt_tokens", safeCount(u, "prompt_tokens")}, {"completion_tokens", safeCount(u, "completion_tokens")}, {"total_tokens", safeCount(u, "total_tokens")}});
}
// is the URL's host this computer? (the "local" tier is only true there)
bool isLoopbackUrl(const std::string& url) {
    const QUrl u(QString::fromStdString(url));
    const std::string h = lowerStr(u.host().toStdString());
    return h == "localhost" || h == "::1" || h == "[::1]" || startsWith(h, "127.");
}
// scheme://host:port, lowercased: an API key is bound to the origin it was saved for (AIGW-1)
std::string originOf(const std::string& url) {
    const QUrl u(QString::fromStdString(url));
    return lowerStr(u.scheme().toStdString()) + "://" + lowerStr(u.host().toStdString()) + ":" + std::to_string(u.port(u.scheme() == "https" ? 443 : 80));
}
// what a model can do, where the provider says so; null = unknown (ask the provider and see)
json boolOrNull(const json& v) { return v.is_boolean() ? v : json(); }
json capsFor(const json& p, const json& m) {
    json caps = {{"jsonSchema", nullptr}, {"tools", nullptr}, {"contextTokens", nullptr}};
    if (p.contains("capabilities") && p["capabilities"].is_object())
        for (const char* k : {"jsonSchema", "tools"}) if (p["capabilities"].contains(k) && p["capabilities"][k].is_boolean()) caps[k] = p["capabilities"][k];
    if (p.contains("capabilityPaths") && p["capabilityPaths"].is_object()) {
        const json& cp = p["capabilityPaths"];
        for (const char* k : {"jsonSchema", "tools"}) if (cp.contains(k) && cp[k].is_string()) { const json v = boolOrNull(dig(m, cp[k].get<std::string>())); if (!v.is_null()) caps[k] = v; }
        if (cp.contains("contextTokens") && cp["contextTokens"].is_string()) { const json v = dig(m, cp["contextTokens"].get<std::string>()); if (v.is_number_integer() && v.get<long long>() > 0) caps["contextTokens"] = v; }
    }
    if (caps["contextTokens"].is_null())
        for (const char* path : {"context_length", "max_context_length", "context_window", "meta.n_ctx_train"}) {
            const json v = dig(m, path);
            if (v.is_number_integer() && v.get<long long>() > 0 && v.get<long long>() < 100000000) { caps["contextTokens"] = v; break; }
        }
    return caps;
}
// an OpenAI response_format the gateway passes on: {type: json_schema|json_object|text, ...}
bool validResponseFormat(const json& f) {
    if (!f.is_object() || !f.contains("type") || !f["type"].is_string()) return false;
    const std::string t = f["type"];
    if (t == "json_schema") return f.contains("json_schema") && f["json_schema"].is_object();
    return t == "json_object" || t == "text";
}
bool isEnabled(const json& c) { return !(c.is_object() && c.contains("enabled") && c["enabled"].is_boolean() && !c["enabled"].get<bool>()); }
// limits on what a provider may send back (AIGW-7)
constexpr qint64 kMaxModelsBody = 8LL << 20;      // a /models answer
constexpr size_t kMaxModels = 5000;
constexpr size_t kMaxModelIdLen = 256;
constexpr qint64 kMaxAnswerBody = 16LL << 20;     // a chat answer on the wire
constexpr size_t kMaxAnswerText = 8u << 20;       // the assembled answer
constexpr size_t kMaxSseLine = 1u << 20;          // one SSE line
constexpr int kMaxJobMs = 15 * 60 * 1000;         // a whole answer
constexpr size_t kMaxRequestBytes = 4u << 20;     // what an app may send in one chat (AIGW-13)
constexpr size_t kMaxTurnBytes = 1u << 20;        // one session turn
}  // namespace

struct AiGatewayCoreImpl::Job {
    std::string id, caller, kind, connector, model, upstreamModel, privacy, state = "running", text, error;
    json message = json();   // the assistant message (non-streamed: tool calls)
    json usage = json();
    bool usageAsked = false;
    bool sawEnd = false;       // [DONE] or a finish_reason: the stream really ended (AIGW-12)
    bool overLimit = false;    // aborted for a size or time limit
    std::string limitError;
    std::string watch;         // the public id in jobUpdate events; the job id itself stays with the caller (AIGW-3)   // stream_options.include_usage was added (dropped once if the provider refuses it)
    json result = json();    // test jobs: the connector's model list
    bool stream = true;
    std::string sseBuf;
    QNetworkReply* reply = nullptr;
    Sink sink;
    std::string pendingDelta;
    long long lastEmitMs = 0;
    long long startedMs = 0, finishedMs = 0;
    std::string sessionId;   // a session turn: on success the turn and the answer join the session's history
    json turn = json();
};
// A conversation the gateway keeps (ADR 0002): the app sends only what is new each turn.
// In memory only: a restart ends every session (the app opens a new one).
struct AiGatewayCoreImpl::Session {
    std::string id, caller, title, model, minPrivacy, system, document, jobId;
    json history = json::array();   // [{role, content}] user turns + answers, oldest first
    long long createdMs = 0, lastUsedMs = 0;
    size_t maxHistoryChars = 400000; // the app may lower it (historyChars in a turn)
    long long sentChars = 0;        // what this session has sent to models, in characters (shown to the user)
};
namespace {
constexpr size_t kSessionMaxMessages = 200;
constexpr size_t kSessionMaxChars = 400000;   // history kept for the model; the oldest turns go first
constexpr long long kSessionIdleMs = 12LL * 3600 * 1000;
constexpr size_t kMaxSessions = 50;
}

AiGatewayCoreImpl::AiGatewayCoreImpl() {
    try { m_presets = json::parse(aigw::kPresets); } catch (...) { m_presets = json::array(); }
}
AiGatewayCoreImpl::~AiGatewayCoreImpl() {
    delete m_server; m_server = nullptr;
    delete m_net; m_net = nullptr;
    delete m_anchor; m_anchor = nullptr;
}

// ── setup ────────────────────────────────────────────────────────────────────────
void AiGatewayCoreImpl::setupDataDir() {
    if (const char* ov = std::getenv("AIGW_CORE_DATA")) { m_dataDir = ov; dirWritable(m_dataDir); ::chmod(m_dataDir.c_str(), 0700); return; }
    const std::string inst = instancePersistencePath();
    if (!inst.empty() && dirWritable(inst)) { m_dataDir = inst; ::chmod(m_dataDir.c_str(), 0700); return; }
    const char* home = std::getenv("HOME");
    m_dataDir = std::string(home && *home ? home : "/tmp") + "/.ai-gateway";
    dirWritable(m_dataDir);
    ::chmod(m_dataDir.c_str(), 0700);
}
void AiGatewayCoreImpl::load() {
    // every field is checked: a damaged or edited file must not crash the core or weaken the floor (AIGW-14)
    const json rawConn = readJsonFile(m_dataDir + "/connectors.json", json::array());
    m_connectors = json::array();
    if (rawConn.is_array()) for (const auto& c : rawConn) {
        if (!c.is_object()) continue;
        const std::string id = jstr(c, "id"), preset = jstr(c, "preset"), url = trimSlash(jstr(c, "baseUrl"));
        if (id.empty() || id.size() > 64 || presetFor(preset).is_null()) continue;
        if (!startsWith(url, "http://") && !startsWith(url, "https://")) continue;
        json k = {{"id", id}, {"preset", preset}, {"name", jstr(c, "name", id).substr(0, 120)}, {"baseUrl", url}, {"apiKey", jstr(c, "apiKey")},
                  {"enabled", c.contains("enabled") && c["enabled"].is_boolean() ? c["enabled"].get<bool>() : true}};
        if (preset == "custom") {
            std::string t = jstr(c, "privacy", "standard");
            if (tierRank(t) < 0 || (t == "local" && !isLoopbackUrl(url))) t = "standard";
            k["privacy"] = t;
        }
        m_connectors.push_back(k);
    }
    m_settings = readJsonFile(m_dataDir + "/settings.json", json::object());
    if (!m_settings.is_object()) m_settings = json::object();
    if (tierRank(jstr(m_settings, "minPrivacy")) < 0) m_settings["minPrivacy"] = "standard";
    if (!m_settings.contains("defaultModel") || !m_settings["defaultModel"].is_string()) m_settings["defaultModel"] = "";
    if (!m_settings.contains("pinnedModels") || !m_settings["pinnedModels"].is_array()) m_settings["pinnedModels"] = json::array();
    if (!m_settings.contains("remoteAcknowledged") || !m_settings["remoteAcknowledged"].is_boolean()) m_settings["remoteAcknowledged"] = false;
    if (!m_settings.contains("server") || !m_settings["server"].is_object()) m_settings["server"] = json::object();
    json& sv = m_settings["server"];
    if (!sv.contains("enabled") || !sv["enabled"].is_boolean()) sv["enabled"] = false;
    if (!sv.contains("port") || !sv["port"].is_number_integer() || sv["port"].get<long long>() < 1024 || sv["port"].get<long long>() > 65535) sv["port"] = 11500;
    if (!sv.contains("token") || !sv["token"].is_string() || sv["token"].get<std::string>().size() < 16) sv["token"] = "aigw-" + randomHex(20);
    m_usage = readJsonFile(m_dataDir + "/usage.json", json::object());
    if (!m_usage.is_object()) m_usage = json::object();
    if (!m_usage.contains("apps") || !m_usage["apps"].is_object()) m_usage["apps"] = json::object();
    if (!m_usage.contains("connectors") || !m_usage["connectors"].is_object()) m_usage["connectors"] = json::object();
    saveSettings();
}
void AiGatewayCoreImpl::saveConnectors() { writePrivateFile(m_dataDir + "/connectors.json", m_connectors.dump(1)); }
void AiGatewayCoreImpl::saveSettings() { writePrivateFile(m_dataDir + "/settings.json", m_settings.dump(1)); }
void AiGatewayCoreImpl::saveUsage() { writePrivateFile(m_dataDir + "/usage.json", m_usage.dump(1)); }

void AiGatewayCoreImpl::onContextReady() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    setupDataDir();
    load();
    ensureNet();
    fprintf(stderr, "AIGW ready (data %s, %zu connectors)\n", m_dataDir.c_str(), m_connectors.size());
    // no calls to other modules here (Basecamp 0.3 rejects them); network work is deferred
    post([this] { applyServer(); refreshModels(); });
}
void AiGatewayCoreImpl::ensureNet() {
    if (m_anchor) return;
    m_anchor = new QObject();
    m_net = new QNetworkAccessManager(m_anchor);
}
void AiGatewayCoreImpl::post(std::function<void()> fn) {
    if (!m_anchor) ensureNet();
    if (QThread::currentThread() == m_anchor->thread()) { QTimer::singleShot(0, m_anchor, [fn] { fn(); }); return; }
    QMetaObject::invokeMethod(m_anchor, [fn] { fn(); }, Qt::QueuedConnection);
}
// job ids are capabilities too (job() returns the answer): 128 random bits (AIGW-3)
std::string AiGatewayCoreImpl::newId(const char* prefix) { ++m_seq; return std::string(prefix) + randomHex(16); }

// ── presets and connectors ─────────────────────────────────────────────────────────
std::string AiGatewayCoreImpl::about() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    return json({{"name", "ai_gateway_core"}, {"version", kVersion}, {"dataDir", m_dataDir}}).dump();
}
std::string AiGatewayCoreImpl::presets() { return m_presets.dump(); }
json AiGatewayCoreImpl::presetFor(const std::string& presetId) const {
    for (const auto& p : m_presets) if (jstr(p, "id") == presetId) return p;
    return json();
}
json AiGatewayCoreImpl::connectorById(const std::string& id) const {
    for (const auto& c : m_connectors) if (jstr(c, "id") == id) return c;
    return json();
}
std::string AiGatewayCoreImpl::connectors() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out = json::array();
    for (const auto& c : m_connectors) {
        json o = c;
        o["apiKey"] = maskKey(jstr(c, "apiKey"));
        o["hasKey"] = !jstr(c, "apiKey").empty();
        o["models"] = m_models.count(jstr(c, "id")) ? (int)m_models[jstr(c, "id")].size() : 0;
        o["error"] = m_modelErrors.count(jstr(c, "id")) ? m_modelErrors[jstr(c, "id")] : "";
        const json p = presetFor(jstr(c, "preset"));
        // the connector's usual tier (its models may differ: Venice per model, NEAR's proxied models)
        o["privacy"] = jstr(c, "preset") == "custom" ? jstr(c, "privacy", "standard") : jstr(p, "privacy", "standard");
        // "on this device" only for this computer: a local runtime on another host is labelled by its host
        o["remote"] = !isLoopbackUrl(jstr(c, "baseUrl"));
        if (o["remote"].get<bool>() && o["privacy"] == "local") {
            o["privacy"] = "standard";
            std::string nm = jstr(c, "name");
            const std::string tag = " (this computer)";
            if (nm.size() > tag.size() && nm.compare(nm.size() - tag.size(), tag.size(), tag) == 0)
                o["name"] = nm.substr(0, nm.size() - tag.size()) + " (" + QUrl(QString::fromStdString(jstr(c, "baseUrl"))).host().toStdString() + ")";
        }
        if (!jstr(p, "privacyNote").empty()) o["privacyNote"] = p["privacyNote"];
        if (jstr(c, "balance") != "") o["balance"] = c["balance"];
        out.push_back(o);
    }
    return out.dump();
}
std::string AiGatewayCoreImpl::saveConnector(std::string connectorJson) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json in;
    try { in = json::parse(connectorJson); } catch (...) { return json({{"ok", false}, {"error", "not JSON"}}).dump(); }
    if (!in.is_object()) return json({{"ok", false}, {"error", "expected an object"}}).dump();
    const std::string presetId = jstr(in, "preset", "custom");
    const json p = presetFor(presetId);
    if (p.is_null()) return json({{"ok", false}, {"error", "unknown preset " + presetId}}).dump();
    // validate before touching anything: a refused save must leave no connector behind
    std::string newUrl;
    if (in.contains("baseUrl") && in["baseUrl"].is_string()) {
        newUrl = trimSlash(in["baseUrl"].get<std::string>());
        if (!newUrl.empty() && !startsWith(newUrl, "http://") && !startsWith(newUrl, "https://")) return json({{"ok", false}, {"error", "the base URL must start with http:// or https://"}}).dump();
    }
    std::string id = jstr(in, "id");
    {
        const json existing = id.empty() ? json() : connectorById(id);
        const std::string url = !newUrl.empty() ? newUrl : (!existing.is_null() ? jstr(existing, "baseUrl") : jstr(p, "baseUrl"));
        if (url.empty()) return json({{"ok", false}, {"error", "a base URL is needed"}}).dump();
    }
    json* cur = nullptr;
    for (auto& c : m_connectors) if (jstr(c, "id") == id && !id.empty()) cur = &c;
    if (!cur) {
        // a new connector: its id is the preset's, made unique
        std::string base = presetId, cand = base; int n = 2;
        while (!connectorById(cand).is_null()) cand = base + "-" + std::to_string(n++);
        id = cand;
        m_connectors.push_back(json({{"id", id}, {"preset", presetId}, {"name", jstr(p, "name")}, {"baseUrl", jstr(p, "baseUrl")}, {"apiKey", ""}, {"enabled", true}}));
        cur = &m_connectors.back();
    }
    if (in.contains("name") && in["name"].is_string() && !in["name"].get<std::string>().empty()) (*cur)["name"] = in["name"].get<std::string>().substr(0, 120);
    const bool newKey = in.contains("apiKey") && in["apiKey"].is_string() && !in["apiKey"].get<std::string>().empty();
    bool keyCleared = false;
    // a stored key only ever goes to the origin it was saved for: moving the connector elsewhere
    // forgets it unless a key comes with the move (AIGW-1)
    if (!newUrl.empty() && originOf(newUrl) != originOf(jstr(*cur, "baseUrl")) && !newKey && !jstr(*cur, "apiKey").empty()) { (*cur)["apiKey"] = ""; keyCleared = true; }
    if (!newUrl.empty()) (*cur)["baseUrl"] = newUrl;
    if (newKey) (*cur)["apiKey"] = in["apiKey"];
    if (in.contains("enabled") && in["enabled"].is_boolean()) (*cur)["enabled"] = in["enabled"];
    // a custom connector's privacy tier is the user's to declare; a preset's is the preset's
    // "local" (on this device) is only true for this computer's own address (AIGW-6)
    if (presetId == "custom" && in.contains("privacy") && in["privacy"].is_string() && tierRank(in["privacy"]) >= 0) (*cur)["privacy"] = in["privacy"];
    if (presetId == "custom" && jstr(*cur, "privacy") == "local" && !isLoopbackUrl(jstr(*cur, "baseUrl"))) (*cur)["privacy"] = "standard";
    saveConnectors();
    post([this, id] { fetchModels(id, ""); });
    json res = {{"ok", true}, {"id", id}};
    if (keyCleared) res["keyCleared"] = true;
    return res.dump();
}
std::string AiGatewayCoreImpl::removeConnector(std::string id) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json kept = json::array(); bool found = false;
    for (const auto& c : m_connectors) { if (jstr(c, "id") == id) found = true; else kept.push_back(c); }
    if (!found) return json({{"ok", false}, {"error", "no such connector"}}).dump();
    m_connectors = kept;
    m_models.erase(id); m_modelErrors.erase(id);
    saveConnectors();
    modelsChanged(modelsJson().dump());
    return json({{"ok", true}}).dump();
}

// ── models ──────────────────────────────────────────────────────────────────────────
std::string AiGatewayCoreImpl::tierFor(const json& c, const json& m) const {
    const json p = presetFor(jstr(c, "preset"));
    std::string tier = jstr(p, "privacy", "standard");
    if (jstr(c, "preset") == "custom") tier = jstr(c, "privacy", "standard");
    const std::string mid = jstr(m, "id");
    if (p.contains("privacyField") && p["privacyField"].is_string()) {
        const json v = dig(m, p["privacyField"].get<std::string>());
        if (v.is_string() && p.contains("privacyMap") && p["privacyMap"].contains(v.get<std::string>())) tier = p["privacyMap"][v.get<std::string>()];
    }
    // names are the provider's; compare case-insensitively and fail safe (AIGW-8): a model the preset
    // doesn't list as TEE is standard, and known proxied names are standard whatever else matches
    const std::string lmid = lowerStr(mid);
    bool listed = false;
    if (p.contains("teePrefixes") && p["teePrefixes"].is_array() && (tier == "tee" || tier == "tee-e2ee")) {
        for (const auto& pre : p["teePrefixes"]) if (pre.is_string() && startsWith(lmid, lowerStr(pre.get<std::string>()))) listed = true;
        if (!listed) tier = "standard";
    }
    if (!listed && p.contains("standardPrefixes") && p["standardPrefixes"].is_array())
        for (const auto& pre : p["standardPrefixes"]) if (pre.is_string() && startsWith(lmid, lowerStr(pre.get<std::string>()))) tier = "standard";
    // "on this device" only for this computer (a preset pointed at another host is not local)
    if (tier == "local" && !isLoopbackUrl(jstr(c, "baseUrl"))) tier = "standard";
    return tier;
}
json AiGatewayCoreImpl::modelsJson() {
    json out = json::array();
    for (const auto& c : m_connectors) {
        if (!isEnabled(c)) continue;
        auto it = m_models.find(jstr(c, "id"));
        if (it == m_models.end()) continue;
        for (const auto& m : it->second) out.push_back(m);
    }
    return out;
}
std::string AiGatewayCoreImpl::models() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    return modelsJson().dump();
}
std::string AiGatewayCoreImpl::refreshModels() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    std::vector<std::string> ids;
    for (const auto& c : m_connectors) if (isEnabled(c)) ids.push_back(jstr(c, "id"));
    post([this, ids] { for (const auto& id : ids) fetchModels(id, ""); });
    return json({{"ok", true}, {"connectors", ids.size()}}).dump();
}
std::string AiGatewayCoreImpl::testConnector(std::string id) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    if (connectorById(id).is_null()) return json({{"ok", false}, {"error", "no such connector"}}).dump();
    auto j = std::make_shared<Job>();
    j->id = newId("test-"); j->watch = "w-" + randomHex(8); j->kind = "test"; j->connector = id; j->caller = "ai_gateway"; j->startedMs = nowMs();
    m_jobs[j->id] = j;
    const std::string jid = j->id;
    post([this, id, jid] { fetchModels(id, jid); });
    return json({{"ok", true}, {"jobId", jid}, {"watchId", j->watch}}).dump();
}
// GET {baseUrl}/models; runs on the module thread
void AiGatewayCoreImpl::fetchModels(const std::string& connectorId, const std::string& jobId) {
    json c;
    { std::lock_guard<std::recursive_mutex> lk(m_mtx); c = connectorById(connectorId); }
    if (c.is_null()) return;
    QNetworkRequest rq(QUrl(QString::fromStdString(jstr(c, "baseUrl") + "/models")));
    rq.setTransferTimeout(20000);
    if (!jstr(c, "apiKey").empty()) rq.setRawHeader("Authorization", QByteArray::fromStdString("Bearer " + jstr(c, "apiKey")));
    rq.setRawHeader("Accept", "application/json");
    QNetworkReply* r = m_net->get(rq);
    auto tooBig = std::make_shared<bool>(false);
    QObject::connect(r, &QNetworkReply::downloadProgress, m_anchor, [r, tooBig](qint64 got, qint64) { if (got > kMaxModelsBody && !*tooBig) { *tooBig = true; r->abort(); } });
    QObject::connect(r, &QNetworkReply::finished, m_anchor, [this, r, connectorId, jobId, tooBig] {
        r->deleteLater();
        const int status = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const std::string body = *tooBig ? std::string() : r->readAll().toStdString();
        std::lock_guard<std::recursive_mutex> lk(m_mtx);
        json c = connectorById(connectorId);
        if (c.is_null()) return;
        std::string err;
        json list = json::array();
        if (*tooBig) err = "the model list is too large";
        else if (r->error() != QNetworkReply::NoError && status == 0) err = "can't reach " + jstr(c, "baseUrl") + " (" + r->errorString().toStdString() + ")";
        else if (status == 401 || status == 403) err = "the key was refused (HTTP " + std::to_string(status) + ")";
        else if (status >= 400) err = "HTTP " + std::to_string(status);
        else {
            try {
                const json j = json::parse(body);
                const json& data = j.is_object() && j.contains("data") ? j["data"] : (j.is_object() && j.contains("models") ? j["models"] : j);
                const json p = presetFor(jstr(c, "preset"));
                if (data.is_array()) for (const auto& m : data) {
                    if (!m.is_object() || list.size() >= kMaxModels) continue;
                    const std::string mid = jstr(m, "id", jstr(m, "name"));
                    if (mid.empty() || mid.size() > kMaxModelIdLen) continue;
                    bool skip = false;
                    if (p.contains("skipPrefixes")) for (const auto& pre : p["skipPrefixes"]) if (pre.is_string() && startsWith(mid, pre.get<std::string>())) skip = true;
                    // only text models: drop image / audio / embedding ones where the provider says so
                    const std::string type = jstr(m, "type");
                    if (!type.empty() && type != "text" && type != "chat" && type != "llm") skip = true;
                    if (skip) continue;
                    std::string name = mid;
                    if (p.contains("nameField") && p["nameField"].is_string()) name = jstr(m, p["nameField"].get<std::string>().c_str(), mid);
                    if (name.empty() || name.size() > kMaxModelIdLen) name = mid;
                    const std::string tier = tierFor(c, m);
                    json entry = {{"id", connectorId + "/" + mid}, {"connector", connectorId}, {"connectorName", jstr(c, "name")}, {"model", mid},
                                  {"name", name}, {"privacy", tier}, {"privacyRank", tierRank(tier)}, {"verified", tier == "local"}};
                    const json caps = capsFor(p, m);
                    for (auto it = caps.begin(); it != caps.end(); ++it) entry[it.key()] = it.value();
                    list.push_back(entry);
                }
            } catch (...) { err = "the answer wasn't a model list"; }
        }
        if (err.empty()) { m_models[connectorId] = list; m_modelErrors.erase(connectorId); }
        else { m_modelErrors[connectorId] = err; }
        // balance headers (Venice): what's left, without an admin key
        const json p = presetFor(jstr(c, "preset"));
        if (p.contains("balanceHeaders"))
            for (auto& cc : m_connectors) if (jstr(cc, "id") == connectorId) {
                json bal = json::object();
                for (const auto& h : p["balanceHeaders"]) if (h.is_string() && r->hasRawHeader(QByteArray::fromStdString(h.get<std::string>())))
                    bal[h.get<std::string>()] = r->rawHeader(QByteArray::fromStdString(h.get<std::string>())).toStdString();
                if (!bal.empty()) { cc["balance"] = bal; saveConnectors(); }
            }
        if (!jobId.empty()) {
            auto it = m_jobs.find(jobId);
            if (it != m_jobs.end()) {
                auto j = it->second;
                j->result = json({{"models", list.size()}, {"error", err}});
                finishJob(j, err.empty() ? "done" : "error", err);
            }
        }
        modelsChanged(modelsJson().dump());
    });
}

// ── chat ────────────────────────────────────────────────────────────────────────────
std::string AiGatewayCoreImpl::chat(std::string caller, std::string requestJson) {
    json req;
    try { req = json::parse(requestJson); } catch (...) { return json({{"ok", false}, {"error", "the request isn't JSON"}}).dump(); }
    return startChat(caller, req, nullptr).dump();
}
json AiGatewayCoreImpl::startChat(const std::string& caller0, const json& req0, Sink sink) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    if (!req0.is_object()) return json({{"ok", false}, {"error", "the request must be an object"}});
    json req = req0;
    if (!req.contains("messages") || !req["messages"].is_array() || req["messages"].empty()) return json({{"ok", false}, {"error", "messages are needed"}});
    if (req.dump().size() > kMaxRequestBytes) return json({{"ok", false}, {"error", "the request is too large (4 MB at most)"}});
    const std::string caller = caller0.empty() ? "unknown" : caller0.substr(0, 64);
    // the privacy floor: the caller's, never below the user's setting
    std::string minPrivacy = jstr(m_settings, "minPrivacy", "standard");
    const std::string asked = jstr(req, "minPrivacy");
    if (!asked.empty()) {
        if (tierRank(asked) < 0) return json({{"ok", false}, {"error", "minPrivacy must be one of standard, no-retention, tee, tee-e2ee, local"}});
        if (tierRank(asked) > tierRank(minPrivacy)) minPrivacy = asked;
    }
    // route: "connector/model", a bare model name, or the default
    const json all = modelsJson();
    std::string want = jstr(req, "model");
    if (want.empty() || want == "default") want = jstr(m_settings, "defaultModel");
    const std::string conn = jstr(req, "connector");
    json pick;
    auto ok = [&](const json& m) { return m.value("privacyRank", -1) >= tierRank(minPrivacy) && (conn.empty() || jstr(m, "connector") == conn); };
    if (!want.empty()) {
        for (const auto& m : all) if (jstr(m, "id") == want && ok(m)) { pick = m; break; }
        if (pick.is_null()) for (const auto& m : all) if (jstr(m, "model") == want && ok(m)) { pick = m; break; }
        if (pick.is_null()) {
            bool exists = false;
            for (const auto& m : all) if (jstr(m, "id") == want || jstr(m, "model") == want) exists = true;
            if (exists) return json({{"ok", false}, {"error", "model " + want + " is less private than required (" + minPrivacy + ")"}});
        }
    }
    if (pick.is_null()) {
        // no model named (or it isn't available): the most private one available
        for (const auto& m : all) if (ok(m) && (pick.is_null() || m.value("privacyRank", -1) > pick.value("privacyRank", -1))) pick = m;
    }
    if (pick.is_null()) return json({{"ok", false}, {"error", all.empty() ? "no AI connector is set up yet - add one in AI Gateway" : "no available model meets the required privacy (" + minPrivacy + ")"}});
    // structured output: responseFormat (or OpenAI's response_format) goes to the provider as response_format
    if (req.contains("responseFormat")) {
        if (!validResponseFormat(req["responseFormat"])) return json({{"ok", false}, {"error", "responseFormat must be {type: json_schema, json_schema: {...}} or {type: json_object|text}"}});
        if (!req.contains("response_format")) req["response_format"] = req["responseFormat"];
        req.erase("responseFormat");
    }
    if (req.contains("response_format") && validResponseFormat(req["response_format"]) && req["response_format"]["type"] == "json_schema" && pick.value("jsonSchema", json()).is_boolean() && !pick["jsonSchema"].get<bool>())
        return json({{"ok", false}, {"error", "model " + jstr(pick, "id") + " doesn't support json_schema output (models() lists jsonSchema per model)"}, {"code", "unsupported"}});
    if (req.contains("tools") && req["tools"].is_array() && !req["tools"].empty() && pick.value("tools", json()).is_boolean() && !pick["tools"].get<bool>())
        return json({{"ok", false}, {"error", "model " + jstr(pick, "id") + " doesn't support tool calls (models() lists tools per model)"}, {"code", "unsupported"}});
    const json c = connectorById(jstr(pick, "connector"));
    auto j = std::make_shared<Job>();
    j->id = newId("job-"); j->watch = "w-" + randomHex(8); j->kind = "chat"; j->caller = caller; j->connector = jstr(pick, "connector"); j->model = jstr(pick, "id");
    j->upstreamModel = jstr(pick, "model"); j->privacy = jstr(pick, "privacy"); j->startedMs = nowMs(); j->sink = sink;
    // what goes upstream: the OpenAI request, our own fields removed; streamed unless it uses tools
    json body = req;
    for (const char* k : {"connector", "minPrivacy", "caller"}) body.erase(k);
    body["model"] = j->upstreamModel;
    j->stream = !(body.contains("tools") && body["tools"].is_array() && !body["tools"].empty());
    body["stream"] = j->stream;
    // streams report token usage only when asked (OpenAI, Ollama, ...): ask, unless the caller already set it
    if (j->stream && !(body.contains("stream_options") && body["stream_options"].is_object() && body["stream_options"].contains("include_usage"))) {
        if (!body.contains("stream_options") || !body["stream_options"].is_object()) body["stream_options"] = json::object();
        body["stream_options"]["include_usage"] = true;
        j->usageAsked = true;
    }
    m_jobs[j->id] = j;
    // usage: count the request now (tokens come with the answer)
    json& a = m_usage["apps"][caller];
    if (!a.is_object()) a = json::object();
    a["requests"] = safeCount(a, "requests") + 1; a["lastAt"] = nowMs();
    // what the app sent, in characters (the user sees it per app in Apps & usage)
    a["sentChars"] = safeCount(a, "sentChars") + (long long)(body.contains("messages") ? body["messages"].dump().size() : 0);
    json& u = m_usage["connectors"][j->connector];
    if (!u.is_object()) u = json::object();
    u["requests"] = safeCount(u, "requests") + 1; u["lastAt"] = nowMs();
    saveUsage();
    post([this, j, body] { runChat(j, body); });
    // old jobs go after an hour
    for (auto it = m_jobs.begin(); it != m_jobs.end();) {
        if (it->second->state != "running" && nowMs() - it->second->finishedMs > 3600000) it = m_jobs.erase(it); else ++it;
    }
    return json({{"ok", true}, {"jobId", j->id}, {"watchId", j->watch}, {"model", j->model}, {"connector", j->connector}, {"connectorName", jstr(c, "name")}, {"privacy", j->privacy}});
}
void AiGatewayCoreImpl::runChat(std::shared_ptr<Job> j, json body) {
    json c;
    { std::lock_guard<std::recursive_mutex> lk(m_mtx); c = connectorById(j->connector); if (j->state != "running") return; }
    if (c.is_null()) { finishJob(j, "error", "the connector was removed"); return; }
    QNetworkRequest rq(QUrl(QString::fromStdString(jstr(c, "baseUrl") + "/chat/completions")));
    rq.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    if (!jstr(c, "apiKey").empty()) rq.setRawHeader("Authorization", QByteArray::fromStdString("Bearer " + jstr(c, "apiKey")));
    rq.setRawHeader("Accept", j->stream ? "text/event-stream" : "application/json");
    rq.setTransferTimeout(120000);   // no byte for 2 minutes: give up
    QNetworkReply* r = m_net->post(rq, QByteArray::fromStdString(body.dump()));
    { std::lock_guard<std::recursive_mutex> lk(m_mtx); j->reply = r; }
    // limits (AIGW-7): bytes on the wire, and the whole answer's time
    auto stopFor = [this, j, r](const std::string& why) {
        { std::lock_guard<std::recursive_mutex> lk(m_mtx); if (j->overLimit || j->reply != r) return; j->overLimit = true; j->limitError = why; }
        r->abort();
    };
    QObject::connect(r, &QNetworkReply::downloadProgress, m_anchor, [stopFor](qint64 got, qint64) { if (got > kMaxAnswerBody) stopFor("the answer is too large"); });
    QTimer::singleShot(kMaxJobMs, r, [stopFor] { stopFor("the answer took longer than 15 minutes"); });
    QObject::connect(r, &QNetworkReply::readyRead, m_anchor, [this, j, r] {
        const int status = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (!j->stream || status >= 400) return;   // read whole at the end
        onChunk(j, r->readAll().toStdString());
    });
    QObject::connect(r, &QNetworkReply::finished, m_anchor, [this, j, r, body] {
        r->deleteLater();
        const int status = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const std::string rest = r->readAll().toStdString();
        { std::lock_guard<std::recursive_mutex> lk(m_mtx); j->reply = nullptr; if (j->state != "running") return; }
        if (r->error() == QNetworkReply::OperationCanceledError) {
            std::string why; { std::lock_guard<std::recursive_mutex> lk(m_mtx); if (j->overLimit) why = j->limitError; }
            if (!why.empty()) finishJob(j, "error", why); else finishJob(j, "cancelled", "");
            return;
        }
        { std::lock_guard<std::recursive_mutex> lk(m_mtx); if (j->overLimit) { const std::string why = j->limitError; finishJob(j, "error", why); return; } }
        // an older server that refuses stream_options: try once more without it (usage is then unknown)
        if ((status == 400 || status == 422) && j->usageAsked && j->text.empty()) {
            j->usageAsked = false;
            json again = body;
            if (again.contains("stream_options") && again["stream_options"].is_object()) {
                again["stream_options"].erase("include_usage");
                if (again["stream_options"].empty()) again.erase("stream_options");
            }
            fprintf(stderr, "[aigw] %s refused stream_options (HTTP %d); retrying without\n", j->connector.c_str(), status);
            runChat(j, again);
            return;
        }
        if (status >= 400 || (r->error() != QNetworkReply::NoError && status == 0)) {
            std::string msg;
            try { const json e = json::parse(rest); if (e.contains("error")) msg = e["error"].is_object() ? jstr(e["error"], "message") : (e["error"].is_string() ? e["error"].get<std::string>() : ""); } catch (...) {}
            if (msg.empty()) msg = status ? "HTTP " + std::to_string(status) : r->errorString().toStdString();
            finishJob(j, "error", msg);
            return;
        }
        // a provider that answered with plain JSON (no stream, or tools)
        const std::string ctype = r->header(QNetworkRequest::ContentTypeHeader).toString().toStdString();
        if (!j->stream || ctype.find("application/json") != std::string::npos) {
            try {
                const json resp = json::parse(j->sseBuf + rest);
                std::lock_guard<std::recursive_mutex> lk(m_mtx);
                if (resp.contains("choices") && resp["choices"].is_array() && !resp["choices"].empty()) {
                    const json& msg = resp["choices"][0].contains("message") ? resp["choices"][0]["message"] : json();
                    j->message = msg;
                    if (msg.contains("content") && msg["content"].is_string()) j->text = msg["content"].get<std::string>();
                }
                if (resp.contains("usage")) j->usage = cleanUsage(resp["usage"]);
                if (j->text.size() > kMaxAnswerText) { j->text.resize(kMaxAnswerText); finishJob(j, "error", "the answer is too large"); return; }
            } catch (...) { finishJob(j, "error", "the provider's answer wasn't valid JSON"); return; }
        } else {
            if (!rest.empty()) onChunk(j, rest);
            // a stream cut before its end is not a complete answer (AIGW-12)
            bool ended = false, over = false; std::string why;
            { std::lock_guard<std::recursive_mutex> lk(m_mtx); ended = j->sawEnd; over = j->overLimit; why = j->limitError; }
            if (over) { finishJob(j, "error", why); return; }
            if (!ended || r->error() != QNetworkReply::NoError) { finishJob(j, "error", "the answer was cut off (" + (r->error() != QNetworkReply::NoError ? r->errorString().toStdString() : std::string("no end of stream")) + ")"); return; }
        }
        finishJob(j, "done", "");
    });
}
// SSE: "data: {...}\n\n" lines; "data: [DONE]" ends it
void AiGatewayCoreImpl::onChunk(std::shared_ptr<Job> j, const std::string& data) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    if (j->overLimit || j->state != "running") return;
    j->sseBuf += data;
    std::string delta;
    size_t pos = 0, nl;
    // walk the lines with an offset and drop the consumed part once (not erase per line: O(n^2))
    while ((nl = j->sseBuf.find('\n', pos)) != std::string::npos) {
        std::string line = j->sseBuf.substr(pos, nl - pos);
        pos = nl + 1;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!startsWith(line, "data:")) continue;
        std::string payload = line.substr(5);
        while (!payload.empty() && payload[0] == ' ') payload.erase(0, 1);
        if (payload == "[DONE]") { j->sawEnd = true; continue; }
        if (payload.empty()) continue;
        try {
            const json ev = json::parse(payload);
            if (ev.contains("choices") && ev["choices"].is_array() && !ev["choices"].empty()) {
                const json& ch = ev["choices"][0];
                if (ch.is_object() && ch.contains("delta") && ch["delta"].is_object() && ch["delta"].contains("content") && ch["delta"]["content"].is_string())
                    delta += ch["delta"]["content"].get<std::string>();
                if (ch.is_object() && ch.contains("finish_reason") && ch["finish_reason"].is_string()) j->sawEnd = true;
            }
            if (ev.contains("usage") && ev["usage"].is_object()) j->usage = cleanUsage(ev["usage"]);
        } catch (...) { /* a partial or foreign line */ }
    }
    j->sseBuf.erase(0, pos);
    if (j->sseBuf.size() > kMaxSseLine) { j->overLimit = true; j->limitError = "the provider sent an over-long line"; if (j->reply) j->reply->abort(); return; }
    if (delta.empty()) return;
    j->text += delta;
    j->pendingDelta += delta;
    if (j->text.size() > kMaxAnswerText) { j->overLimit = true; j->limitError = "the answer is too large"; if (j->reply) j->reply->abort(); return; }
    // updates at most every 100 ms: a token per event would flood the IPC
    if (nowMs() - j->lastEmitMs >= 100) {
        json up = {{"id", j->id}, {"state", "running"}, {"delta", j->pendingDelta}};
        j->pendingDelta.clear(); j->lastEmitMs = nowMs();
        notify(j, up);
    }
}
void AiGatewayCoreImpl::finishJob(std::shared_ptr<Job> j, const std::string& state, const std::string& error) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    if (j->state != "running") return;
    j->state = state; j->error = error; j->finishedMs = nowMs();
    if (j->kind == "chat" && state == "done" && j->usage.is_object()) {
        const long long pt = safeCount(j->usage, "prompt_tokens"), ct = safeCount(j->usage, "completion_tokens");
        for (json* u : {&m_usage["apps"][j->caller], &m_usage["connectors"][j->connector]}) {
            if (!u->is_object()) *u = json::object();
            (*u)["promptTokens"] = safeCount(*u, "promptTokens") + pt;
            (*u)["completionTokens"] = safeCount(*u, "completionTokens") + ct;
        }
        saveUsage();
    }
    if (!j->sessionId.empty()) {
        auto it = m_sessions.find(j->sessionId);
        if (it != m_sessions.end()) {
            auto& se = *it->second;
            if (se.jobId == j->id) se.jobId.clear();
            if (state == "done") {
                for (const auto& m : j->turn) se.history.push_back(m);
                json ans = j->message.is_object() ? j->message : json({{"role", "assistant"}, {"content", j->text}});
                se.history.push_back(ans);
                auto chars = [](const json& h) { size_t n = 0; for (const auto& m : h) n += m.dump().size(); return n; };
                while (!se.history.empty() && (se.history.size() > kSessionMaxMessages || chars(se.history) > std::min(kSessionMaxChars, se.maxHistoryChars))) se.history.erase(se.history.begin());
            }
        }
    }
    json up = {{"id", j->id}, {"state", state}, {"text", j->text}};
    if (!j->sessionId.empty()) up["sessionId"] = j->sessionId;
    if (!j->pendingDelta.empty()) { up["delta"] = j->pendingDelta; j->pendingDelta.clear(); }
    if (!error.empty()) up["error"] = error;
    if (!j->usage.is_null()) up["usage"] = j->usage;
    if (!j->message.is_null()) up["message"] = j->message;
    if (!j->result.is_null()) up["result"] = j->result;
    up["model"] = j->model; up["connector"] = j->connector; up["privacy"] = j->privacy;
    notify(j, up);
}
void AiGatewayCoreImpl::notify(std::shared_ptr<Job> j, json update) {
    if (j->sink) { try { j->sink(update); } catch (...) {} }
    // the event is visible to every module: only the public watch id and the state, never the text,
    // the job id or a session id (AIGW-3). The app that started the job reads it with job(jobId).
    json pub = {{"id", j->watch}, {"state", update.value("state", "running")}};
    jobUpdate(j->watch, pub.dump());
}
// ── sessions (ADR 0002) ───────────────────────────────────────────────────────────
void AiGatewayCoreImpl::expireSessions() {
    for (auto it = m_sessions.begin(); it != m_sessions.end();) {
        if (it->second->jobId.empty() && nowMs() - it->second->lastUsedMs > kSessionIdleMs) it = m_sessions.erase(it); else ++it;
    }
}
std::string AiGatewayCoreImpl::openSession(std::string caller, std::string sessionJson) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json in;
    try { in = json::parse(sessionJson); } catch (...) { return json({{"ok", false}, {"error", "the session isn't JSON"}}).dump(); }
    if (!in.is_object()) return json({{"ok", false}, {"error", "the session must be an object"}}).dump();
    expireSessions();
    if (m_sessions.size() >= kMaxSessions) return json({{"ok", false}, {"error", "too many open sessions - close some in AI Gateway"}}).dump();
    std::string minPrivacy = jstr(m_settings, "minPrivacy", "standard");
    const std::string asked = jstr(in, "minPrivacy");
    if (!asked.empty()) {
        if (tierRank(asked) < 0) return json({{"ok", false}, {"error", "minPrivacy must be one of standard, no-retention, tee, tee-e2ee, local"}}).dump();
        if (tierRank(asked) > tierRank(minPrivacy)) minPrivacy = asked;
    }
    // pick the model now, with the same rules as chat(), so the session reports what it will use
    std::string want = jstr(in, "model");
    if (want.empty() || want == "default") want = jstr(m_settings, "defaultModel");
    json pick;
    const json all = modelsJson();
    for (const auto& m : all) if (m.value("privacyRank", -1) >= tierRank(minPrivacy) && !want.empty() && (jstr(m, "id") == want || jstr(m, "model") == want)) { pick = m; break; }
    if (pick.is_null()) for (const auto& m : all) if (m.value("privacyRank", -1) >= tierRank(minPrivacy) && (pick.is_null() || m.value("privacyRank", -1) > pick.value("privacyRank", -1))) pick = m;
    if (pick.is_null()) return json({{"ok", false}, {"error", all.empty() ? "no AI connector is set up yet - add one in AI Gateway" : "no available model meets the required privacy (" + minPrivacy + ")"}}).dump();
    auto se = std::make_shared<Session>();
    se->id = "ses-" + randomHex(16);   // also the capability: only the app that got the answer knows it
    se->caller = caller.empty() ? "unknown" : caller.substr(0, 64);
    se->title = jstr(in, "title").substr(0, 200);
    se->model = jstr(pick, "id"); se->minPrivacy = minPrivacy;
    se->system = jstr(in, "system"); se->document = jstr(in, "document");
    if (se->document.size() > 1000000 || se->system.size() > 100000) return json({{"ok", false}, {"error", "the document (1 MB) or system prompt (100 KB) is too long"}}).dump();
    se->createdMs = se->lastUsedMs = nowMs();
    m_sessions[se->id] = se;
    return json({{"ok", true}, {"sessionId", se->id}, {"model", se->model}, {"privacy", jstr(pick, "privacy")}, {"connectorName", jstr(connectorById(jstr(pick, "connector")), "name")}}).dump();
}
std::string AiGatewayCoreImpl::sessionChat(std::string sessionId, std::string turnJson) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    expireSessions();
    auto it = m_sessions.find(sessionId);
    if (it == m_sessions.end()) return json({{"ok", false}, {"error", "no such session (it was closed, expired, or AI Gateway restarted)"}, {"code", "no_session"}}).dump();
    auto se = it->second;
    if (!se->jobId.empty()) return json({{"ok", false}, {"error", "the session is still answering"}, {"code", "busy"}}).dump();
    json in;
    try { in = json::parse(turnJson); } catch (...) { return json({{"ok", false}, {"error", "the turn isn't JSON"}}).dump(); }
    if (!in.is_object()) return json({{"ok", false}, {"error", "the turn must be an object"}}).dump();
    if (turnJson.size() > kMaxTurnBytes + 1000000) return json({{"ok", false}, {"error", "the turn is too large"}}).dump();
    json turn = json::array();
    if (in.contains("messages")) {
        if (!in["messages"].is_array()) return json({{"ok", false}, {"error", "messages must be a list"}}).dump();
        for (const auto& m : in["messages"]) {
            if (!m.is_object() || jstr(m, "role").empty()) return json({{"ok", false}, {"error", "every message needs a role"}}).dump();
            if (jstr(m, "role") == "system") return json({{"ok", false}, {"error", "system messages belong in the session's system"}}).dump();
            turn.push_back(m);
        }
    }
    if (in.contains("message") && in["message"].is_string() && !in["message"].get<std::string>().empty()) turn.push_back({{"role", "user"}, {"content", in["message"]}});
    if (in.contains("document")) { if (!in["document"].is_string() || in["document"].get<std::string>().size() > 1000000) return json({{"ok", false}, {"error", "document must be text, at most 1 MB"}}).dump(); se->document = in["document"]; }
    if (turn.empty()) return json({{"ok", false}, {"error", "a turn needs a message"}}).dump();
    // context: text for THIS call only (fresh app state); never kept in the history
    std::string context;
    if (in.contains("context")) {
        if (!in["context"].is_string() || in["context"].get<std::string>().size() > 262144) return json({{"ok", false}, {"error", "context must be text, at most 256 KB"}}).dump();
        context = in["context"];
    }
    // the app's history policy: how much history to keep (and send), and a fresh start
    if (in.contains("historyChars")) {
        if (!in["historyChars"].is_number_integer() || in["historyChars"].get<long long>() < 0 || in["historyChars"].get<long long>() > (long long)kSessionMaxChars)
            return json({{"ok", false}, {"error", "historyChars must be 0-400000"}}).dump();
        se->maxHistoryChars = (size_t)in["historyChars"].get<long long>();
    }
    if (in.contains("resetHistory") && in["resetHistory"].is_boolean() && in["resetHistory"].get<bool>()) se->history = json::array();
    if (turn.dump().size() + context.size() > kMaxTurnBytes) return json({{"ok", false}, {"error", "the message is too large (1 MB at most)"}}).dump();
    // what the model sees: the system prompt, the latest document, the history, the new turn
    json msgs = json::array();
    std::string sys = se->system;
    if (!se->document.empty()) sys += (sys.empty() ? "" : "\n\n") + std::string("The document (latest version):\n<<<\n") + se->document + "\n>>>";
    if (!sys.empty()) msgs.push_back({{"role", "system"}, {"content", sys}});
    // history that fits: the session's limit, and the model's context window where known (~3 chars a token,
    // leaving room for the system prompt, the context, the turn and the answer); the oldest goes first
    size_t budget = std::min(kSessionMaxChars, se->maxHistoryChars);
    for (const auto& m : modelsJson()) if (jstr(m, "id") == se->model && m.value("contextTokens", json()).is_number_integer()) {
        const long long win = m["contextTokens"].get<long long>() * 3, used = (long long)(sys.size() + context.size() + turn.dump().size()) + 4096 * 3;
        budget = std::min<size_t>(budget, win > used ? (size_t)((win - used) * 0.9) : 0);
    }
    size_t first = se->history.size(), total = 0;
    while (first > 0 && total + se->history[first - 1].dump().size() <= budget) { total += se->history[first - 1].dump().size(); first--; }
    for (size_t i = first; i < se->history.size(); i++) msgs.push_back(se->history[i]);
    if (!context.empty()) msgs.push_back({{"role", "system"}, {"content", "Current state (for this request only):\n" + context}});
    for (const auto& m : turn) msgs.push_back(m);
    json req = {{"model", se->model}, {"minPrivacy", se->minPrivacy}, {"messages", msgs}};
    if (in.contains("temperature") && in["temperature"].is_number()) req["temperature"] = in["temperature"];
    if (in.contains("maxTokens") && in["maxTokens"].is_number_integer()) req["max_tokens"] = in["maxTokens"];
    if (in.contains("responseFormat")) req["responseFormat"] = in["responseFormat"];
    if (in.contains("tools")) {
        if (!in["tools"].is_array() || in["tools"].dump().size() > 65536) return json({{"ok", false}, {"error", "tools must be a list (64 KB at most)"}}).dump();
        req["tools"] = in["tools"];
        if (in.contains("toolChoice")) req["tool_choice"] = in["toolChoice"];
    }
    json r = startChat(se->caller, req, nullptr);
    if (!r.value("ok", false)) return r.dump();
    auto jt = m_jobs.find(jstr(r, "jobId"));
    if (jt != m_jobs.end()) { jt->second->sessionId = se->id; jt->second->turn = turn; }
    se->jobId = jstr(r, "jobId"); se->lastUsedMs = nowMs();
    se->sentChars += (long long)msgs.dump().size();
    r["sessionId"] = se->id;
    return r.dump();
}
std::string AiGatewayCoreImpl::sessions() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    expireSessions();
    json out = json::array();
    for (const auto& [id, se] : m_sessions)
        out.push_back({{"handle", id.substr(0, 12)}, {"caller", se->caller}, {"title", se->title}, {"model", se->model}, {"minPrivacy", se->minPrivacy},
                       {"turns", se->history.size() / 2}, {"documentChars", se->document.size()}, {"sentChars", se->sentChars}, {"createdAt", se->createdMs},
                       {"lastUsedAt", se->lastUsedMs}, {"busy", !se->jobId.empty()}});
    return out.dump();
}
std::string AiGatewayCoreImpl::closeSession(std::string sessionId) {
    std::string running;
    {
        std::lock_guard<std::recursive_mutex> lk(m_mtx);
        // the full id (the app that owns it) or the short handle sessions() shows (the user's End button);
        // a handle can only end a session, never read or continue it (AIGW-2)
        auto it = m_sessions.find(sessionId);
        if (it == m_sessions.end() && sessionId.size() == 12 && startsWith(sessionId, "ses-"))
            for (auto i2 = m_sessions.begin(); i2 != m_sessions.end(); ++i2) if (startsWith(i2->first, sessionId)) { it = i2; break; }
        if (it == m_sessions.end()) return json({{"ok", false}, {"error", "no such session"}}).dump();
        running = it->second->jobId;
        m_sessions.erase(it);
    }
    if (!running.empty()) cancelJob(running);
    return json({{"ok", true}}).dump();
}
std::string AiGatewayCoreImpl::job(std::string jobId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    auto it = m_jobs.find(jobId);
    if (it == m_jobs.end()) return json({{"ok", false}, {"error", "no such job"}}).dump();
    const auto& j = it->second;
    json o = {{"ok", true}, {"id", j->id}, {"kind", j->kind}, {"state", j->state}, {"text", j->text}, {"model", j->model}, {"connector", j->connector},
              {"privacy", j->privacy}, {"caller", j->caller}, {"error", j->error}, {"startedAt", j->startedMs}};
    if (!j->usage.is_null()) o["usage"] = j->usage;
    if (!j->message.is_null()) o["message"] = j->message;
    if (!j->result.is_null()) o["result"] = j->result;
    return o.dump();
}
void AiGatewayCoreImpl::cancelJob(const std::string& id) {
    std::shared_ptr<Job> j;
    { std::lock_guard<std::recursive_mutex> lk(m_mtx); auto it = m_jobs.find(id); if (it == m_jobs.end()) return; j = it->second; }
    post([this, j] {
        QNetworkReply* r = nullptr;
        { std::lock_guard<std::recursive_mutex> lk(m_mtx); r = j->reply; }
        if (r) r->abort();
        finishJob(j, "cancelled", "");
    });
}
std::string AiGatewayCoreImpl::cancel(std::string jobId) {
    { std::lock_guard<std::recursive_mutex> lk(m_mtx); if (!m_jobs.count(jobId)) return json({{"ok", false}, {"error", "no such job"}}).dump(); }
    cancelJob(jobId);
    return json({{"ok", true}}).dump();
}

// ── settings, usage, local endpoint ─────────────────────────────────────────────────
std::string AiGatewayCoreImpl::settings() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json s = m_settings;
    s["server"].erase("token");   // serverInfo() gives it to the view
    return s.dump();
}
std::string AiGatewayCoreImpl::setSettings(std::string settingsJson) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json in;
    try { in = json::parse(settingsJson); } catch (...) { return json({{"ok", false}, {"error", "not JSON"}}).dump(); }
    if (!in.is_object()) return json({{"ok", false}, {"error", "expected an object"}}).dump();
    if (in.contains("minPrivacy")) {
        if (!in["minPrivacy"].is_string() || tierRank(in["minPrivacy"]) < 0) return json({{"ok", false}, {"error", "unknown privacy tier"}}).dump();
        m_settings["minPrivacy"] = in["minPrivacy"];
    }
    if (in.contains("defaultModel") && in["defaultModel"].is_string()) m_settings["defaultModel"] = in["defaultModel"];
    // models the user pinned to the top of every picker: ids ("connector/model"), at most 200
    if (in.contains("pinnedModels")) {
        if (!in["pinnedModels"].is_array() || in["pinnedModels"].size() > 200) return json({{"ok", false}, {"error", "pinnedModels must be a list of up to 200 model ids"}}).dump();
        json pins = json::array();
        for (const auto& v : in["pinnedModels"]) if (v.is_string() && !v.get<std::string>().empty() && v.get<std::string>().size() <= 256) pins.push_back(v);
        m_settings["pinnedModels"] = pins;
    }
    // the user read the warning about remote (non-local) providers; the view shows them only after that
    if (in.contains("remoteAcknowledged")) {
        if (!in["remoteAcknowledged"].is_boolean()) return json({{"ok", false}, {"error", "remoteAcknowledged must be true or false"}}).dump();
        m_settings["remoteAcknowledged"] = in["remoteAcknowledged"];
    }
    if (in.contains("server") && in["server"].is_object()) {
        const json& s = in["server"];
        if (s.contains("enabled") && s["enabled"].is_boolean()) m_settings["server"]["enabled"] = s["enabled"];
        if (s.contains("port") && s["port"].is_number_integer()) {
            const int p = s["port"];
            if (p < 1024 || p > 65535) return json({{"ok", false}, {"error", "the port must be 1024-65535"}}).dump();
            m_settings["server"]["port"] = p;
        }
    }
    saveSettings();
    post([this] { applyServer(); });
    return json({{"ok", true}, {"settings", json::parse(settings())}}).dump();
}
std::string AiGatewayCoreImpl::usage() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    return m_usage.dump();
}
bool AiGatewayCoreImpl::checkServerToken(const std::string& bearer) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    const std::string t = jstr(m_settings["server"], "token");
    if (t.empty() || bearer.size() != t.size()) return false;
    unsigned char diff = 0;   // constant time
    for (size_t i = 0; i < t.size(); i++) diff |= (unsigned char)(t[i] ^ bearer[i]);
    return diff == 0;
}
void AiGatewayCoreImpl::applyServer() {
    bool on; int port;
    { std::lock_guard<std::recursive_mutex> lk(m_mtx); on = m_settings["server"].value("enabled", false); port = m_settings["server"].value("port", 11500); }
    if (!on) { delete m_server; m_server = nullptr; m_serverError.clear(); return; }
    if (m_server && m_server->port() == port) return;
    delete m_server; m_server = nullptr;
    auto* s = new aigw::LocalServer(this, m_anchor);
    std::string err;
    if (!s->start(port, err)) { delete s; std::lock_guard<std::recursive_mutex> lk(m_mtx); m_serverError = err; return; }
    m_server = s;
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    m_serverError.clear();
}
std::string AiGatewayCoreImpl::serverInfo() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    const int port = m_settings["server"].value("port", 11500);
    return json({{"running", m_server != nullptr}, {"enabled", m_settings["server"].value("enabled", false)}, {"port", port},
                 {"url", "http://127.0.0.1:" + std::to_string(port) + "/v1"}, {"token", jstr(m_settings["server"], "token")}, {"error", m_serverError}}).dump();
}
std::string AiGatewayCoreImpl::rotateServerToken() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    m_settings["server"]["token"] = "aigw-" + randomHex(20);
    saveSettings();
    return json({{"ok", true}, {"token", m_settings["server"]["token"]}}).dump();
}
