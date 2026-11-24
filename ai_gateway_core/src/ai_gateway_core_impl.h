#pragma once
// AiGatewayCoreImpl - the AI Gateway as a Logos core module (universal authoring: the public methods
// below ARE the module's API; the glue is generated from this header). Comments go ABOVE a method,
// never after it on the same line (the parser skips such a method), no default arguments, <= 4 args.
//
// One way in for every Logos app that wants AI (ADR 0001): OpenAI-compatible connectors to local
// runtimes and private / decentralised providers, routing that never goes below the privacy a caller
// asks for, jobs that stream (inference outlives the 20 s IPC timeout, so nothing here blocks), keys
// kept in a private file, per-app usage, and an optional local OpenAI endpoint.
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <nlohmann/json.hpp>
#include "logos_module_context.h"

class QObject;
class QNetworkAccessManager;
class QNetworkReply;
namespace aigw { class LocalServer; }

class AiGatewayCoreImpl : public LogosModuleContext {
public:
    AiGatewayCoreImpl();
    ~AiGatewayCoreImpl() override;

    // {name, version, dataDir}
    std::string about();
    // The built-in connector presets (providers, links, onboarding steps, privacy) as a JSON array
    std::string presets();
    // Configured connectors (keys masked to the last 4 characters) as a JSON array
    std::string connectors();
    // Add or update a connector: {id?, preset, name?, baseUrl?, apiKey?, enabled?}. An empty or absent apiKey keeps the stored one, unless the base URL moves to another origin: then the key is forgotten. Returns {ok, id, keyCleared?}
    std::string saveConnector(std::string connectorJson);
    // Remove a connector and forget its key: {ok}
    std::string removeConnector(std::string id);
    // Check a connector (lists its models): {ok, jobId, watchId}; read the result with job(jobId)
    std::string testConnector(std::string id);
    // Every usable model: [{id: "connector/model", connector, model, name, privacy, privacyRank, verified}]
    std::string models();
    // Re-read every enabled connector's model list (async): {ok}
    std::string refreshModels();
    // Start a chat completion. caller names the app asking; requestJson is an OpenAI chat request plus optional {connector, minPrivacy}. Returns {ok, jobId, watchId, model, connector, privacy} or {ok:false, error}. Keep jobId to yourself: job(jobId) returns the answer; events only carry watchId
    std::string chat(std::string caller, std::string requestJson);
    // A job: {id, state: running|done|error|cancelled, text, message, model, connector, privacy, usage, error, caller}
    std::string job(std::string jobId);
    // Stop a running job: {ok}
    std::string cancel(std::string jobId);
    // {defaultModel, minPrivacy, pinnedModels: [model id], server: {enabled, port}}
    std::string settings();
    // Change settings (partial JSON); also starts or stops the local endpoint: {ok, settings}
    std::string setSettings(std::string settingsJson);
    // The local OpenAI endpoint: {running, url, token, port, error}
    std::string serverInfo();
    // A new random token for the local endpoint: {ok, token}
    std::string rotateServerToken();
    // Per-app and per-connector usage: {apps: {...}, connectors: {...}}
    std::string usage();
    // Open a conversation the gateway keeps (ADR 0002). caller names the app; sessionJson is {title, model?, minPrivacy?, system?, document?}. Returns {ok, sessionId, model, privacy}. The AI Gateway view calls this after the user allows an ai.session intent
    std::string openSession(std::string caller, std::string sessionJson);
    // One turn in a session: {message?: text, messages?: [new OpenAI messages], document?: latest full text, temperature?, maxTokens?}. Only what is new is sent; the gateway adds the history. Returns {ok, jobId, model, privacy} like chat()
    std::string sessionChat(std::string sessionId, std::string turnJson);
    // Open sessions, without their ids: [{handle, caller, title, model, minPrivacy, turns, documentChars, createdAt, lastUsedAt, busy}]. A handle can only close a session
    std::string sessions();
    // End a session by its id or its handle (stops a running answer, forgets its history): {ok}
    std::string closeSession(std::string sessionId);

protected:
    void onContextReady() override;

logos_events:
    // A job changed: {id: watchId, state}. Every module can see events, so they carry no content: read it with job(jobId)
    void jobUpdate(const std::string& watchId, const std::string& updateJson);
    // The model list changed
    void modelsChanged(const std::string& modelsJson);

private:
    // ── internals (private: only the public methods above are the module's API) ──
    friend class aigw::LocalServer;
    struct Job;
    struct Session;
    using json = nlohmann::json;
    using Sink = std::function<void(const json& update)>;
    // used by the local endpoint: start a job from an already-parsed request, with a sink for its updates
    json startChat(const std::string& caller, const json& req, Sink sink);
    json modelsJson();
    bool checkServerToken(const std::string& bearer);
    void cancelJob(const std::string& id);
    void setupDataDir();
    void load();
    void saveConnectors();
    void saveSettings();
    void saveUsage();
    void ensureNet();
    void post(std::function<void()> fn);
    json presetFor(const std::string& presetId) const;
    json connectorById(const std::string& id) const;
    std::string tierFor(const json& connector, const json& modelEntry) const;
    void fetchModels(const std::string& connectorId, const std::string& jobId);
    void runChat(std::shared_ptr<Job> j, json body);
    void onChunk(std::shared_ptr<Job> j, const std::string& data);
    void finishJob(std::shared_ptr<Job> j, const std::string& state, const std::string& error);
    void notify(std::shared_ptr<Job> j, json update);
    void applyServer();
    std::string newId(const char* prefix);
    void expireSessions();

    std::recursive_mutex m_mtx;
    std::string m_dataDir;
    json m_presets = json::array();
    json m_connectors = json::array();   // [{id, preset, name, baseUrl, apiKey, enabled}]
    json m_settings = json::object();
    json m_usage = json::object();
    std::map<std::string, json> m_models;   // connectorId -> [{...}]
    std::map<std::string, std::string> m_modelErrors;
    std::map<std::string, std::shared_ptr<Job>> m_jobs;
    std::map<std::string, std::shared_ptr<Session>> m_sessions;
    QObject* m_anchor = nullptr;            // lives on the module's thread: network work is posted to it
    QNetworkAccessManager* m_net = nullptr;
    aigw::LocalServer* m_server = nullptr;
    std::string m_serverError;
    long m_seq = 0;
};
