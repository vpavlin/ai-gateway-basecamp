#include "aigw_server.hpp"
#include "ai_gateway_core_impl.h"

#include <QHostAddress>
#include <QPointer>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>

#include <algorithm>
#include <cctype>
#include <ctime>
#include <memory>

using json = nlohmann::json;

namespace aigw {
namespace {
constexpr size_t kMaxRequest = 4u << 20;   // 4 MiB: long prompts, not uploads
constexpr int kMaxConnections = 32;          // a same-user process can't exhaust file descriptors
constexpr int kReadTimeoutMs = 30000;        // the whole request must arrive within 30 s (no slowloris)

std::string lower(std::string s) { std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return (char)std::tolower(c); }); return s; }
void send(QTcpSocket* s, int status, const char* reason, const std::string& ctype, const std::string& body) {
    std::string h = "HTTP/1.1 " + std::to_string(status) + " " + reason + "\r\nContent-Type: " + ctype +
                    "\r\nContent-Length: " + std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n";
    s->write(h.data(), (qint64)h.size());
    s->write(body.data(), (qint64)body.size());
    s->disconnectFromHost();
}
void sendError(QTcpSocket* s, int status, const char* reason, const std::string& msg, const char* type) {
    send(s, status, reason, "application/json", json({{"error", {{"message", msg}, {"type", type}}}}).dump());
}
// one OpenAI chat.completion(.chunk) object
json chunkObj(const std::string& id, const std::string& model, const json& delta, const json& finish) {
    return json({{"id", id}, {"object", "chat.completion.chunk"}, {"created", (long long)std::time(nullptr)}, {"model", model},
                 {"choices", json::array({json({{"index", 0}, {"delta", delta}, {"finish_reason", finish}})})}});
}
}  // namespace

LocalServer::LocalServer(AiGatewayCoreImpl* core, QObject* parent) : m_core(core), m_srv(new QTcpServer(parent)) {}
LocalServer::~LocalServer() { m_srv->close(); m_srv->deleteLater(); }

bool LocalServer::start(int port, std::string& error) {
    if (!m_srv->listen(QHostAddress::LocalHost, (quint16)port)) { error = "can't listen on 127.0.0.1:" + std::to_string(port) + " (" + m_srv->errorString().toStdString() + ")"; return false; }
    m_port = port;
    QObject::connect(m_srv, &QTcpServer::newConnection, m_srv, [this] { accept(); });
    return true;
}

