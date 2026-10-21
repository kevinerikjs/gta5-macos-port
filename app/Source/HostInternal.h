#pragma once
#include "game.h"
#include "wasm-rt-exceptions.h"
#include "EngineHost.h"
#include <stdatomic.h>
#include <setjmp.h>

struct w2c_env {
  wasm_rt_shared_memory_t memory;
  w2c_game game;
};
struct w2c_wasi__snapshot__preview1 { struct w2c_env *env; };
void pg_log(const char *message);
// Mods inside archives (GTA-69): a file in Mods at <archive>.rpf/<path inside> is served past the archive's
// real end; when the engine opens that archive, EngineHost points the entry there (pg_packfile_mounted).
typedef struct { const char *inner; uint64_t offset, length; uint32_t low, high; int resource; } PGModPiece;
int pg_mods_for_archive(const char *enginePath, const PGModPiece **pieces);
const char *pg_mods_folder_path(void);
// A file from the Mods folder that the game uses this launch (GTA-153, NativeAssets.m).
void pg_mod_path_used(const char *path);
const char *pg_game_index_path(void);
const char *pg_game_files_version(void);
bool pg_mods_archive_path(const char *enginePath, char *out, size_t cap);
void pg_missing_import(const char *name);
// A call into the engine through an invoke_* import, which an engine longjmp can end early
// (Scripts/prepare_longjmp.py). The innermost one on each thread is pg_invoke_top.
typedef struct pg_invoke_frame { jmp_buf jump; struct pg_invoke_frame *outer; u64 stack; } pg_invoke_frame;
extern _Thread_local pg_invoke_frame *pg_invoke_top;
void *pg_pointer(struct w2c_env *, uint64_t address, uint64_t size);

const char *pg_string(struct w2c_env *, uint64_t);
void pg_files_init(const char *root);
u32 pg_file_io(struct w2c_env *,u32,u64,u64,u64,u64,bool,bool);
void PGMeshTouch(const void *start, uint64_t length);	// NativeMeshRelease.c: before a system call reads or writes engine memory
void pg_assets_configure(const char *,const char *);
const char *pg_assets_manifest_override(void); // the manifest with Mods applied, or NULL
#include "NativeAssetServer.h"
void pg_assets_prewarm(void);
void pg_threads_main(struct w2c_env *);
