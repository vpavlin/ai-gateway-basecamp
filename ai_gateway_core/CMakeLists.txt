cmake_minimum_required(VERSION 3.14)
project(AiGatewayCorePlugin LANGUAGES CXX)
if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LogosModule.cmake")
    include(cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found")
endif()
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json" METADATA_JSON)
string(JSON MODULE_NAME GET ${METADATA_JSON} name)

# Qt Network: HTTPS to the providers and the local endpoint (Basecamp ships libQt6Network and the
# OpenSSL TLS backend). The builder only finds Core + RemoteObjects itself.
find_package(Qt6 REQUIRED COMPONENTS Network)

logos_module(
    NAME ${MODULE_NAME}
    SOURCES
        src/ai_gateway_core_impl.h
        src/ai_gateway_core_impl.cpp
        src/aigw_server.hpp
        src/aigw_server.cpp
        src/aigw_presets.hpp
    INCLUDE_DIRS src
    LINK_LIBRARIES Qt6::Network
)
