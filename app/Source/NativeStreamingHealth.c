// Streaming health for the Health line (GTA-116): how long the engine's streaming requests (textures,
// models, map data) wait before they are loaded, how many are still waiting, and how many it unloads.
//
// Scripts/prepare_streaming_health.py calls these from the engine's rage::strStreamingInfoManager:
// RequestObject → pg_stream_requested, SetObjectToLoaded → pg_stream_loaded, RemoveObject →
// pg_stream_removed. The engine also "requests" objects that are already loaded, to keep them; those
// are skipped by reading the object's status, and an entry leaves the table once its object is no
// longer requested or loading, so "waiting" counts real waits only.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <os/lock.h>

#define SLOTS 16384u		// power of two; requests beyond three quarters of it are counted but not timed
#define SLOW_MS 10000u
extern const uint8_t *pg_engine_memory(uint64_t *size);	// EngineHost.c

// strStreamingInfoManager's object table: a pointer at 11607304 and a count at 11607312, 16 bytes per
// object, its status in the low 2 bits of byte 4: 0 not loaded, 1 loaded, 2 requested, 3 loading.
enum { NOT_LOADED, LOADED, REQUESTED, LOADING, UNKNOWN };
static int status(uint32_t index) {
	uint64_t size, base;
	uint32_t count;
	const uint8_t *m = pg_engine_memory(&size);
	if (!m || size < 11607316) return UNKNOWN;
	memcpy(&base, m + 11607304, 8);
	memcpy(&count, m + 11607312, 4);
	if (index >= count || base + index * 16ull + 16 > size) return UNKNOWN;
	return m[base + index * 16ull + 4] & 3;
}
static struct { uint32_t key, ms; } table[SLOTS];	// key = engine index + 1 (0 = empty), ms = when requested
static uint32_t used, loadedCount, removedCount, waits[512], waitCount;
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;

static uint32_t nowMS(void) { return (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000); }
static uint32_t home(uint32_t key) { return (key * 2654435761u) >> 18; }

// Linear probing. Erasing shifts the following entries back, so a lookup never stops at a hole.
static int lookup(uint32_t key) {
	for (uint32_t i = home(key), n = 0; n < SLOTS; i = (i + 1) & (SLOTS - 1), n++) {
		if (!table[i].key) return -1;
		if (table[i].key == key) return (int)i;
	}
	return -1;
}
static void erase(uint32_t i) {
	table[i].key = 0;
	used--;
	for (uint32_t j = (i + 1) & (SLOTS - 1); table[j].key; j = (j + 1) & (SLOTS - 1)) {
		if (((j - home(table[j].key)) & (SLOTS - 1)) >= ((j - i) & (SLOTS - 1))) {
			table[i] = table[j];
			table[j].key = 0;
			i = j;
		}
	}
}

void pg_stream_requested(uint32_t index) {
	if (status(index) == LOADED) return;	// kept, not loaded again
	uint32_t key = index + 1, now = nowMS();
	os_unfair_lock_lock(&lock);
	if (used < SLOTS / 4 * 3) {
		uint32_t i = home(key);
		while (table[i].key && table[i].key != key) i = (i + 1) & (SLOTS - 1);
		if (!table[i].key) { table[i].key = key; table[i].ms = now; used++; }
	}
	os_unfair_lock_unlock(&lock);
}

// Trace (PG_TRACE_STREAM_LOADS, GTA-148): loads per object, to find what streams in again and again; the engine
// thread names the most-loaded ones every ~10 s (EngineHost.c pg_trace_stream_loads).
static struct { uint32_t key, count; } loads[8192];
static int traceLoads = -1;
static void countLoad(uint32_t index) {
	if (traceLoads < 0) traceLoads = getenv("PG_TRACE_STREAM_LOADS") != NULL;
	if (!traceLoads) return;
	uint32_t key = index + 1;
	for (uint32_t i = (key * 2654435761u) >> 19, n = 0; n < 8192; i = (i + 1) & 8191, n++) {
		if (loads[i].key == key) { loads[i].count++; return; }
		if (!loads[i].key) { loads[i].key = key; loads[i].count = 1; return; }
	}
}
// The `max` most-loaded objects since the last call (index, count), most first; resets the counts.
int PGStreamTopLoads(uint32_t *index, uint32_t *count, int max) {
	int n = 0;
	os_unfair_lock_lock(&lock);
	for (uint32_t i = 0; i < 8192; i++) {
		if (!loads[i].key) continue;
		const uint32_t c = loads[i].count;
		int at;
		if (n < max) at = n++;			// room left: goes at the end, then moves up
		else if (c > count[max - 1]) at = max - 1;	// beats the smallest kept: replaces it
		else continue;
		while (at > 0 && count[at - 1] < c) { index[at] = index[at - 1]; count[at] = count[at - 1]; at--; }
		index[at] = loads[i].key - 1; count[at] = c;
	}
	memset(loads, 0, sizeof loads);
	os_unfair_lock_unlock(&lock);
	return n;
}

