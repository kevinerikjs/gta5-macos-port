// Mesh release (GTA-152, PG_MESH_RELEASE=1): the engine keeps its own copy of every vertex and index buffer
// after the renderer has copied it into a Metal buffer (measured with PG_TRACE_HELD: 94% of mesh bytes, about
// 75-135 MB at a 2.1 GB limit). Those engine pages are handed back to iOS and protected; the Metal buffer, which
// the CPU can read (shared storage), holds the same bytes. The game still reads some meshes on the CPU
// (grcVertexBufferEditor, grcIndexBuffer::LockRO: vehicle glass, for example), so any access to a released page
// faults, and the handler below copies the page back from the Metal buffer and lets the access go on.
//
// 1. Scripts/prepare_mesh_release.py: wasm_null_d3d::NullDevice::CreateBuffer calls pg_mesh_source with the
//    buffer's object id and its source range after it has written the upload into the command ring.
// 2. The renderer, after it copied that upload into the Metal buffer, calls PGMeshRelease. Each page fully inside
//    the source is made read-only and compared with the Metal copy; only identical pages are released. A page the
//    engine wrote meanwhile (memory reused, an object id taken again) differs and stays.
// 3. Before the Metal buffer goes away (destroyed, or renamed because the game rewrote it) PGMeshForget puts the
//    bytes back, so the engine's memory is exactly as it was.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <mach/vm_page_size.h>
#include <os/lock.h>

extern const uint8_t *pg_engine_memory(uint64_t *size);	// EngineHost.c
extern uint64_t pg_engine_memory_capacity(void);
extern void pg_log(const char *line);

// A page's state. RELEASED and ORPHANED pages are protected; an ORPHANED page's buffer is gone (PG_MESH_RELEASE=2:
// a destroyed mesh's pages stay handed back, empty, instead of getting the old bytes again).
enum { NORMAL, PENDING, DISCARDING, RELEASED, RESTORING, ORPHANED };
static _Atomic uint8_t *state;		// per engine page
static uint8_t **copy;				// per released page: the same bytes in the Metal buffer
static uint8_t *base;
static uint64_t capacity, pageSize;
static int enabled = -1, mode;
static struct sigaction oldBus, oldSegv;
static _Atomic uint64_t releasedPages, restoredByFault, restoredByForget, mismatches, orphaned, orphanWrites, orphanReads;

// Object id → source range, from the engine thread to the renderer thread. A stale or reused entry is harmless:
// the renderer only releases pages whose bytes equal the Metal buffer's.
#define SOURCES 8192u
static struct { uint32_t oid; uint32_t size; uint64_t src; } sources[SOURCES];
static os_unfair_lock sourceLock = OS_UNFAIR_LOCK_INIT;

static void spin(void) { __asm__ volatile("yield"); }

// Puts one released page back (any thread, also inside the fault handler): only syscalls and memcpy. `faulted`:
// the caller is the fault handler, so a PENDING page is read-only and was written to.
static void restore(uint64_t page, _Atomic uint64_t *counter, int faulted) {
	for (;;) {
		uint8_t s = atomic_load(&state[page]);
		if (s == NORMAL) return;
		if (s == RELEASED) {
			uint8_t expected = RELEASED;
			if (!atomic_compare_exchange_strong(&state[page], &expected, RESTORING)) continue;
			uint8_t *at = base + page * pageSize;
			mprotect(at, pageSize, PROT_READ | PROT_WRITE);
			madvise(at, pageSize, MADV_FREE_REUSE);
			memcpy(at, copy[page], pageSize);
			atomic_store(&state[page], NORMAL);
			atomic_fetch_add(counter, 1);
			return;
		}
		if (s == ORPHANED) {		// handed back for good: the page comes back empty
			uint8_t expected = ORPHANED;
			if (!atomic_compare_exchange_strong(&state[page], &expected, RESTORING)) continue;
			uint8_t *at = base + page * pageSize;
			mprotect(at, pageSize, PROT_READ | PROT_WRITE);
			madvise(at, pageSize, MADV_FREE_REUSE);
			atomic_store(&state[page], NORMAL);
			atomic_fetch_add(faulted == 2 ? &orphanReads : &orphanWrites, 1);
			return;
		}
		if (s == PENDING && faulted) {		// read-only while the renderer compares it: the bytes are intact
			uint8_t expected = PENDING;
			if (atomic_compare_exchange_strong(&state[page], &expected, NORMAL)) { mprotect(base + page * pageSize, pageSize, PROT_READ | PROT_WRITE); return; }
			continue;
		}
		spin();		// PENDING (not from a fault), DISCARDING or RESTORING: the other thread finishes in a moment
	}
}

