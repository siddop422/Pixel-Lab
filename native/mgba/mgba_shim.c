/*
 * PocketGB native adapter for the upstream mGBA core.
 * mGBA is MPL-2.0; the exact source revision is pinned by the Windows build workflow.
 * This file only exposes a small stable C ABI to the C# frontend. It is not a reimplementation
 * of the emulation core and does not ship ROMs or BIOS data.
 */
#include <mgba/core/core.h>
#include <mgba/core/config.h>
#include <mgba/core/log.h>
#include <mgba-util/audio-buffer.h>
#include <mgba-util/image.h>
#include <mgba-util/vfs.h>

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#include <signal.h>
#include <process.h>
#if defined(_MSC_VER)
#include <crtdbg.h>
#include <eh.h>
#endif

static char g_active_operation[256] = "native library startup";
static volatile LONG g_crash_handlers_installed = 0;

static void pgb_set_operation(const char* operation) {
    if (!operation) operation = "unknown native operation";
    snprintf(g_active_operation, sizeof(g_active_operation), "%s", operation);
}

static void pgb_native_crash_path(char* path, size_t capacity) {
    char base[MAX_PATH] = { 0 };
    DWORD length = GetEnvironmentVariableA("LOCALAPPDATA", base, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) {
        length = GetTempPathA(MAX_PATH, base);
        if (length == 0 || length >= MAX_PATH) snprintf(base, sizeof(base), ".");
    }

    char app_directory[MAX_PATH];
    char log_directory[MAX_PATH];
    snprintf(app_directory, sizeof(app_directory), "%s\\PocketGB", base);
    snprintf(log_directory, sizeof(log_directory), "%s\\logs", app_directory);
    CreateDirectoryA(app_directory, NULL);
    CreateDirectoryA(log_directory, NULL);
    snprintf(path, capacity, "%s\\native-crash.txt", log_directory);
}

static void pgb_write_native_crash(const char* kind, const char* details) {
    char path[MAX_PATH];
    pgb_native_crash_path(path, sizeof(path));
    FILE* output = fopen(path, "ab");
    if (!output) return;

    SYSTEMTIME now;
    GetLocalTime(&now);
    fprintf(output,
        "[%04u-%02u-%02u %02u:%02u:%02u.%03u] %s\\r\\n"
        "Operation: %s\\r\\n"
        "Details: %s\\r\\n\\r\\n",
        now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
        kind ? kind : "Native failure",
        g_active_operation,
        details ? details : "No additional details");
    fclose(output);
}

#if defined(_MSC_VER)
static void pgb_wide_to_utf8(const wchar_t* source, char* destination, int capacity) {
    if (!destination || capacity <= 0) return;
    destination[0] = '\0';
    if (!source) return;
    WideCharToMultiByte(CP_UTF8, 0, source, -1, destination, capacity, NULL, NULL);
}

static void __cdecl pgb_invalid_parameter(
    const wchar_t* expression, const wchar_t* function,
    const wchar_t* file, unsigned int line, uintptr_t reserved) {
    char expression_text[256], function_text[256], file_text[256], details[900];
    (void)reserved;
    pgb_wide_to_utf8(expression, expression_text, sizeof(expression_text));
    pgb_wide_to_utf8(function, function_text, sizeof(function_text));
    pgb_wide_to_utf8(file, file_text, sizeof(file_text));
    snprintf(details, sizeof(details),
        "MSVC invalid-parameter handler. Expression: %s; Function: %s; File: %s; Line: %u",
        expression_text, function_text, file_text, line);
    pgb_write_native_crash("MSVC C/C++ runtime invalid parameter", details);
}

static void __cdecl pgb_purecall(void) {
    pgb_write_native_crash("MSVC pure virtual call", "The native runtime detected a pure virtual function call.");
    _exit(134);
}
#endif

static void pgb_abort_signal(int signal_number) {
    char details[128];
    snprintf(details, sizeof(details), "Native abort signal: %d", signal_number);
    pgb_write_native_crash("Native abort", details);
    _exit(128 + signal_number);
}

