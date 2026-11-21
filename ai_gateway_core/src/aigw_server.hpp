#pragma once
// LocalServer - the gateway as an OpenAI endpoint for tools outside Basecamp (ADR 0001): HTTP/1.1 on
// 127.0.0.1 only, a Bearer token, GET /v1/models, POST /v1/chat/completions (streamed as SSE when the
// request asks for it), GET /health. One request per connection (Connection: close). Basecamp ships
// Qt Network but not Qt HttpServer, so this is a small QTcpServer.
#include <memory>
#include <string>

class QObject;
class QTcpServer;
class AiGatewayCoreImpl;

namespace aigw {
class LocalServer {
public:
    LocalServer(AiGatewayCoreImpl* core, QObject* parent);
    ~LocalServer();
    bool start(int port, std::string& error);
    int port() const { return m_port; }
private:
    void accept();
    AiGatewayCoreImpl* m_core;
    QTcpServer* m_srv;
    int m_port = 0;
};
}  // namespace aigw