// Engine memory is read-write except for released pages, so a fault inside it is one: put the page back and let
// the access run again. A page already NORMAL was put back by another thread between the fault and here; the
// access just runs again. Only a fault that keeps coming back on a NORMAL page (a bug) goes on to the old handler.
static _Thread_local uintptr_t lastFault; static _Thread_local unsigned repeats;
static void fault(int sig, siginfo_t *info, void *context) {
	uintptr_t at = (uintptr_t)info->si_addr;
	if (state && at >= (uintptr_t)base && at < (uintptr_t)base + capacity) {
		uint64_t page = (at - (uintptr_t)base) / pageSize;
		// The data abort's WnR bit tells a read (2) from a write (1): reading an orphaned page means something
		// still used the dead mesh's bytes, which mode 2 can't give back.
		int read = !((((ucontext_t *)context)->uc_mcontext->__es.__esr >> 6) & 1);
		if (atomic_load(&state[page]) != NORMAL) { repeats = 0; restore(page, &restoredByFault, read ? 2 : 1); return; }
		if (at != lastFault) { lastFault = at; repeats = 0; }
		if (++repeats < 1000) return;
	}
	struct sigaction *old = sig == SIGBUS ? &oldBus : &oldSegv;
	if ((old->sa_flags & SA_SIGINFO) && old->sa_sigaction) { old->sa_sigaction(sig, info, context); return; }
	if (old->sa_handler == SIG_IGN) return;
	if (old->sa_handler && old->sa_handler != SIG_DFL) { old->sa_handler(sig); return; }
	sigaction(sig, old, NULL);		// a real crash: the access repeats and the default action follows
}

static int debugged(void) {
	struct kinfo_proc info = {0}; size_t size = sizeof info; int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
	return sysctl(mib, 4, &info, &size, NULL, 0) == 0 && (info.kp_proc.p_flag & P_TRACED);
}