static LONG WINAPI pgb_unhandled_exception(EXCEPTION_POINTERS* exception_info) {
    char details[256];
    if (exception_info && exception_info->ExceptionRecord) {
        snprintf(details, sizeof(details), "Windows exception 0x%08lX at address %p",
            (unsigned long)exception_info->ExceptionRecord->ExceptionCode,
            exception_info->ExceptionRecord->ExceptionAddress);
    } else {
        snprintf(details, sizeof(details), "Windows reported an unhandled native exception.");
    }
    pgb_write_native_crash("Unhandled Windows native exception", details);
    return EXCEPTION_EXECUTE_HANDLER;
}

static void pgb_install_native_crash_handlers(void) {
    if (InterlockedCompareExchange(&g_crash_handlers_installed, 1, 0) != 0) return;
#if defined(_MSC_VER)
    _set_invalid_parameter_handler(pgb_invalid_parameter);
    _set_purecall_handler(pgb_purecall);
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
#endif
    signal(SIGABRT, pgb_abort_signal);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    SetUnhandledExceptionFilter(pgb_unhandled_exception);
}
#else
static void pgb_set_operation(const char* operation) { (void)operation; }
static void pgb_install_native_crash_handlers(void) { }
#endif

#if defined(_WIN32)
#define PGB_EXPORT __declspec(dllexport)
#else
#define PGB_EXPORT __attribute__((visibility("default")))
#endif

#define PGB_VIDEO_WIDTH_MAX 256u
#define PGB_VIDEO_HEIGHT_MAX 224u
#define PGB_MAX_ARCHIVE_DIRS 32u
#define PGB_MAX_ARCHIVE_DEPTH 16u

typedef struct PgbMgbaContext {
    struct mCore* core;
    uint8_t* rom_data;
    size_t rom_size;
    mColor* core_video;
    uint32_t* rgba_video;
    unsigned video_width;
    unsigned video_height;
    int config_initialized;
    int core_initialized;
    int rom_loaded;
    char error[512];
    char title[32];
    char game_code[8];
    int platform;
#if defined(ENABLE_VFS) && defined(ENABLE_DIRECTORIES)
    struct VDir* archive_directories[PGB_MAX_ARCHIVE_DIRS];
    unsigned int archive_directory_count;
#endif
} PgbMgbaContext;

static void set_error(PgbMgbaContext* ctx, const char* message) {
    if (!ctx) return;
    if (!message) message = "Unknown mGBA error";
    snprintf(ctx->error, sizeof(ctx->error), "%s", message);
}

