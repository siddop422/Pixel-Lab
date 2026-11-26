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

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define PGB_EXPORT __declspec(dllexport)
#else
#define PGB_EXPORT __attribute__((visibility("default")))
#endif

#define PGB_VIDEO_WIDTH_MAX 256u
#define PGB_VIDEO_HEIGHT_MAX 224u

typedef struct PgbMgbaContext {
    struct mCore* core;
    uint8_t* rom_data;
    size_t rom_size;
    mColor* core_video;
    uint32_t* rgba_video;
    unsigned video_width;
    unsigned video_height;
    int config_initialized;
    int rom_loaded;
    char error[512];
    char title[32];
    char game_code[8];
    int platform;
#if defined(ENABLE_VFS) && defined(ENABLE_DIRECTORIES)
    struct VDir* archive_directory;
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
        rom_file->close(rom_file);
        set_error(ctx, "mGBA failed to initialise the selected emulation core.");
        return 0;
    }

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
    ctx->error[0] = '\\0';
    return 1;
}

static void release_core(PgbMgbaContext* ctx) {
    if (!ctx) return;

    if (ctx->core) {
        if (ctx->rom_loaded && ctx->core->unloadROM) {
            ctx->core->unloadROM(ctx->core);
        }
        if (ctx->config_initialized) {
            mCoreConfigDeinit(&ctx->core->config);
        }
        if (ctx->core->deinit) {
            ctx->core->deinit(ctx->core);
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
    /* The core unloads its VFile first; only then is its parent archive safe to close. */
    if (ctx->archive_directory) {
        ctx->archive_directory->close(ctx->archive_directory);
        ctx->archive_directory = NULL;
    }
#endif

    ctx->video_width = 0;
    ctx->video_height = 0;
    ctx->config_initialized = 0;
    ctx->rom_loaded = 0;
    ctx->platform = mPLATFORM_NONE;
    ctx->title[0] = '\0';
    ctx->game_code[0] = '\0';
}

PGB_EXPORT void* pgb_mgba_create(void) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)calloc(1, sizeof(PgbMgbaContext));
    if (!ctx) return NULL;
    ctx->platform = mPLATFORM_NONE;
    return ctx;
}

PGB_EXPORT void pgb_mgba_destroy(void* handle) {
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
PGB_EXPORT int pgb_mgba_load_7z_file(void* handle, const char* path) {
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !path || !path[0]) {
        set_error(ctx, "A 7z archive path is required.");
        return 0;
    }

#if defined(ENABLE_VFS) && defined(ENABLE_DIRECTORIES)
    release_core(ctx);
    ctx->archive_directory = VDirOpenArchive(path);
    if (!ctx->archive_directory) {
        set_error(ctx, "mGBA could not open this 7z archive. Check that it is not corrupt or password-protected.");
        return 0;
    }

    ctx->archive_directory->rewind(ctx->archive_directory);
    struct VDirEntry* entry = NULL;
    while ((entry = ctx->archive_directory->listNext(ctx->archive_directory))) {
        if (!entry->name || !entry->type || entry->type(entry) == VFS_DIRECTORY) continue;
        struct VFile* candidate = ctx->archive_directory->openFile(
            ctx->archive_directory, entry->name(entry), O_RDONLY);
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

        if (!load_rom_file(ctx, candidate)) {
            release_core(ctx);
            return 0;
        }
        return 1;
    }

    release_core(ctx);
    set_error(ctx, "This 7z archive contains no supported GB, GBC, SGB or GBA cartridge under 32 MiB.");
    return 0;
#else
    set_error(ctx, "7z support was not enabled in this mGBA build.");
    return 0;
#endif
}

/* Apply an IPS, UPS or BPS sidecar patch using the active mGBA platform's patch loader. */
PGB_EXPORT int pgb_mgba_apply_patch(void* handle, const uint8_t* patch_data, size_t patch_bytes) {
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
    ctx->error[0] = '\\0';
    return 1;
}

PGB_EXPORT int pgb_mgba_run_frame(void* handle) {
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
    PgbMgbaContext* ctx = (PgbMgbaContext*)handle;
    if (!ctx || !ctx->core || !destination) return 0;
    if (capacity < ctx->core->stateSize(ctx->core)) return 0;
    return ctx->core->saveState(ctx->core, destination) ? 1 : 0;
}

PGB_EXPORT int pgb_mgba_load_state(void* handle, const void* source, size_t size) {
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
