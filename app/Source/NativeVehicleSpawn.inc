// Settings › Cheats › Spawn vehicle. Included by EngineHost.c. The list comes from the running
// engine's model registry, so it has exactly the vehicles this game build (and its DLC) has; no
// vehicle list ships with the app. Everything that touches the engine runs on the game thread during
// the "main" script's turn (pg_cheats_menu_tick, from pg_asi_script_tick): creating vehicles from
// the controller thread raced the engine walking its vehicle pool and crashed after some spawns.
// Layouts are pinned to 8b0b5899ed (prepare.py checks game.wasm's SHA-256):
// GetModelInfoFromLocalIndex reads the pool's capacity at 10872120; a model stores its name hash at
// +24 and its type at +157, and vehicle models have type 5.
u64 PG_FN_MODEL_INFO_AT_INDEX(w2c_game*, u32);
u32 PG_FN_IS_VEHICLE_MODEL(w2c_game*, u32);
u64 PG_FN_HASH_STRING_TRY_GET(w2c_game*, u32, u32);
u32 PG_FN_VEHICLE_CLASS(w2c_game*, u32);
u64 PG_FN_VEHICLE_LABEL(w2c_game*, u32);
u32 PG_FN_VEHICLE_SEATS(w2c_game*, u32);
void PG_FN_REQUEST_MODEL(w2c_game*, u32);
void PG_FN_RELEASE_MODEL(w2c_game*, u32);
u32 PG_FN_HAS_MODEL_LOADED(w2c_game*, u32);
void PG_FN_GET_ENTITY_COORDS(w2c_game*, u64, u32, u32);
f32 PG_FN_GET_ENTITY_HEADING(w2c_game*, u32);
u32 PG_FN_CREATE_VEHICLE(w2c_game*, u32, u64, f32, u32, u32, u32);
void PG_FN_SET_PED_INTO_VEHICLE(w2c_game*, u32, u32, u32);
u32 PG_FN_GROUND_VEHICLE(w2c_game*, u32, f32);
u32 PG_FN_ENTITY_EXISTS(w2c_game*, u32);
u32 PG_FN_ENTITY_OWNED(w2c_game*, u32, u32);
void PG_FN_DELETE_VEHICLE(w2c_game*, u64);
u32 PG_FN_VEHICLE_OCCUPANT(w2c_game*, u32, u32, u32);
u64 PG_FN_CURRENT_SCRIPT_HANDLER(w2c_game*);

// Vehicle classes with their own handling here (GET_VEHICLE_CLASS_FROM_NAME).
enum { PG_CLASS_BOAT = 14, PG_CLASS_HELICOPTER = 15, PG_CLASS_PLANE = 16, PG_CLASS_TRAIN = 21 };

// The menu keeps owning what it spawned until it deletes it. "No longer needed" alone leaves nearby
// vehicles (and their streamed models) alive, so repeated spawns grew memory without bound.
static u32 menuVehicles[2];
static u64 menuVehicleOwner;
static bool pg_vehicle_make_room(w2c_game *instance, u64 scratch, u64 owner) {
  if (menuVehicleOwner != owner) {
    memset(menuVehicles, 0, sizeof menuVehicles);
    menuVehicleOwner = owner; // A new main script: the old one cleaned up its own vehicles.
  }
  for (int i = 0; i < 2; i++) {
    u32 vehicle = menuVehicles[i];
    if (vehicle && (!PG_FN_ENTITY_EXISTS(instance, vehicle) || !PG_FN_ENTITY_OWNED(instance, vehicle, 0)))
      menuVehicles[i] = 0; // Never take a vehicle back from a mission that took it over.
  }
  if (!menuVehicles[0] || !menuVehicles[1]) return true;
  for (int i = 0; i < 2; i++) {
    bool occupied = false;
    // This build has 16 seats per vehicle; also counts anyone getting in.
    for (int seat = -1; seat < 15; seat++)
      if (PG_FN_VEHICLE_OCCUPANT(instance, menuVehicles[i], (u32)seat, 1)) { occupied = true; break; }
    if (occupied) continue;
    u32 vehicle = menuVehicles[i];
    *(u32 *)pg_pointer(&env, scratch, 4) = vehicle;
    PG_FN_DELETE_VEHICLE(instance, scratch);
    // DELETE_VEHICLE clears its argument even when it fails in this build, so ask the game instead.
    if (PG_FN_ENTITY_EXISTS(instance, vehicle)) continue;
    menuVehicles[i] = 0;
    pg_log("Vehicle menu: removed an older empty menu vehicle before loading another.");
    return true;
  }
  return false;
}
static bool pg_vehicle_memory_available(void) {
  uint64_t headroom;
  return !nativeProcessHeadroom(&headroom) || headroom >= guardReserve();
}
// The name the game shows for a vehicle, in the game's language: its display-name label
// (GET_DISPLAY_NAME_FROM_VEHICLE_MODEL, "ADDER") looked up in the game's text with _GET_LABEL_TEXT,
// the lookup script mods use. Empty when the game has no text for it.
static void pg_vehicle_display_name(w2c_game *instance, uint32_t model, char *out, size_t size) {
  out[0] = 0;
  const u64 label = PG_FN_VEHICLE_LABEL(instance, model);
  if (!label) return;
  const uint64_t argument[1] = {label};
  const u64 text = pg_test_call(instance, 0x7b5280eba9840c72ull, 1, argument);
  if (!text || text == (u64)-1) return;
  const char *words = pg_string(&env, text);
  if (!words[0] || !strcmp(words, "NULL")) return;
  // Cut a long name at a whole character: Japanese, Korean, Chinese and Russian letters take several bytes.
  size_t n = strlen(words);
  if (n >= size) { n = size - 1; while (n && ((uint8_t)words[n] & 0xC0) == 0x80) n--; }
  memcpy(out, words, n); out[n] = 0;
}