// When each object last finished loading, for pg_may_evict (GTA-148). One slot per index modulo the table (a
// collision only forgets an older load time, which makes that object evictable as before).
static uint32_t loadedAt[65536];
static int protectMS = -1;
// Forced eviction (the memory guard below its reserve) took objects the engine had loaded moments ago and
// needed again at once: the same map pieces and weapon models loaded 50-270 times every 10 s, 95% of all
// reading was repeats, and the ground stayed grey (4 GB phones). An object loaded in the last
// PG_EVICT_PROTECT_MS (0 = off, the default; the app sets 4000 on the smallest memory limits, GraphicsOptions.swift)
// counts as in use for DeleteNextLeastUsedObject (Scripts/prepare_evict_protect.py): stale objects still go,
// nothing bounces in and out. Alone it starves new loads; with Lite's closer detail it doesn't.
uint32_t pg_may_evict(uint32_t index) {
	if (protectMS < 0) { const char *v = getenv("PG_EVICT_PROTECT_MS"); protectMS = v ? atoi(v) : 0; }
	if (protectMS <= 0) return 1;
	const uint32_t at = loadedAt[index & 65535];
	return !at || nowMS() - at >= (uint32_t)protectMS;
}

void pg_stream_loaded(uint32_t index) {
	uint32_t now = nowMS();
	loadedAt[index & 65535] = now ? now : 1;
	os_unfair_lock_lock(&lock);
	countLoad(index);
	int i = lookup(index + 1);
	if (i >= 0) {
		waits[waitCount < 512 ? waitCount : loadedCount % 512] = now - table[i].ms;
		if (waitCount < 512) waitCount++;
		erase((uint32_t)i);
	}
	loadedCount++;
	os_unfair_lock_unlock(&lock);
}

void pg_stream_removed(uint32_t index) {
	os_unfair_lock_lock(&lock);
	int i = lookup(index + 1);
	if (i >= 0) erase((uint32_t)i);
	removedCount++;
	os_unfair_lock_unlock(&lock);
}

static int byValue(const void *a, const void *b) {
	uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
	return x < y ? -1 : x > y;
}

// Since the last call: out = {waiting now, of those waiting over 10 s, loaded, median wait ms,
// 95th-percentile wait ms, unloaded}.
void PGStreamingHealth(uint64_t out[6]) {
	uint32_t now = nowMS(), waiting = 0, slow = 0, done[1024], doneCount = 0;
	os_unfair_lock_lock(&lock);
	for (uint32_t i = 0; i < SLOTS; i++) {
		if (!table[i].key) continue;
		int state = status(table[i].key - 1);
		if (state != REQUESTED && state != LOADING && state != UNKNOWN) {	// loaded another way, or cancelled
			if (doneCount < 1024) done[doneCount++] = table[i].key;
			continue;
		}
		waiting++;
		if (now - table[i].ms > SLOW_MS) slow++;
	}
	for (uint32_t k = 0; k < doneCount; k++) { int i = lookup(done[k]); if (i >= 0) erase((uint32_t)i); }
	qsort(waits, waitCount, sizeof waits[0], byValue);
	out[0] = waiting;
	out[1] = slow;
	out[2] = loadedCount;
	out[3] = waitCount ? waits[waitCount / 2] : 0;
	out[4] = waitCount ? waits[waitCount * 95 / 100] : 0;
	out[5] = removedCount;
	loadedCount = removedCount = waitCount = 0;
	os_unfair_lock_unlock(&lock);
}
