cmake_minimum_required(VERSION 3.14)
project(DufsCoreModule LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LogosModule.cmake")
    include(cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT or ensure logos-module-builder is in your flake inputs.")
endif()

# HTTP to the dufs servers. Qt Network ships with Basecamp/logosctl (6.9.2).
find_package(Qt6 REQUIRED COMPONENTS Network)

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json" METADATA_JSON)
string(JSON MODULE_NAME GET ${METADATA_JSON} name)

logos_module(
    NAME ${MODULE_NAME}
    SOURCES
        src/dufs_core_impl.h
        src/dufs_core_impl.cpp
    INCLUDE_DIRS src
    LINK_LIBRARIES Qt6::Network
)