void LocalServer::accept() {
    while (QTcpSocket* s = m_srv->nextPendingConnection()) {
        if (m_open >= kMaxConnections) { s->abort(); s->deleteLater(); continue; }
        m_open++;
        QObject::connect(s, &QObject::destroyed, m_srv, [this] { m_open--; });
        auto buf = std::make_shared<std::string>();
        auto handled = std::make_shared<bool>(false);
        QObject::connect(s, &QTcpSocket::disconnected, s, &QObject::deleteLater);
        QTimer::singleShot(kReadTimeoutMs, s, [s, handled] { if (!*handled) { *handled = true; s->abort(); s->deleteLater(); } });
        auto onRead = [this, s, buf, handled] {
            if (*handled) { s->readAll(); return; }
            const QByteArray in = s->readAll();
            buf->append(in.constData(), (size_t)in.size());
            if (buf->size() > kMaxRequest) { *handled = true; sendError(s, 413, "Payload Too Large", "request too large", "invalid_request_error"); return; }
            const size_t hdrEnd = buf->find("\r\n\r\n");
            if (hdrEnd == std::string::npos) return;
            // request line + headers
            const std::string head = buf->substr(0, hdrEnd);
            const size_t le = head.find("\r\n");
            const std::string reqLine = head.substr(0, le);
            const size_t sp1 = reqLine.find(' '), sp2 = reqLine.find(' ', sp1 + 1);
            if (sp1 == std::string::npos || sp2 == std::string::npos) { *handled = true; sendError(s, 400, "Bad Request", "bad request line", "invalid_request_error"); return; }
            const std::string method = reqLine.substr(0, sp1);
            std::string path = reqLine.substr(sp1 + 1, sp2 - sp1 - 1);
            if (path.find('?') != std::string::npos) path = path.substr(0, path.find('?'));
            size_t contentLength = 0; std::string auth, host, origin;
            size_t pos = le == std::string::npos ? head.size() : le + 2;
            while (pos < head.size()) {
                size_t e = head.find("\r\n", pos); if (e == std::string::npos) e = head.size();
                const std::string line = head.substr(pos, e - pos);
                const size_t c = line.find(':');
                if (c != std::string::npos) {
                    const std::string k = lower(line.substr(0, c));
                    std::string v = line.substr(c + 1); while (!v.empty() && v[0] == ' ') v.erase(0, 1);
                    if (k == "content-length") { try { contentLength = (size_t)std::stoull(v); } catch (...) { contentLength = kMaxRequest + 1; } }
                    if (k == "authorization") auth = v;
                    if (k == "host") host = lower(v);
                    if (k == "origin") origin = v;
                }
                pos = e + 2;
            }
            if (contentLength > kMaxRequest) { *handled = true; sendError(s, 413, "Payload Too Large", "request too large", "invalid_request_error"); return; }
            if (buf->size() < hdrEnd + 4 + contentLength) return;   // wait for the body
            *handled = true;
            const std::string body = buf->substr(hdrEnd + 4, contentLength);
            // only this computer's own clients: a web page (Origin) or a rebinding DNS name (Host) is refused
            const std::string p = std::to_string(m_port);
            if (!(host == "127.0.0.1:" + p || host == "localhost:" + p || host == "[::1]:" + p || host == "127.0.0.1" || host == "localhost")) {
                sendError(s, 403, "Forbidden", "only http://127.0.0.1:" + p + " is served", "invalid_request_error"); return;
            }
            if (!origin.empty()) { sendError(s, 403, "Forbidden", "browser requests are not served", "invalid_request_error"); return; }
            if (method == "GET" && path == "/health") { send(s, 200, "OK", "application/json", "{\"ok\":true}"); return; }
            // every other route needs the token
            const std::string bearer = auth.rfind("Bearer ", 0) == 0 ? auth.substr(7) : "";
            if (!m_core->checkServerToken(bearer)) { sendError(s, 401, "Unauthorized", "missing or wrong token (AI Gateway -> Settings -> Local endpoint)", "invalid_api_key"); return; }
            if (method == "GET" && (path == "/v1/models" || path == "/models")) {
                json data = json::array();
                json models;
                { std::lock_guard<std::recursive_mutex> lk(m_core->m_mtx); models = m_core->modelsJson(); }
                for (const auto& m : models) data.push_back(json({{"id", m.value("id", "")}, {"object", "model"}, {"owned_by", m.value("connector", "")}, {"privacy", m.value("privacy", "")}}));
                send(s, 200, "OK", "application/json", json({{"object", "list"}, {"data", data}}).dump());
                return;
            }
            if (method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions")) {
                json req;
                try { req = json::parse(body); } catch (...) { sendError(s, 400, "Bad Request", "the body isn't JSON", "invalid_request_error"); return; }
                if (!req.is_object()) { sendError(s, 400, "Bad Request", "the body must be a JSON object", "invalid_request_error"); return; }
                // only a real boolean; a request with tools is answered whole (the core doesn't stream tool calls)
                const bool hasTools = req.contains("tools") && req["tools"].is_array() && !req["tools"].empty();
                const bool stream = req.contains("stream") && req["stream"].is_boolean() && req["stream"].get<bool>() && !hasTools;
                QPointer<QTcpSocket> sock(s);
                auto started = std::make_shared<bool>(false);
                auto jid = std::make_shared<std::string>();
                auto modelName = std::make_shared<std::string>();
                // updates arrive on the module thread (the socket's thread)
                auto sink = [sock, stream, started, jid, modelName](const json& up) {
                    if (!sock) return;
                    const std::string state = up.value("state", "");
                    if (stream) {
                        if (!*started) {
                            *started = true;
                            const std::string h = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n";
                            sock->write(h.data(), (qint64)h.size());
                            const std::string first = "data: " + chunkObj(*jid, *modelName, json({{"role", "assistant"}, {"content", ""}}), nullptr).dump() + "\n\n";
                            sock->write(first.data(), (qint64)first.size());
                        }
                        if (up.contains("delta") && up["delta"].is_string() && !up["delta"].get<std::string>().empty()) {
                            const std::string d = "data: " + chunkObj(*jid, *modelName, json({{"content", up["delta"]}}), nullptr).dump() + "\n\n";
                            sock->write(d.data(), (qint64)d.size());
                        }
                        if (state == "done" || state == "error" || state == "cancelled") {
                            std::string tail;
                            if (state == "error") tail += "data: " + json({{"error", {{"message", up.value("error", "")}, {"type", "upstream_error"}}}}).dump() + "\n\n";
                            json last = chunkObj(*jid, *modelName, json::object(), state == "done" ? json("stop") : json("error"));
                            if (up.contains("usage")) last["usage"] = up["usage"];
                            tail += "data: " + last.dump() + "\n\ndata: [DONE]\n\n";
                            sock->write(tail.data(), (qint64)tail.size());
                            sock->disconnectFromHost();
                        }
                        return;
                    }
                    if (state == "done") {
                        json msg = up.contains("message") && up["message"].is_object() ? up["message"] : json({{"role", "assistant"}, {"content", up.value("text", "")}});
                        json resp = {{"id", *jid}, {"object", "chat.completion"}, {"created", (long long)std::time(nullptr)}, {"model", *modelName},
                                     {"choices", json::array({json({{"index", 0}, {"message", msg}, {"finish_reason", "stop"}})})}};
                        if (up.contains("usage")) resp["usage"] = up["usage"];
                        send(sock, 200, "OK", "application/json", resp.dump());
                    } else if (state == "error" || state == "cancelled") {
                        sendError(sock, 502, "Bad Gateway", up.value("error", state), "upstream_error");
                    }
                };
                const json r = m_core->startChat("local endpoint", req, sink);
                if (!r.value("ok", false)) { sendError(s, 400, "Bad Request", r.value("error", "refused"), "invalid_request_error"); return; }
                *jid = r.value("jobId", ""); *modelName = r.value("model", "");
                // the client went away: stop paying for an answer nobody reads
                QObject::connect(s, &QTcpSocket::disconnected, m_srv, [this, jid] { m_core->cancelJob(*jid); });
                return;
            }
            sendError(s, 404, "Not Found", "unknown route " + method + " " + path, "invalid_request_error");
        };
        // nothing a client sends may take the process down (AIGW-5)
        QObject::connect(s, &QTcpSocket::readyRead, s, [s, handled, onRead] {
            try { onRead(); }
            catch (...) { if (!*handled) *handled = true; sendError(s, 500, "Internal Server Error", "the request couldn't be handled", "server_error"); }
        });
    }
}
}  // namespace aigw