static pthread_mutex_t vehicleMenuLock = PTHREAD_MUTEX_INITIALIZER;
static PGVehicleEntry *vehicleCatalog;
static int32_t vehicleCatalogCount = -1;
static bool vehicleCatalogRequested = true; // Read the list during play, before Settings pauses the scripts.
static PGVehicleSpawnStatus vehicleSpawnStatus;
static uint32_t vehicleSpawnModel;
static bool vehicleSpawnEnter;
static double vehicleSpawnQueuedAt;

void PGRequestVehicleCatalog(void) {
  pthread_mutex_lock(&vehicleMenuLock);
  if (vehicleCatalogCount <= 0) { vehicleCatalogRequested = true; vehicleCatalogCount = -1; }
  pthread_mutex_unlock(&vehicleMenuLock);
}
int32_t PGVehicleCatalogCount(void) {
  pthread_mutex_lock(&vehicleMenuLock);
  int32_t count = vehicleCatalogCount;
  pthread_mutex_unlock(&vehicleMenuLock);
  return count;
}
bool PGVehicleCatalogEntryAt(uint32_t index, PGVehicleEntry *entry) {
  pthread_mutex_lock(&vehicleMenuLock);
  bool valid = entry && vehicleCatalogCount > 0 && index < (uint32_t)vehicleCatalogCount;
  if (valid) *entry = vehicleCatalog[index];
  pthread_mutex_unlock(&vehicleMenuLock);
  return valid;
}
bool PGSpawnVehicle(uint32_t model, bool enterVehicle) {
  pthread_mutex_lock(&vehicleMenuLock);
  bool accepted = model && vehicleSpawnStatus != PGVehicleSpawnWaiting && vehicleSpawnStatus != PGVehicleSpawnLoading;
  if (accepted) {
    vehicleSpawnModel = model; vehicleSpawnEnter = enterVehicle;
    vehicleSpawnQueuedAt = timeMS(CLOCK_MONOTONIC);
    vehicleSpawnStatus = PGVehicleSpawnWaiting;
  }
  pthread_mutex_unlock(&vehicleMenuLock);
  return accepted;
}
PGVehicleSpawnStatus PGGetVehicleSpawnStatus(void) {
  pthread_mutex_lock(&vehicleMenuLock);
  PGVehicleSpawnStatus status = vehicleSpawnStatus;
  pthread_mutex_unlock(&vehicleMenuLock);
  return status;
}
static void pg_vehicle_spawn_status(PGVehicleSpawnStatus status) {
  pthread_mutex_lock(&vehicleMenuLock);
  vehicleSpawnStatus = status;
  pthread_mutex_unlock(&vehicleMenuLock);
}
static void pg_vehicle_catalog_tick(w2c_game *instance) {
  static PGVehicleEntry *building;
  static uint32_t index, capacity, count;
  pthread_mutex_lock(&vehicleMenuLock);
  bool requested = vehicleCatalogRequested;
  pthread_mutex_unlock(&vehicleMenuLock);
  if (!requested || (PGGameStatus() & 16)) return;
  if (!building) {
    capacity = *(uint32_t *)pg_pointer(&env, 10872120, 4);
    if (!capacity) return;
    // Model indices are 16-bit: a larger capacity means the layout isn't the pinned one.
    if (capacity <= 65536) building = calloc(capacity, sizeof *building);
    if (!building) {
      pthread_mutex_lock(&vehicleMenuLock);
      vehicleCatalogCount = -2; vehicleCatalogRequested = false;
      pthread_mutex_unlock(&vehicleMenuLock);
      return;
    }
    index = count = 0;
  }
  // 512 models per frame, so reading the list doesn't stall a frame. Nothing is loaded to list it.
  uint32_t end = index + 512 < capacity ? index + 512 : capacity;
  for (; index < end; index++) {
    u64 info = PG_FN_MODEL_INFO_AT_INDEX(instance, index);
    if (!info || (*(uint8_t *)pg_pointer(&env, info + 157, 1) & 31) != 5) continue;
    uint32_t hash = *(uint32_t *)pg_pointer(&env, info + 24, 4);
    if (!hash || !PG_FN_IS_VEHICLE_MODEL(instance, hash)) continue;
    // Trains are left out: a single carriage spawned off its route can't be used.
    uint32_t vehicleClass = PG_FN_VEHICLE_CLASS(instance, hash);
    if (vehicleClass == PG_CLASS_TRAIN) continue;
    bool duplicate = false;
    for (uint32_t i = 0; i < count; i++) if (building[i].model == hash) { duplicate = true; break; }
    if (duplicate) continue;
    PGVehicleEntry *entry = &building[count++];
    entry->model = hash;
    entry->vehicleClass = vehicleClass;
    u64 name = PG_FN_HASH_STRING_TRY_GET(instance, 0, hash);
    if (name) snprintf(entry->name, sizeof entry->name, "%s", pg_string(&env, name));
    if (!entry->name[0]) snprintf(entry->name, sizeof entry->name, "0x%08X", hash);
    pg_vehicle_display_name(instance, hash, entry->label, sizeof entry->label);
  }
  if (index < capacity) return;
  // The model pool holds every object in the world; keep only the much smaller vehicle list.
  if (count) {
    PGVehicleEntry *compact = realloc(building, count * sizeof *building);
    if (compact) building = compact;
  } else { free(building); building = NULL; }
  pthread_mutex_lock(&vehicleMenuLock);
  free(vehicleCatalog); vehicleCatalog = building; building = NULL;
  vehicleCatalogCount = (int32_t)count; vehicleCatalogRequested = false;
  pthread_mutex_unlock(&vehicleMenuLock);
  char line[96]; snprintf(line, sizeof line, "Vehicle menu: found %u vehicle models.", count); pg_log(line);
}
u32 PG_FN_STREAM_VIRTUAL_SIZE(w2c_game*, u64, u32, u32);
u32 PG_FN_STREAM_PHYSICAL_SIZE(w2c_game*, u64, u32);
u64 PG_FN_STREAM_OBJECT_NAME(w2c_game*, u32);
// A spawn still loading after 10 s (GTA-151): what the engine is waiting for. Big add-on cars sat at "waiting for the
// game" until the 30 s timeout with nothing in the log; this names every object still requested or loading, with the
// memory it needs, so a player log shows which file of the pack is stuck and how big it is.
static void pg_vehicle_log_waiting(w2c_game *instance) {
  uint64_t size, base; uint32_t count;
  const uint8_t *m = pg_engine_memory(&size);
  if (!m || size < 11607316) return;
  memcpy(&base, m + 11607304, 8); memcpy(&count, m + 11607312, 4);
  int logged = 0;
  for (uint32_t i = 0; i < count && logged < 12 && base + i * 16ull + 16 <= size; i++) {
    const int status = m[base + i * 16ull + 4] & 3;		// 2 requested, 3 loading (NativeStreamingHealth.c)
    if (status != 2 && status != 3) continue;
    const u64 info = base + i * 16ull;
    const u32 virt = PG_FN_STREAM_VIRTUAL_SIZE(instance, info, i, 0), phys = PG_FN_STREAM_PHYSICAL_SIZE(instance, info, i);
    const u64 name = PG_FN_STREAM_OBJECT_NAME(instance, i);
    char line[200];
    snprintf(line, sizeof line, "Vehicle menu: still waiting for %s (%s; %u KB, %u KB of it graphics).", name ? pg_string(&env, name) : "?",
             status == 3 ? "loading" : "requested", (virt + phys) >> 10, phys >> 10);
    pg_log(line); logged++;
  }
  if (!logged) pg_log("Vehicle menu: still waiting, but the game has nothing requested or loading.");
  // The model's own files (cbr1000rrr.yft, cbr1000rrr.ytd, cbr1000rrr_hi.yft...): their state and size, also when the
  // engine refused them and nothing is waiting ("Request failed for ... requesting dependency ... failed").
  char model[64] = "";		// its model name, from the menu's list
  pthread_mutex_lock(&vehicleMenuLock);
  for (int32_t c = 0; c < vehicleCatalogCount; c++) if (vehicleCatalog[c].model == vehicleSpawnModel) { snprintf(model, sizeof model, "%s", vehicleCatalog[c].name); break; }
  pthread_mutex_unlock(&vehicleMenuLock);
  const size_t length = strlen(model);
  for (uint32_t i = 0; length && i < count && base + i * 16ull + 16 <= size; i++) {
    const u64 name = PG_FN_STREAM_OBJECT_NAME(instance, i);
    const char *text = name ? pg_string(&env, name) : NULL;
    if (!text || strncasecmp(text, model, length) || (text[length] && text[length] != '.' && text[length] != '_')) continue;
    const u64 info = base + i * 16ull;
    const u32 virt = PG_FN_STREAM_VIRTUAL_SIZE(instance, info, i, 0), phys = PG_FN_STREAM_PHYSICAL_SIZE(instance, info, i);
    static const char *const states[] = {"not loaded", "loaded", "requested", "loading"};
    char line[200];
    snprintf(line, sizeof line, "Vehicle menu: %s is object %u, %s (%u KB, %u KB of it graphics).", text, i, states[m[info + 4] & 3], (virt + phys) >> 10, phys >> 10);
    pg_log(line);
  }
}
static void pg_vehicle_menu_step(w2c_game *instance, u64 vector) {
  pg_vehicle_catalog_tick(instance);
  static double began;
  static bool requested;
  static u64 requestOwner;
  pthread_mutex_lock(&vehicleMenuLock);
  PGVehicleSpawnStatus status = vehicleSpawnStatus;
  uint32_t model = vehicleSpawnModel;
  bool enter = vehicleSpawnEnter;
  double queuedAt = vehicleSpawnQueuedAt;
  pthread_mutex_unlock(&vehicleMenuLock);
  if (status != PGVehicleSpawnWaiting && status != PGVehicleSpawnLoading) { began = 0; return; }
  double now = timeMS(CLOCK_MONOTONIC);
  if (!began) { began = queuedAt; requested = false; }
  // Counted from when it was asked for: scripts may not run at all while paused, and a spawn asked
  // for long ago must not suddenly appear when play resumes.
  if (!requested && now - began >= 10000) {
    began = 0; pg_vehicle_spawn_status(PGVehicleSpawnNotReady); return;
  }
  // Settings closes the pause menu; wait for the game to really be playing again.
  bool ready = !PGPauseMenuActive() && PGGameStatus() == 0 && PGLoadSceneSeconds() == 0;
  if (!requested && !ready) return;
  u64 previous = pg_asi_enter_script(instance);
  u64 active = *(u64 *)pg_pointer(&env, instance->w2c_g1 + 3088, 8);
  u64 owner = active ? PG_FN_CURRENT_SCRIPT_HANDLER(instance) : 0;
  if (!owner || (requested && owner != requestOwner)) {
    // Never release a model through another script's handler: the main script that asked for it
    // releases its own requests when it ends.
    pg_asi_leave_script(instance, previous);
    began = 0; requested = false;
    pg_log("Vehicle menu: the main script ended or changed; spawn cancelled.");
    pg_vehicle_spawn_status(PGVehicleSpawnNotReady); return;
  }
  PGVehicleSpawnStatus result = PGVehicleSpawnLoading;
  if (!requested) {
    if (!PG_FN_IS_VEHICLE_MODEL(instance, model) || PG_FN_VEHICLE_CLASS(instance, model) == PG_CLASS_TRAIN) result = PGVehicleSpawnUnavailable;
    else if (!pg_vehicle_make_room(instance, vector, owner)) result = PGVehicleSpawnVehicleLimit;
    else if (!pg_vehicle_memory_available()) result = PGVehicleSpawnLowMemory;
    else {
      pg_log("Vehicle menu: loading the model.");
      PG_FN_REQUEST_MODEL(instance, model); requested = true; requestOwner = owner; began = now;
      pg_vehicle_spawn_status(PGVehicleSpawnLoading);
    }
  }
  static bool waitLogged;
  if (!requested) waitLogged = false;
  if (requested && !waitLogged && now - began > 10000) { waitLogged = true; pg_vehicle_log_waiting(instance); }
  if (requested) {
    if (!ready) result = PGVehicleSpawnNotReady;
    else if (now - began > 30000) result = PGVehicleSpawnTimedOut;
    else if (!pg_vehicle_memory_available()) result = PGVehicleSpawnLowMemory;
    else if (PG_FN_HAS_MODEL_LOADED(instance, model)) {
      const u32 ped = PG_FN_PLAYER_PED_ID(instance);
      if (!vector || !ped) result = PGVehicleSpawnNotReady;
      else {
        PG_FN_GET_ENTITY_COORDS(instance, vector, ped, 1);
        float *v = pg_pointer(&env, vector, 24);
        float heading = PG_FN_GET_ENTITY_HEADING(instance, ped);
        uint32_t category = PG_FN_VEHICLE_CLASS(instance, model);
        // Aircraft are wider, so they go further ahead.
        float distance = (category == PG_CLASS_HELICOPTER || category == PG_CLASS_PLANE) ? 20.0f : 8.0f;
        float angle = heading * 0.017453292519943295f;
        v[0] -= sinf(angle) * distance; v[2] += cosf(angle) * distance; v[4] += 0.5f;
        pg_log("Vehicle menu: model loaded; creating the vehicle.");
        u32 vehicle = PG_FN_CREATE_VEHICLE(instance, model, vector, heading, 0, 0, 1);
        result = vehicle ? PGVehicleSpawnSucceeded : PGVehicleSpawnFailed;
        if (vehicle) {
          // Boats keep the height they were created at (on the water).
          if (category != PG_CLASS_BOAT) PG_FN_GROUND_VEHICLE(instance, vehicle, 5.0f);
          if (enter && PG_FN_VEHICLE_SEATS(instance, model) > 0) PG_FN_SET_PED_INTO_VEHICLE(instance, ped, vehicle, (u32)-1);
          // Oldest first; room was made before the model was requested.
          if (!menuVehicles[0]) menuVehicles[0] = menuVehicles[1];
          menuVehicles[1] = vehicle;
        }
      }
    }
  }
  if (result != PGVehicleSpawnLoading && requested) PG_FN_RELEASE_MODEL(instance, model);
  pg_asi_leave_script(instance, previous);
  if (result != PGVehicleSpawnLoading) {
    char line[128]; snprintf(line, sizeof line, "Vehicle menu: model 0x%08x finished with status %d.", model, result); pg_log(line);
    began = 0; requested = false;
    pg_vehicle_spawn_status(result);
  }
}

static void pg_vehicle_menu_tick(w2c_game *instance) {
  // Engine calls can poll input while they work, which could run this again: never spawn twice.
  static bool ticking;
  if (ticking) return;
  ticking = true;
  // The game commands' arguments go on this thread's own engine stack: a buffer kept from an
  // earlier frame could outlive a script or world reset.
  u64 stack = instance->w2c_g0;
  instance->w2c_g0 -= 32;
  pg_vehicle_menu_step(instance, instance->w2c_g0);
  instance->w2c_g0 = stack;
  ticking = false;
}

// Settings › Cheats, once per frame on the game thread, in the "main" script's turn
// (pg_asi_script_tick): spawns, one-off actions, and keeping God mode and Never wanted on.
static void pg_cheats_menu_tick(w2c_game *instance) {
  pg_vehicle_menu_tick(instance);
  pg_native_cheats_tick(instance);
}