static int on(void) {
	if (enabled >= 0) return enabled;
	const char *v = getenv("PG_MESH_RELEASE");
	enabled = 0;
	if (!v || (strcmp(v, "1") && strcmp(v, "2"))) return 0;
	mode = atoi(v);
	// A debugger stops at every protected-page access (EXC_BAD_ACCESS) before the handler sees it.
	if (debugged()) { pg_log("Mesh release: off under a debugger."); return 0; }
	uint64_t size; base = (uint8_t *)pg_engine_memory(&size);
	pageSize = vm_page_size;
	capacity = pg_engine_memory_capacity();		// the whole reservation: the engine's memory grows into it
	uint64_t pages = capacity / pageSize;
	state = (_Atomic uint8_t *)mmap(NULL, pages, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	copy = (uint8_t **)mmap(NULL, pages * sizeof *copy, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	if (!base || state == MAP_FAILED || copy == MAP_FAILED) { state = NULL; pg_log("Mesh release: off (no table)."); return 0; }
	struct sigaction handler = {0};
	handler.sa_sigaction = fault; handler.sa_flags = SA_SIGINFO | SA_ONSTACK; sigemptyset(&handler.sa_mask);
	sigaction(SIGBUS, &handler, &oldBus); sigaction(SIGSEGV, &handler, &oldSegv);
	pg_log(mode == 2 ? "Mesh release: on, destroyed meshes stay handed back (GTA-152)." : "Mesh release: on (GTA-152).");
	return enabled = 1;
}

// Engine thread, from CreateBuffer: `desc` is the D3D11_BUFFER_DESC (Usage +4, BindFlags +8, CPUAccessFlags +12,
// MiscFlags +16). Only plain vertex and index buffers the CPU can't map, and at least one whole page.
void pg_mesh_source(uint32_t oid, uint64_t src, uint32_t size, uint64_t desc) {
	if (!on() || size < pageSize || desc + 20 > capacity || src + size > capacity) return;
	uint32_t usage, bind, cpu, misc;
	memcpy(&usage, base + desc + 4, 4); memcpy(&bind, base + desc + 8, 4); memcpy(&cpu, base + desc + 12, 4); memcpy(&misc, base + desc + 16, 4);
	if (usage > 1 || cpu || misc || !(bind & 3) || (bind & ~3u)) return;		// DEFAULT or IMMUTABLE; VB (1) / IB (2) only
	os_unfair_lock_lock(&sourceLock);
	uint32_t slot = (oid * 2654435761u) % SOURCES;
	sources[slot].oid = oid; sources[slot].size = size; sources[slot].src = src;
	os_unfair_lock_unlock(&sourceLock);
}

// Renderer thread, after an upload of `oid` filled its Metal buffer (`contents`, the buffer's `bytes`). Returns
// the number of pages released; the renderer remembers the range for PGMeshForget.
uint32_t PGMeshRelease(uint32_t oid, const uint8_t *contents, uint32_t bytes, uint64_t *firstPage, uint32_t *pageCount, uint32_t *pageOffset) {
	if (enabled != 1) return 0;
	os_unfair_lock_lock(&sourceLock);
	uint32_t slot = (oid * 2654435761u) % SOURCES;
	uint64_t src = sources[slot].oid == oid ? sources[slot].src : 0; uint32_t size = sources[slot].oid == oid ? sources[slot].size : 0;
	if (sources[slot].oid == oid) sources[slot].oid = 0;
	os_unfair_lock_unlock(&sourceLock);
	if (!size || size > bytes) return 0;
	uint64_t first = (src + pageSize - 1) / pageSize, end = (src + size) / pageSize;
	if (end <= first) return 0;
	uint32_t released = 0;
	for (uint64_t page = first; page < end; page++) {
		uint8_t *at = base + page * pageSize;
		const uint8_t *same = contents + (page * pageSize - src);
		uint8_t expected = NORMAL;
		if (!atomic_compare_exchange_strong(&state[page], &expected, PENDING)) continue;	// already another buffer's
		mprotect(at, pageSize, PROT_READ);
		if (memcmp(at, same, pageSize)) {
			expected = PENDING;
			if (atomic_compare_exchange_strong(&state[page], &expected, NORMAL)) mprotect(at, pageSize, PROT_READ | PROT_WRITE);
			atomic_fetch_add(&mismatches, 1);
			continue;
		}
		expected = PENDING;
		if (!atomic_compare_exchange_strong(&state[page], &expected, DISCARDING)) continue;	// the engine touched it
		copy[page] = (uint8_t *)same;
		mprotect(at, pageSize, PROT_NONE);		// first: once handed back, a read would see zeros without a fault
		madvise(at, pageSize, MADV_FREE_REUSABLE);
		atomic_store(&state[page], RELEASED);
		released++;
	}
	atomic_fetch_add(&releasedPages, released);
	*firstPage = first; *pageCount = (uint32_t)(end - first); *pageOffset = (uint32_t)(first * pageSize - src);
	return released;
}

// Renderer thread, before the Metal buffer that holds these pages' bytes goes away (`gone`: destroyed, not
// rewritten). Mode 2 leaves a destroyed buffer's pages handed back: the engine freed that mesh with it.
void PGMeshForget(uint64_t firstPage, uint32_t pageCount, int gone) {
	if (enabled != 1) return;
	for (uint64_t page = firstPage; page < firstPage + pageCount; page++) {
		uint8_t expected = RELEASED;
		if (gone && mode == 2 && atomic_compare_exchange_strong(&state[page], &expected, ORPHANED)) { atomic_fetch_add(&orphaned, 1); continue; }
		restore(page, &restoredByForget, 0);
	}
}

// Host code that hands engine memory to a system call (pread into it, write from it) calls this first: the kernel
// doesn't fault on a protected page, the call fails with EFAULT. Memory the engine freed and reused for a new read
// can still be released until the renderer has seen the old buffer's destroy.
static _Atomic uint64_t restoredByTouch;
void PGMeshTouch(const void *start, uint64_t length) {
	if (enabled != 1 || !length) return;
	uintptr_t a = (uintptr_t)start, b = (uintptr_t)base;
	if (a >= b + capacity || a + length <= b) return;
	uint64_t first = a > b ? (a - b) / pageSize : 0, last = (a + length - 1 - b) / pageSize;
	if (last >= capacity / pageSize) last = capacity / pageSize - 1;
	for (uint64_t page = first; page <= last; page++) if (atomic_load(&state[page]) != NORMAL) restore(page, &restoredByTouch, 0);
}

// For the renderer's periodic report.
void PGMeshReleaseStats(uint64_t *released, uint64_t *byFault, uint64_t *byForget, uint64_t *byTouch, uint64_t *mismatched, uint64_t *page,
                        uint64_t *orphanedPages, uint64_t *orphanWritten, uint64_t *orphanRead) {
	*released = atomic_load(&releasedPages); *byFault = atomic_load(&restoredByFault); *byForget = atomic_load(&restoredByForget); *byTouch = atomic_load(&restoredByTouch);
	*orphanedPages = atomic_load(&orphaned); *orphanWritten = atomic_load(&orphanWrites); *orphanRead = atomic_load(&orphanReads);
	*mismatched = atomic_load(&mismatches); *page = pageSize;
}
int PGMeshReleaseOn(void) { return enabled == 1; }
