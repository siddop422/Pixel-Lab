cmake_minimum_required(VERSION 3.20)

project(PocketGBMgbaNative LANGUAGES C CXX)

if(ANDROID)
    set(CMAKE_POSITION_INDEPENDENT_CODE ON)
endif()

# Link the MSVC C runtime statically so the native DLL does not require a separate VC++ redistributable install.
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>" CACHE STRING "" FORCE)
endif()

# CI checks out mGBA into third_party/mgba at an exact upstream revision.
if(NOT DEFINED MGBA_SOURCE_DIR OR MGBA_SOURCE_DIR STREQUAL "")
    set(MGBA_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../third_party/mgba")
endif()
get_filename_component(MGBA_SOURCE_DIR "${MGBA_SOURCE_DIR}" ABSOLUTE)
message(STATUS "Using pinned mGBA source: ${MGBA_SOURCE_DIR}")
if(NOT EXISTS "${MGBA_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "Pinned mGBA source was not found at ${MGBA_SOURCE_DIR}.")
endif()

if(NOT DEFINED PGB_NATIVE_OUTPUT_DIR OR PGB_NATIVE_OUTPUT_DIR STREQUAL "")
    set(PGB_NATIVE_OUTPUT_DIR "${CMAKE_CURRENT_LIST_DIR}/../../artifacts/native/win-x64")
endif()
get_filename_component(PGB_NATIVE_OUTPUT_DIR "${PGB_NATIVE_OUTPUT_DIR}" ABSOLUTE)

# Build only the reusable mGBA library. No Qt or SDL desktop frontend is needed.
set(LIBMGBA_ONLY ON CACHE BOOL "" FORCE)
set(M_CORE_GBA ON CACHE BOOL "" FORCE)
set(M_CORE_GB ON CACHE BOOL "" FORCE)
set(BUILD_TEST OFF CACHE BOOL "" FORCE)
set(BUILD_SUITE OFF CACHE BOOL "" FORCE)
set(BUILD_CINEMA OFF CACHE BOOL "" FORCE)
set(ENABLE_DEBUGGERS OFF CACHE BOOL "" FORCE)
set(ENABLE_SCRIPTING OFF CACHE BOOL "" FORCE)
if(ANDROID)
    set(USE_PTHREADS ON CACHE BOOL "" FORCE)
# Enable mGBA's bundled 7-Zip virtual filesystem reader.
set(USE_LZMA ON CACHE BOOL "" FORCE)
else()
    set(USE_PTHREADS OFF CACHE BOOL "" FORCE)
endif()

add_subdirectory("${MGBA_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/mgba")

if(NOT TARGET mgba)
    message(FATAL_ERROR "The pinned mGBA CMake build did not create the mgba core target.")
endif()

# mCore has conditional fields. Compile the shim with the exact feature defines
# and include paths of the upstream library to keep the C ABI layout identical.
get_target_property(MGBA_TARGET_DEFINITIONS mgba COMPILE_DEFINITIONS)
get_target_property(MGBA_TARGET_INCLUDE_DIRS mgba INCLUDE_DIRECTORIES)
get_target_property(MGBA_TARGET_OPTIONS mgba COMPILE_OPTIONS)
get_directory_property(MGBA_DIRECTORY_DEFINITIONS DIRECTORY "${MGBA_SOURCE_DIR}" COMPILE_DEFINITIONS)
get_directory_property(MGBA_DIRECTORY_INCLUDE_DIRS DIRECTORY "${MGBA_SOURCE_DIR}" INCLUDE_DIRECTORIES)

if(NOT MGBA_TARGET_INCLUDE_DIRS)
    message(FATAL_ERROR "Could not discover the include directories from the mGBA target.")
endif()

add_library(pocketgb_mgba SHARED mgba_shim.c)
target_include_directories(pocketgb_mgba PRIVATE
    ${MGBA_TARGET_INCLUDE_DIRS}
    ${MGBA_DIRECTORY_INCLUDE_DIRS}
)
target_compile_definitions(pocketgb_mgba PRIVATE
    ${MGBA_TARGET_DEFINITIONS}
    ${MGBA_DIRECTORY_DEFINITIONS}
)
if(MGBA_TARGET_OPTIONS)
    target_compile_options(pocketgb_mgba PRIVATE ${MGBA_TARGET_OPTIONS})
endif()
target_link_libraries(pocketgb_mgba PRIVATE mgba)
if(ANDROID)
    find_library(ANDROID_LOG_LIBRARY log)
    if(ANDROID_LOG_LIBRARY)
        target_link_libraries(pocketgb_mgba PRIVATE ${ANDROID_LOG_LIBRARY})
    endif()
endif()

set_target_properties(pocketgb_mgba PROPERTIES
    OUTPUT_NAME "pocketgb-mgba"
    WINDOWS_EXPORT_ALL_SYMBOLS ON
    RUNTIME_OUTPUT_DIRECTORY "${PGB_NATIVE_OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${PGB_NATIVE_OUTPUT_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "${PGB_NATIVE_OUTPUT_DIR}"
    LIBRARY_OUTPUT_DIRECTORY_RELEASE "${PGB_NATIVE_OUTPUT_DIR}"
)