static int load_rom_file(PgbMgbaContext* ctx, struct VFile* rom_file) {
    if (!ctx || !rom_file) return 0;

    /* mCoreFindVF detects the cartridge platform from its real header, not the filename. */
    ctx->core = mCoreFindVF(rom_file);
    if (!ctx->core) {
        rom_file->close(rom_file);
        set_error(ctx, "mGBA did not recognise this cartridge as a supported GBA or GB/GBC ROM.");
        return 0;
    }

    /* The platform probe may seek while reading the header; the core needs the ROM from byte 0. */
    rom_file->seek(rom_file, 0, SEEK_SET);
    mCoreInitConfig(ctx->core, "PocketGB");
    ctx->config_initialized = 1;

    if (!ctx->core->init(ctx->core)) {
        /*
         * The pinned GB/GBA core init routines clean up their own partial memory-map
         * allocations when they return false. Their deinit routines require a fully
         * initialised CPU/board pair, so release_core must free only the outer core
         * allocation in this failure case rather than calling core->deinit.
         */
        rom_file->close(rom_file);
        set_error(ctx, "mGBA could not initialise the cartridge core. Close other applications and try again.");
        return 0;
    }
    ctx->core_initialized = 1;

    /* Use mGBA's HLE BIOS by default. No copyrighted BIOS image is bundled. */
    struct mCoreOptions defaults;
    memset(&defaults, 0, sizeof(defaults));
    defaults.useBios = true;
    defaults.skipBios = true;
    defaults.volume = 0x100;
    defaults.logLevel = mLOG_WARN;
    defaults.sampleRate = 48000;
    mCoreConfigLoadDefaults(&ctx->core->config, &defaults);
    mCoreLoadConfig(ctx->core);

    ctx->core_video = (mColor*)calloc(
        PGB_VIDEO_WIDTH_MAX * PGB_VIDEO_HEIGHT_MAX, sizeof(mColor));
    ctx->rgba_video = (uint32_t*)calloc(
        PGB_VIDEO_WIDTH_MAX * PGB_VIDEO_HEIGHT_MAX, sizeof(uint32_t));
    if (!ctx->core_video || !ctx->rgba_video) {
        rom_file->close(rom_file);
        set_error(ctx, "Could not allocate the mGBA video buffers.");
        return 0;
    }

    ctx->core->setVideoBuffer(ctx->core, ctx->core_video, PGB_VIDEO_WIDTH_MAX);
    ctx->core->setAudioBufferSize(ctx->core, 0x4000);

    /* On success, loadROM owns the VFile. The owning archive remains open in ctx. */
    if (!ctx->core->loadROM(ctx->core, rom_file)) {
        rom_file->close(rom_file);
        set_error(ctx, "mGBA rejected this cartridge image.");
        return 0;
    }

    ctx->rom_loaded = 1;
    ctx->core->reset(ctx->core);
    ctx->platform = (int)ctx->core->platform(ctx->core);
    ctx->core->currentVideoSize(ctx->core, &ctx->video_width, &ctx->video_height);

    struct mGameInfo info;
    memset(&info, 0, sizeof(info));
    ctx->core->getGameInfo(ctx->core, &info);
    snprintf(ctx->title, sizeof(ctx->title), "%s", info.title);
    snprintf(ctx->game_code, sizeof(ctx->game_code), "%s", info.code);
    ctx->error[0] = '\0';
    return 1;
}

static void release_core(PgbMgbaContext* ctx) {
    if (!ctx) return;

    if (ctx->core) {
        if (ctx->core_initialized) {
            if (ctx->rom_loaded && ctx->core->unloadROM) {
                ctx->core->unloadROM(ctx->core);
            }
            if (ctx->config_initialized) {
                mCoreConfigDeinit(&ctx->core->config);
            }
            if (ctx->core->deinit) {
                /* GBACoreDeinit/GBCoreDeinit also release the outer mCore allocation. */
                ctx->core->deinit(ctx->core);
            } else {
                free(ctx->core);
            }
        } else {
            if (ctx->config_initialized) {
                mCoreConfigDeinit(&ctx->core->config);
            }
            /* Never call core->deinit on an unsuccessful core->init result. */
            free(ctx->core);
        }
        ctx->core = NULL;
    }

    free(ctx->rom_data);
    ctx->rom_data = NULL;
    ctx->rom_size = 0;

    free(ctx->core_video);
    ctx->core_video = NULL;
    free(ctx->rgba_video);
    ctx->rgba_video = NULL;

#if defined(ENABLE_VFS) && defined(ENABLE_DIRECTORIES)
    /* The core unloads its VFile first; close nested dirs from child back to archive root. */
    while (ctx->archive_directory_count > 0) {
        struct VDir* directory = ctx->archive_directories[--ctx->archive_directory_count];
        ctx->archive_directories[ctx->archive_directory_count] = NULL;
        if (directory) directory->close(directory);
    }
#endif

    ctx->video_width = 0;
    ctx->video_height = 0;
    ctx->config_initialized = 0;
    ctx->core_initialized = 0;
    ctx->rom_loaded = 0;
    ctx->platform = mPLATFORM_NONE;
    ctx->title[0] = '\0';
    ctx->game_code[0] = '\0';
}

