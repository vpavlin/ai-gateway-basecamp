// ai_gateway_core end-to-end test: the REAL core (ai_gateway_core_impl.cpp + aigw_server.cpp) against a fake
// OpenAI-compatible provider (fake_openai.py), outside nix/Basecamp. Run with test/run-tests.sh.
#include "ai_gateway_core_impl.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QProcess>
#include <QThread>

#include <cstdio>
#include <cstdlib>
#include <functional>
#include <map>
#include <string>
#include <vector>

using json = nlohmann::json;

static int checks = 0, failures = 0;
#define CHECK(cond, msg) do { checks++; if (cond) std::printf("  ok   %s\n", std::string(msg).c_str()); else { failures++; std::printf("  FAIL %s\n", std::string(msg).c_str()); } } while (0)

// the events the generated glue would forward to Basecamp
static std::vector<std::pair<std::string, json>> g_updates;
static int g_modelsChanged = 0;
void AiGatewayCoreImpl::jobUpdate(const std::string& id, const std::string& u) { g_updates.push_back({id, json::parse(u)}); }
void AiGatewayCoreImpl::modelsChanged(const std::string&) { g_modelsChanged++; }

static void pump(int ms) {
    QElapsedTimer t; t.start();
    while (t.elapsed() < ms) { QCoreApplication::processEvents(QEventLoop::AllEvents, 20); QThread::msleep(5); }
}
static bool waitUntil(std::function<bool()> f, int ms) {
    QElapsedTimer t; t.start();
    while (t.elapsed() < ms) { if (f()) return true; QCoreApplication::processEvents(QEventLoop::AllEvents, 20); QThread::msleep(5); }
    return f();
}
static json J(const std::string& s) { try { return json::parse(s); } catch (...) { return json(); } }
static std::string sh(const std::string& cmd) {
    std::string out; char buf[4096];
    FILE* p = popen(cmd.c_str(), "r");
    if (!p) return out;
    size_t n; while ((n = fread(buf, 1, sizeof buf, p)) > 0) out.append(buf, n);
    pclose(p);
    return out;
}

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    setvbuf(stdout, nullptr, _IONBF, 0);
    const std::string dir = argc > 1 ? argv[1] : ".";
    const char* tmp = std::getenv("AIGW_TEST_TMP");
    const std::string data = std::string(tmp ? tmp : "/tmp") + "/aigw-test-data";
    std::system(("rm -rf '" + data + "'").c_str());
    setenv("AIGW_CORE_DATA", data.c_str(), 1);

    QProcess fake;
    fake.start("python3", {QString::fromStdString(dir + "/fake_openai.py"), "18765", "sekret"});
    fake.waitForStarted();
    pump(600);

    AiGatewayCoreImpl core;
    core.fakeStart();
    pump(200);

    std::printf("presets + connectors:\n");
    json presets = J(core.presets());
    CHECK(presets.is_array() && presets.size() >= 8, "presets load (" + std::to_string(presets.size()) + ")");
    bool venice = false; for (auto& p : presets) if (p.value("id", "") == "venice") venice = true;
    CHECK(venice, "Venice preset present");
    CHECK(!J(core.saveConnector(R"({"preset":"custom","baseUrl":"ftp://x"})")).value("ok", true) && J(core.connectors()).empty(), "a non-http base URL is refused, nothing saved");
    CHECK(!J(core.saveConnector(R"({"preset":"custom"})")).value("ok", true) && J(core.connectors()).empty(), "a custom connector needs a URL");
    // a Venice-shaped connector pointed at the fake (privacy per model, e2ee skipped, balance header)
    json r = J(core.saveConnector(R"({"preset":"venice","baseUrl":"http://127.0.0.1:18765/v1","apiKey":"wrong"})"));
    CHECK(r.value("ok", false) && r.value("id", "") == "venice", "Venice connector saved");
    CHECK(waitUntil([&] { return J(core.connectors())[0].value("error", "") != ""; }, 5000), "a wrong key is reported: " + J(core.connectors())[0].value("error", std::string()));
    json cs = J(core.connectors());
    CHECK(cs[0].value("apiKey", "") != "wrong" && cs[0].value("hasKey", false), "the key is masked, never returned");
    core.saveConnector(R"({"id":"venice","preset":"venice","apiKey":"sekret"})");
    CHECK(waitUntil([&] { return J(core.models()).size() == 3; }, 5000), "models listed: image and e2ee-only models skipped (" + std::to_string(J(core.models()).size()) + ")");
    std::map<std::string, std::string> tier;
    for (auto& m : J(core.models())) tier[m.value("model", "")] = m.value("privacy", "");
    CHECK(tier["echo"] == "no-retention" && tier["anon"] == "standard" && tier["broken"] == "standard", "privacy per model from model_spec.privacy");
    {
        json echo, anon; for (auto& m : J(core.models())) { if (m.value("model", "") == "echo") echo = m; if (m.value("model", "") == "anon") anon = m; }
        CHECK(echo.value("jsonSchema", false) == true && echo.value("tools", false) == true && echo.value("contextTokens", 0) == 32768 && anon.value("jsonSchema", true) == false && echo.contains("jsonSchema"), "models() says per model: jsonSchema, tools, context window");
        json un = J(core.chat("tester", R"({"model":"venice/anon","responseFormat":{"type":"json_schema","json_schema":{"name":"x","schema":{}}},"messages":[{"role":"user","content":"x"}]})"));
        CHECK(!un.value("ok", true) && un.value("code", "") == "unsupported", "json_schema on a model that can't: a clear error");
        CHECK(!J(core.chat("tester", R"({"model":"venice/echo","responseFormat":{"type":"yaml"},"messages":[{"role":"user","content":"x"}]})")).value("ok", true), "a bad responseFormat is refused");
    }
    CHECK(J(core.connectors())[0].contains("balance"), "balance header kept");
    // a "local" custom connector on the same fake: the most private route
    core.saveConnector(R"({"preset":"custom","name":"Local box","baseUrl":"http://127.0.0.1:18765/v1","apiKey":"sekret","privacy":"local"})");
    CHECK(waitUntil([&] { return J(core.models()).size() == 7; }, 5000), "a second connector's models join (the custom one keeps e2ee-*: only the Venice preset skips them)");
    json t = J(core.testConnector("venice"));
    CHECK(waitUntil([&] { return J(core.job(t.value("jobId", ""))).value("state", "") == "done"; }, 5000), "testConnector answers through a job");

    std::printf("chat:\n");
    g_updates.clear();
    json c = J(core.chat("tester", R"({"model":"venice/echo","messages":[{"role":"user","content":"hello world, stream me"}]})"));
    CHECK(c.value("ok", false) && c.value("privacy", "") == "no-retention", "chat starts on the model asked for");
    const std::string jid = c.value("jobId", "");
    CHECK(waitUntil([&] { return J(core.job(jid)).value("state", "") == "done"; }, 8000), "the job finishes");
    json jr = J(core.job(jid));
    CHECK(jr.value("text", "") == "echo: hello world, stream me", "streamed text assembled: " + jr.value("text", std::string()));
    CHECK(jr.contains("usage") && jr["usage"].value("completion_tokens", 0) == 7, "a stream asks for usage (stream_options.include_usage) and gets it");
    {
        json rj = J(core.chat("tester", R"({"model":"venice/echo","messages":[{"role":"user","content":"reject-stream-options"}]})"));
        const std::string rid = rj.value("jobId", "");
        waitUntil([&] { return J(core.job(rid)).value("state", "") != "running"; }, 8000);
        json rr = J(core.job(rid));
        CHECK(rr.value("state", "") == "done" && rr.value("text", "") == "echo: reject-stream-options", "a server that refuses stream_options is retried without it: " + rr.value("state", std::string()) + " " + rr.value("error", std::string()));
    }
    // events are visible to every module: they name the job by its public watch id and carry no content (AIGW-3)
    const std::string wid = c.value("watchId", "");
    int evs = 0; bool leak = false;
    for (auto& u : g_updates) {
        if (u.first == jid) leak = true;
        if (u.first == wid) { evs++; if (u.second.contains("text") || u.second.contains("delta") || u.second.contains("sessionId") || u.second.dump().find("echo") != std::string::npos) leak = true; }
    }
    CHECK(!wid.empty() && evs >= 1 && !leak, "jobUpdate events carry only the watch id and the state (" + std::to_string(evs) + " events)");
    CHECK(jid.size() >= 36, "job ids are 128 random bits");

    std::printf("security (review 2026-11-24):\n");
    {
        auto finished = [&](const std::string& body) {
            json r0 = J(core.chat("tester", body));
            const std::string id = r0.value("jobId", "");
            waitUntil([&] { return J(core.job(id)).value("state", "") != "running"; }, 8000);
            return J(core.job(id));
        };
        json bu = finished(R"({"model":"venice/echo","messages":[{"role":"user","content":"bad-usage"}]})");
        CHECK(bu.value("state", "") == "done" && bu["usage"].value("prompt_tokens", -1) == 0, "AIGW-4: non-numeric token counts from a provider count as 0 (no crash)");
        json co = finished(R"({"model":"venice/echo","messages":[{"role":"user","content":"cutoff"}]})");
        CHECK(co.value("state", "") == "error" && co.value("error", "").find("cut off") != std::string::npos, "AIGW-12: a stream cut before its end is an error: " + co.value("error", std::string()));
        const std::string huge(4u << 20, 'x');
        CHECK(!J(core.chat("tester", json({{"model", "venice/echo"}, {"messages", json::array({json({{"role", "user"}, {"content", huge}})})}}).dump())).value("ok", true), "AIGW-13: a request over 4 MB is refused");
        // AIGW-1: moving a connector to another origin forgets its key
        json mv = J(core.saveConnector(R"({"id":"venice","preset":"venice","baseUrl":"http://localhost:18765/v1"})"));
        bool hasKey = true; for (auto& cc : J(core.connectors())) if (cc.value("id", "") == "venice") hasKey = cc.value("hasKey", true);
        CHECK(mv.value("keyCleared", false) && !hasKey, "AIGW-1: a connector moved to another origin loses its stored key");
        core.saveConnector(R"({"id":"venice","preset":"venice","baseUrl":"http://127.0.0.1:18765/v1","apiKey":"sekret"})");
        json same = J(core.saveConnector(R"({"id":"venice","preset":"venice","baseUrl":"http://127.0.0.1:18765/v1/"})"));
        CHECK(!same.value("keyCleared", false), "the same origin keeps the key");
        // AIGW-6: "local" only on this computer
        json rl = J(core.saveConnector(R"({"preset":"custom","name":"far box","baseUrl":"http://203.0.113.9/v1","privacy":"local"})"));
        std::string farTier; for (auto& cc : J(core.connectors())) if (cc.value("id", "") == rl.value("id", "")) farTier = cc.value("privacy", "");
        CHECK(farTier == "standard", "AIGW-6: a remote custom connector can't be labelled local (" + farTier + ")");
        // a local runtime preset pointed at another machine: its card isn't "on this device" either
        json om = J(core.saveConnector(R"({"preset":"ollama","baseUrl":"http://ai.box.example/v1"})"));
        json omc; for (auto& cc : J(core.connectors())) if (cc.value("id", "") == om.value("id", "")) omc = cc;
        CHECK(omc.value("privacy", "") == "standard" && omc.value("remote", false) && omc.value("name", "") == "Ollama (ai.box.example)", "a local preset on another host is labelled standard + by its host: " + omc.value("name", std::string()));
        core.removeConnector(om.value("id", ""));
        core.removeConnector(rl.value("id", ""));
        // AIGW-8: on a NEAR-shaped connector only listed open models keep the TEE tier
        json nr = J(core.saveConnector(R"({"preset":"nearai","baseUrl":"http://127.0.0.1:18765/v1","apiKey":"sekret"})"));
        const std::string nid = nr.value("id", "");
        waitUntil([&] { for (auto& m : J(core.models())) if (m.value("connector", "") == nid) return true; return false; }, 5000);
        int nTee = 0, nAll = 0; for (auto& m : J(core.models())) if (m.value("connector", "") == nid) { nAll++; if (m.value("privacy", "") != "standard") nTee++; }
        CHECK(nAll > 0 && nTee == 0, "AIGW-8: unlisted model names on NEAR are standard, not TEE (" + std::to_string(nAll) + " models)");
        core.removeConnector(nid);
        waitUntil([&] { return J(core.models()).size() == 7; }, 3000);
    }
    // routing by privacy
    json lc = J(core.chat("tester", R"({"messages":[{"role":"user","content":"x"}]})"));
    CHECK(lc.value("ok", false) && lc.value("privacy", "") == "local", "no model named: the most private one (" + lc.value("model", std::string()) + ")");
    json rf = J(core.chat("tester", R"({"model":"venice/anon","minPrivacy":"no-retention","messages":[{"role":"user","content":"x"}]})"));
    CHECK(!rf.value("ok", true) && rf.value("error", "").find("less private") != std::string::npos, "a model below the caller's minPrivacy is refused");
    core.setSettings(R"({"minPrivacy":"tee"})");
    json rs = J(core.chat("tester", R"({"model":"venice/echo","messages":[{"role":"user","content":"x"}]})"));
    CHECK(!rs.value("ok", true), "the user's minPrivacy setting is a floor for every caller");
    core.setSettings(R"({"minPrivacy":"standard"})");
    std::printf("sessions:\n");
    {
        json so = J(core.openSession("fileverse_ui", R"({"title":"Notes","model":"venice/echo","system":"Be brief.","document":"v1 text"})"));
        const std::string sid = so.value("sessionId", "");
        CHECK(so.value("ok", false) && sid.size() > 20 && so.value("model", "") == "venice/echo", "openSession picks the model and returns a session id");
        auto turn = [&](const std::string& t) {
            json r = J(core.sessionChat(sid, t));
            if (!r.value("ok", false)) return std::string("ERR ") + r.value("error", std::string());
            const std::string id = r.value("jobId", "");
            waitUntil([&] { return J(core.job(id)).value("state", "") != "running"; }, 8000);
            return J(core.job(id)).value("text", std::string());
        };
        CHECK(turn(R"({"message":"hi"})") == "echo: hi", "first turn");
        const std::string t2 = turn(R"({"message":"inspect"})");
        CHECK(t2 == "roles=system,user,assistant,user doc=v1 text", "the gateway adds system+document+history: " + t2);
        const std::string t3 = turn(R"({"message":"inspect","document":"v2 text"})");
        CHECK(t3 == "roles=system,user,assistant,user,assistant,user doc=v2 text", "a new document replaces the old one: " + t3);
        json sl = J(core.sessions());
        CHECK(sl.is_array() && sl.size() == 1 && sl[0].value("turns", 0) == 3 && sl[0].value("caller", "") == "fileverse_ui", "sessions() lists it with its turns");
        CHECK(!sl[0].contains("id") && sl[0].value("handle", "").size() == 12 && sid.find(sl[0].value("handle", "")) == 0, "AIGW-2: sessions() shows a short handle, never the session id");
        CHECK(J(core.sessionChat(sl[0].value("handle", ""), R"({"message":"x"})")).value("code", "") == "no_session", "AIGW-2: a handle can't continue a session");
        CHECK(J(core.sessionChat(sid, R"({"messages":[{"role":"system","content":"x"}]})")).value("ok", true) == false, "a turn can't inject a system message");
        CHECK(J(core.sessionChat(sid, R"({})")).value("ok", true) == false, "a turn needs a message");
        // basecamp-voice: ephemeral context, structured output, history policy, sent size
        const std::string t4 = turn(R"({"message":"inspect","context":"apps: scala, kym"})");
        CHECK(t4.find(" ctx") != std::string::npos, "a turn's context reaches the model: " + t4);
        const std::string t5 = turn(R"({"message":"inspect"})");
        CHECK(t5.find(" ctx") == std::string::npos, "and is not kept in the history: " + t5);
        const std::string t6 = turn(R"({"message":"plan","responseFormat":{"type":"json_schema","json_schema":{"name":"plan","schema":{"type":"object"}}}})");
        CHECK(t6.find("json_schema") != std::string::npos && t6.find("plan") != std::string::npos, "responseFormat goes to the provider as response_format: " + t6);
        const std::string t7 = turn(R"({"message":"inspect","resetHistory":true})");
        CHECK(t7.rfind("roles=system,user ", 0) == 0, "resetHistory starts the history over: " + t7);
        CHECK(J(core.sessionChat(sid, R"({"message":"x","historyChars":-1})")).value("ok", true) == false, "historyChars is checked");
        CHECK(J(core.sessions())[0].value("sentChars", 0) > 0, "sessions() shows what a session has sent");
        CHECK(J(core.closeSession(sid)).value("ok", false) && J(core.sessionChat(sid, R"({"message":"x"})")).value("code", "") == "no_session", "a closed session refuses turns");
        CHECK(J(core.sessions()).empty(), "and is gone from the list");
        json s2 = J(core.openSession("other", R"({"title":"T2","model":"venice/echo"})"));
        const std::string h2 = J(core.sessions())[0].value("handle", "");
        CHECK(J(core.closeSession(h2)).value("ok", false) && J(core.sessions()).empty(), "the user's End button closes a session by its handle");
    }
    CHECK(J(core.setSettings(R"({"pinnedModels":["venice/echo","custom/echo"]})")).value("ok", false) && J(core.settings())["pinnedModels"].size() == 2, "pinned models are kept");
    CHECK(!J(core.setSettings(R"({"pinnedModels":"venice/echo"})")).value("ok", true), "pinnedModels must be a list");
    CHECK(J(core.settings()).value("remoteAcknowledged", true) == false, "remote providers start unacknowledged");
    CHECK(J(core.setSettings(R"({"remoteAcknowledged":true})")).value("ok", false) && J(core.settings()).value("remoteAcknowledged", false), "the remote-provider warning can be acknowledged");
    CHECK(!J(core.setSettings(R"({"remoteAcknowledged":"yes"})")).value("ok", true), "remoteAcknowledged must be a boolean");
    CHECK(!J(core.chat("tester", R"({"model":"venice/echo","minPrivacy":"secret","messages":[{"role":"user","content":"x"}]})")).value("ok", true), "an unknown tier is refused");
    CHECK(!J(core.chat("tester", R"({"messages":[]})")).value("ok", true), "no messages: refused");
    // errors and tools
    json be = J(core.chat("tester", R"({"model":"venice/broken","messages":[{"role":"user","content":"x"}]})"));
    CHECK(waitUntil([&] { return J(core.job(be.value("jobId", ""))).value("state", "") == "error"; }, 5000), "a provider error ends the job");
    CHECK(J(core.job(be.value("jobId", ""))).value("error", "") == "model exploded", "...with the provider's message");
    json tc = J(core.chat("tester", R"({"model":"venice/echo","tools":[{"type":"function","function":{"name":"f","parameters":{}}}],"messages":[{"role":"user","content":"x"}]})"));
    CHECK(waitUntil([&] { return J(core.job(tc.value("jobId", ""))).value("state", "") == "done"; }, 5000), "a tools request completes (not streamed)");
    CHECK(J(core.job(tc.value("jobId", "")))["message"].contains("tool_calls"), "...and returns the tool calls");
    // cancel
    json cc = J(core.chat("tester", R"({"model":"venice/echo","messages":[{"role":"user","content":"a long one to cancel quickly please"}]})"));
    core.cancel(cc.value("jobId", ""));
    CHECK(waitUntil([&] { std::string s = J(core.job(cc.value("jobId", ""))).value("state", ""); return s == "cancelled" || s == "done"; }, 5000), "cancel ends a job");
    json us = J(core.usage());
    CHECK(us["apps"]["tester"].value("requests", 0) >= 3 && us["apps"]["tester"].value("completionTokens", 0) >= 7, "usage per app");

    std::printf("local endpoint:\n");
    core.setSettings(R"({"server":{"enabled":true,"port":18766}})");
    CHECK(waitUntil([&] { return J(core.serverInfo()).value("running", false); }, 3000), "the local endpoint starts");
    const std::string tok = J(core.serverInfo()).value("token", "");
    // run curl off the Qt thread so the server can answer
    auto curlAsync = [&](const std::string& cmd) {
        std::string out; bool done = false;
        QThread* th = QThread::create([&] { out = sh(cmd); done = true; });
        th->start();
        waitUntil([&] { return done; }, 15000);
        th->wait(); delete th;
        return out;
    };
    CHECK(curlAsync("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18766/v1/models") == "401", "no token: 401");
    CHECK(curlAsync("curl -s -o /dev/null -w '%{http_code}' -H 'Origin: http://evil.example' -H 'Authorization: Bearer " + tok + "' http://127.0.0.1:18766/v1/models") == "403", "AIGW-11: a browser request (Origin) is refused");
    CHECK(curlAsync("curl -s -o /dev/null -w '%{http_code}' -H 'Host: rebind.example' -H 'Authorization: Bearer " + tok + "' http://127.0.0.1:18766/v1/models") == "403", "AIGW-11: a foreign Host (DNS rebinding) is refused");
    json sy = J(curlAsync("curl -s -H 'Authorization: Bearer " + tok + "' -H 'Content-Type: application/json' -d '{\"model\":\"venice/echo\",\"stream\":\"yes\",\"messages\":[{\"role\":\"user\",\"content\":\"odd\"}]}' http://127.0.0.1:18766/v1/chat/completions"));
    CHECK(sy.contains("choices"), "AIGW-5: a non-boolean stream field is answered, not a crash");
    json ml = J(curlAsync("curl -s -H 'Authorization: Bearer " + tok + "' http://127.0.0.1:18766/v1/models"));
    CHECK(ml.contains("data") && ml["data"].size() == 7, "GET /v1/models lists every model");
    json nc = J(curlAsync("curl -s -H 'Authorization: Bearer " + tok + "' -H 'Content-Type: application/json' -d '{\"model\":\"venice/echo\",\"messages\":[{\"role\":\"user\",\"content\":\"via http\"}]}' http://127.0.0.1:18766/v1/chat/completions"));
    CHECK(nc.contains("choices") && nc["choices"][0]["message"].value("content", "") == "echo: via http", "POST /v1/chat/completions (JSON)");
    const std::string sse = curlAsync("curl -s -N -H 'Authorization: Bearer " + tok + "' -H 'Content-Type: application/json' -d '{\"model\":\"venice/echo\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"via sse\"}]}' http://127.0.0.1:18766/v1/chat/completions");
    std::string assembled;
    size_t p = 0;
    while ((p = sse.find("data: ", p)) != std::string::npos) {
        size_t e = sse.find("\n\n", p); std::string d = sse.substr(p + 6, e - p - 6); p = e;
        if (d == "[DONE]") break;
        json ch = J(d);
        if (ch.contains("choices") && ch["choices"][0]["delta"].contains("content")) assembled += ch["choices"][0]["delta"]["content"].get<std::string>();
    }
    CHECK(assembled == "echo: via sse" && sse.find("[DONE]") != std::string::npos, "streamed SSE in OpenAI chunk format: " + assembled);
    CHECK(J(core.usage())["apps"].contains("local endpoint"), "the endpoint's calls are counted as their own app");
    core.setSettings(R"({"server":{"enabled":false}})");
    CHECK(waitUntil([&] { return !J(core.serverInfo()).value("running", true); }, 3000), "the endpoint stops");

    std::printf("persistence:\n");
    {
        AiGatewayCoreImpl again;
        again.fakeStart();
        pump(200);
        json cs2 = J(again.connectors());
        CHECK(cs2.size() == 2 && cs2[0].value("hasKey", false), "connectors and keys survive a restart");
        CHECK(sh("stat -c %a '" + data + "/connectors.json'").substr(0, 3) == "600", "connectors.json is private (0600)");
        CHECK(waitUntil([&] { return J(again.models()).size() == 7; }, 5000), "models are fetched again at start");
    }
    CHECK(J(core.removeConnector("venice")).value("ok", false) && J(core.models()).size() == 4, "removing a connector drops its models");

    fake.kill(); fake.waitForFinished();
    std::printf("\n%d/%d checks passed\n", checks - failures, checks);
    std::printf(failures ? "TESTS FAILED\n" : "ALL GREEN\n");
    return failures ? 1 : 0;
}
