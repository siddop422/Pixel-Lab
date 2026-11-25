cmake_minimum_required(VERSION 3.20)

project(PocketGBMgbaNative LANGUAGES C CXX)

if(NOT DEFINED MGBA_SOURCE_DIR OR NOT EXISTS "\${MGBA_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "MGBA_SOURCE_DIR must point to a checked-out mGBA source tree.")
endif()

# Build only the reusable mGBA library. No Qt, SDL frontend, debugger or optional
# codec/database dependencies are needed by PocketGB.
set(LIBMGBA_ONLY ON CACHE BOOL "" FORCE)
set(M_CORE_GBA ON CACHE BOOL "" FORCE)
set(M_CORE_GB ON CACHE BOOL "" FORCE)
set(BUILD_TEST OFF CACHE BOOL "" FORCE)
set(BUILD_SUITE OFF CACHE BOOL "" FORCE)
set(BUILD_CINEMA OFF CACHE BOOL "" FORCE)
set(ENABLE_DEBUGGERS OFF CACHE BOOL "" FORCE)
set(ENABLE_SCRIPTING OFF CACHE BOOL "" FORCE)
set(USE_PTHREADS OFF CACHE BOOL "" FORCE)

add_subdirectory("\${MGBA_SOURCE_DIR}" "\${CMAKE_BINARY_DIR}/mgba")

if(NOT TARGET mgba)
    message(FATAL_ERROR "The pinned mGBA CMake build did not create the mgba core target.")
endif()

# The shim compiles against the exact same feature macros and headers as the
# mGBA static library. mCore is a conditional-layout C struct; mismatched
# ENABLE_VFS / ENABLE_DIRECTORIES / MINIMAL_CORE definitions corrupt its ABI.
get_target_property(MGBA_TARGET_DEFINITIONS mgba COMPILE_DEFINITIONS)
get_target_property(MGBA_TARGET_INCLUDE_DIRS mgba INCLUDE_DIRECTORIES)
get_target_property(MGBA_TARGET_OPTIONS mgba COMPILE_OPTIONS)
get_directory_property(MGBA_DIRECTORY_DEFINITIONS DIRECTORY "\${MGBA_SOURCE_DIR}" COMPILE_DEFINITIONS)
get_directory_property(MGBA_DIRECTORY_INCLUDE_DIRS DIRECTORY "\${MGBA_SOURCE_DIR}" INCLUDE_DIRECTORIES)

if(NOT MGBA_TARGET_INCLUDE_DIRS)
    message(FATAL_ERROR "Could not discover the include directories from the mGBA target.")
endif()

add_library(pocketgb_mgba SHARED mgba_shim.c)
target_include_directories(pocketgb_mgba PRIVATE
    \${MGBA_TARGET_INCLUDE_DIRS}
    \${MGBA_DIRECTORY_INCLUDE_DIRS}
)
target_compile_definitions(pocketgb_mgba PRIVATE
    \${MGBA_TARGET_DEFINITIONS}
    \${MGBA_DIRECTORY_DEFINITIONS}
)
if(MGBA_TARGET_OPTIONS)
    target_compile_options(pocketgb_mgba PRIVATE \${MGBA_TARGET_OPTIONS})
endif()
target_link_libraries(pocketgb_mgba PRIVATE mgba)

set_target_properties(pocketgb_mgba PROPERTIES
    OUTPUT_NAME "pocketgb-mgba"
    WINDOWS_EXPORT_ALL_SYMBOLS OFF
    RUNTIME_OUTPUT_DIRECTORY "\${PGB_NATIVE_OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "\${PGB_NATIVE_OUTPUT_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "\${PGB_NATIVE_OUTPUT_DIR}"
    LIBRARY_OUTPUT_DIRECTORY_RELEASE "\${PGB_NATIVE_OUTPUT_DIR}"
)