PGB_EXPORT void* pgb_mgba_create(void) {
    pgb_install_native_crash_handlers();
    pgb_set_operation("Create mGBA context");
    PgbMgbaContext* ctx = (PgbMgbaContext*)calloc(1, sizeof(PgbMgbaContext));
    if (!ctx) return NULL;
    ctx->platform = mPLATFORM_NONE;
    return ctx;
}

PGB_EXPORT void pgb_mgba_destroy(void* handle) {
    pgb_set_operation("Destroy mGBA context");
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx) return;
    release_core(ctx);
    free(ctx);
}

PGB_EXPORT const char* pgb_mgba_last_error(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    return ctx ? ctx->error : "Invalid mGBA context";
}

PGB_EXPORT int pgb_mgba_load_rom(void* handle, const uint8_t* rom, size_t rom_bytes) {
    pgb_set_operation("Load raw cartridge image");
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !rom || rom_bytes == 0 || rom_bytes > (32u * 1024u * 1024u)) {
        set_error(ctx, "Invalid ROM data (expected 1 byte to 32 MiB).");
        return 0;
    }

    release_core(ctx);
    ctx->rom_data = (uint8_t*)malloc(rom_bytes);
    if (!ctx->rom_data) {
        set_error(ctx, "Could not allocate memory for the cartridge image.");
        return 0;
    }
    memcpy(ctx->rom_data, rom, rom_bytes);
    ctx->rom_size = rom_bytes;

    struct VFile* rom_file = VFileFromMemory(ctx->rom_data, ctx->rom_size);
    if (!rom_file) {
        set_error(ctx, "mGBA could not create a virtual file for this ROM.");
        release_core(ctx);
        return 0;
    }

    if (!load_rom_file(ctx, rom_file)) {
        release_core(ctx);
        return 0;
    }
    return 1;
}

/*
 * mGBA's VFS layer provides the 7z reader (bundled LZMA decoder) when USE_LZMA
 * is enabled in CMake. Iterate archive members and select a real GB/GBA cartridge
 * by header, never by a misleading filename suffix.
 */
#if defined(ENABLE_VFS) && defined(ENABLE_DIRECTORIES)
static struct VFile* find_cartridge_in_archive_directory(
    PgbMgbaContext* ctx, struct VDir* directory, unsigned int depth) {
    if (!ctx || !directory || depth > PGB_MAX_ARCHIVE_DEPTH) return NULL;

    directory->rewind(directory);
    struct VDirEntry* entry = NULL;
    while ((entry = directory->listNext(directory))) {
        if (!entry->name || !entry->type) continue;
        const char* name = entry->name(entry);
        if (!name || !name[0]) continue;

        if (entry->type(entry) == VFS_DIRECTORY) {
            /* Keep every ancestor VDir alive while an extracted VFile is in use by mGBA. */
            if (!directory->openDir || ctx->archive_directory_count >= PGB_MAX_ARCHIVE_DIRS)
                continue;
            struct VDir* child = directory->openDir(directory, name);
            if (!child) continue;
            ctx->archive_directories[ctx->archive_directory_count++] = child;
            struct VFile* nested = find_cartridge_in_archive_directory(ctx, child, depth + 1);
            if (nested) return nested;

            child->close(child);
            ctx->archive_directories[--ctx->archive_directory_count] = NULL;
            continue;
        }

        if (!directory->openFile) continue;
        struct VFile* candidate = directory->openFile(directory, name, O_RDONLY);
        if (!candidate) continue;

        ssize_t size = candidate->size(candidate);
        if (size <= 0 || size > (ssize_t)(32u * 1024u * 1024u)) {
            candidate->close(candidate);
            continue;
        }

        enum mPlatform platform = mCoreIsCompatible(candidate);
        candidate->seek(candidate, 0, SEEK_SET);
        if (platform == mPLATFORM_NONE) {
            candidate->close(candidate);
            continue;
        }

        return candidate;
    }

    return NULL;
}
#endif

