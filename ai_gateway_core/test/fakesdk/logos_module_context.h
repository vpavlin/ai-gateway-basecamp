#pragma once
// FAKE logos SDK (test-only): just enough of the universal-module surface for ai_gateway_core to
// compile and run outside nix/Basecamp. The real header comes from logos-module-builder.
#include <string>
#define logos_events public
class LogosModuleContext {
public:
    virtual ~LogosModuleContext() = default;
    void fakeStart() { onContextReady(); }
    const std::string& instancePersistencePath() const { return m_fakePersist; }
    std::string m_fakePersist;
protected:
    virtual void onContextReady() {}
};