/*
 * mGBA's VFS layer provides the 7z reader (bundled LZMA decoder) when USE_LZMA
 * is enabled in CMake. Search nested folders and select a real cartridge by header,
 * rather than trusting a filename extension in an archive.
 */
PGB_EXPORT int pgb_mgba_load_7z_file(void* handle, const char* path) {
    pgb_set_operation("Load 7z cartridge archive");
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !path || !path[0]) {
        set_error(ctx, "A 7z archive path is required.");
        return 0;
    }

#if defined(ENABLE_VFS) && defined(ENABLE_DIRECTORIES)
    release_core(ctx);
    struct VDir* root = VDirOpenArchive(path);
    if (!root) {
        set_error(ctx, "mGBA could not open this 7z archive. Check that it is not corrupt or password-protected.");
        return 0;
    }

    ctx->archive_directories[ctx->archive_directory_count++] = root;
    struct VFile* candidate = find_cartridge_in_archive_directory(ctx, root, 0);
    if (!candidate) {
        release_core(ctx);
        set_error(ctx, "This 7z archive contains no supported GB, GBC, SGB or GBA cartridge under 32 MiB.");
        return 0;
    }

    if (!load_rom_file(ctx, candidate)) {
        release_core(ctx);
        return 0;
    }
    return 1;
#else
    set_error(ctx, "7z support was not enabled in this mGBA build.");
    return 0;
#endif
}

/* Apply an IPS, UPS or BPS sidecar patch using the active mGBA platform's patch loader. */
PGB_EXPORT int pgb_mgba_apply_patch(void* handle, const uint8_t* patch_data, size_t patch_bytes) {
    pgb_set_operation("Apply cartridge patch");
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core || !ctx->rom_loaded || !patch_data ||
        patch_bytes == 0 || patch_bytes > (32u * 1024u * 1024u)) {
        set_error(ctx, "Invalid patch data or no loaded cartridge.");
        return 0;
    }

    struct VFile* patch_file = VFileFromConstMemory(patch_data, patch_bytes);
    if (!patch_file) {
        set_error(ctx, "Could not create an in-memory patch file.");
        return 0;
    }

    bool applied = ctx->core->loadPatch && ctx->core->loadPatch(ctx->core, patch_file);
    patch_file->close(patch_file);
    if (!applied) {
        set_error(ctx, "mGBA could not apply this IPS, UPS or BPS patch to the selected ROM.");
        return 0;
    }

    ctx->core->reset(ctx->core);
    ctx->core->currentVideoSize(ctx->core, &ctx->video_width, &ctx->video_height);
    struct mGameInfo patched_info;
    memset(&patched_info, 0, sizeof(patched_info));
    ctx->core->getGameInfo(ctx->core, &patched_info);
    snprintf(ctx->title, sizeof(ctx->title), "%s", patched_info.title);
    snprintf(ctx->game_code, sizeof(ctx->game_code), "%s", patched_info.code);
    ctx->error[0] = '\0';
    return 1;
}

PGB_EXPORT int pgb_mgba_run_frame(void* handle) {
    pgb_set_operation("Execute game frame");
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core || !ctx->rom_loaded) return 0;

    ctx->core->runFrame(ctx->core);
    ctx->core->currentVideoSize(ctx->core, &ctx->video_width, &ctx->video_height);

    unsigned width = ctx->video_width;
    unsigned height = ctx->video_height;
    if (width == 0 || height == 0 ||
        width > PGB_VIDEO_WIDTH_MAX || height > PGB_VIDEO_HEIGHT_MAX) {
        set_error(ctx, "mGBA returned an unsupported video size.");
        return 0;
    }

    for (unsigned y = 0; y < height; ++y) {
        const mColor* source = &ctx->core_video[y * PGB_VIDEO_WIDTH_MAX];
        uint32_t* destination = &ctx->rgba_video[y * width];
        for (unsigned x = 0; x < width; ++x) {
            /* Native mColor is XBGR8 in the little-endian byte order expected by GL_RGBA. */
            destination[x] = ((uint32_t)source[x]) | 0xFF000000u;
        }
    }

    return 1;
}

PGB_EXPORT const uint32_t* pgb_mgba_video_pixels(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    return ctx ? ctx->rgba_video : NULL;
}

PGB_EXPORT int pgb_mgba_video_width(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    return ctx ? (int)ctx->video_width : 0;
}

PGB_EXPORT int pgb_mgba_video_height(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    return ctx ? (int)ctx->video_height : 0;
}

PGB_EXPORT int pgb_mgba_platform(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    return ctx ? ctx->platform : mPLATFORM_NONE;
}

PGB_EXPORT void pgb_mgba_game_title(void* handle, char* destination, size_t capacity) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!destination || capacity == 0) return;
    snprintf(destination, capacity, "%s", ctx ? ctx->title : "");
}

PGB_EXPORT void pgb_mgba_game_code(void* handle, char* destination, size_t capacity) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!destination || capacity == 0) return;
    snprintf(destination, capacity, "%s", ctx ? ctx->game_code : "");
}

PGB_EXPORT double pgb_mgba_frame_rate(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core) return 0.0;
    int32_t cycles = ctx->core->frameCycles(ctx->core);
    if (cycles <= 0) return 0.0;
    return (double)ctx->core->frequency(ctx->core) / (double)cycles;
}

PGB_EXPORT void pgb_mgba_set_keys(void* handle, uint32_t keys) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (ctx && ctx->core) ctx->core->setKeys(ctx->core, keys);
}

PGB_EXPORT int pgb_mgba_audio_sample_rate(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core) return 0;
    return (int)ctx->core->audioSampleRate(ctx->core);
}

PGB_EXPORT int pgb_mgba_audio_available(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core) return 0;
    return (int)mAudioBufferAvailable(ctx->core->getAudioBuffer(ctx->core));
}

PGB_EXPORT int pgb_mgba_audio_read(void* handle, int16_t* destination, int frames) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core || !destination || frames <= 0) return 0;
    return (int)mAudioBufferRead(ctx->core->getAudioBuffer(ctx->core), destination, (size_t)frames);
}

PGB_EXPORT size_t pgb_mgba_state_size(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core) return 0;
    return ctx->core->stateSize(ctx->core);
}

PGB_EXPORT int pgb_mgba_save_state(void* handle, void* destination, size_t capacity) {
    pgb_set_operation("Write save state");
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core || !destination) return 0;
    if (capacity < ctx->core->stateSize(ctx->core)) return 0;
    return ctx->core->saveState(ctx->core, destination) ? 1 : 0;
}

PGB_EXPORT int pgb_mgba_load_state(void* handle, const void* source, size_t size) {
    pgb_set_operation("Load save state");
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core || !source) return 0;
    if (size != ctx->core->stateSize(ctx->core)) return 0;
    return ctx->core->loadState(ctx->core, source) ? 1 : 0;
}

PGB_EXPORT size_t pgb_mgba_savedata_size(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core) return 0;
    void* data = NULL;
    size_t size = ctx->core->savedataClone(ctx->core, &data);
    free(data);
    return size;
}

PGB_EXPORT size_t pgb_mgba_savedata_copy(void* handle, void* destination, size_t capacity) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core) return 0;
    void* data = NULL;
    size_t size = ctx->core->savedataClone(ctx->core, &data);
    if (data && destination && capacity >= size) memcpy(destination, data, size);
    free(data);
    return size;
}

PGB_EXPORT int pgb_mgba_savedata_load(void* handle, const void* source, size_t size) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core || !source || size == 0) return 0;
    return ctx->core->savedataRestore(ctx->core, source, size, true) ? 1 : 0;
}

PGB_EXPORT void pgb_mgba_reset(void* handle) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core) return;
    ctx->core->reset(ctx->core);
    ctx->core->currentVideoSize(ctx->core, &ctx->video_width, &ctx->video_height);
}
