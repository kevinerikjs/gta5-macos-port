// Exercise real protected-page read/write faults and the platform fault context.
// Run twice: PG_MESH_RELEASE=1 and PG_MESH_RELEASE=2.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static uint8_t *memory;
static uint64_t capacity;
const uint8_t *pg_engine_memory(uint64_t *size) { *size = capacity; return memory; }
uint64_t pg_engine_memory_capacity(void) { return capacity; }
void pg_log(const char *line) { puts(line); }
void pg_mesh_source(uint32_t, uint64_t, uint32_t, uint64_t);
uint32_t PGMeshRelease(uint32_t, const uint8_t *, uint32_t, uint64_t *, uint32_t *, uint32_t *);
void PGMeshForget(uint64_t, uint32_t, int);
void PGMeshReleaseStats(uint64_t *, uint64_t *, uint64_t *, uint64_t *, uint64_t *, uint64_t *, uint64_t *, uint64_t *, uint64_t *);

int main(void) {
    const size_t page = (size_t)getpagesize();
    capacity = page * 3;
    memory = mmap(NULL, capacity, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(memory != MAP_FAILED);
    uint32_t vertexBinding = 1;
    memcpy(memory + 8, &vertexBinding, sizeof vertexBinding);
    memset(memory + page, 0x5a, page * 2);
    uint8_t *uploaded = malloc(page * 2);
    assert(uploaded);
    memcpy(uploaded, memory + page, page * 2);
    int orphan = getenv("PG_MESH_RELEASE") && !strcmp(getenv("PG_MESH_RELEASE"), "2");
    for (unsigned i = 0; i < 2; ++i) {
        pg_mesh_source(i + 1, page * (i + 1), (uint32_t)page, 0);
        uint64_t first = 0; uint32_t count = 0, offset = 0;
        assert(PGMeshRelease(i + 1, uploaded + page * i, (uint32_t)page, &first, &count, &offset) == 1);
        assert(count == 1 && offset == 0);
        if (orphan) PGMeshForget(first, count, 1);
    }
    volatile uint8_t *readPage = memory + page;
    volatile uint8_t *writePage = memory + page * 2;
    uint8_t value = readPage[0]; // actual read fault
    if (!orphan) assert(value == 0x5a);
    writePage[0] = 0x71; // actual write fault
    assert(writePage[0] == 0x71);
    if (!orphan) assert(writePage[1] == 0x5a);
    uint64_t released, faults, forgets, touches, mismatches, pageSize, orphans, writes, reads;
    PGMeshReleaseStats(&released, &faults, &forgets, &touches, &mismatches, &pageSize, &orphans, &writes, &reads);
    assert(released == 2 && mismatches == 0 && pageSize == page);
    if (orphan) assert(orphans == 2 && reads == 1 && writes == 1);
    else assert(faults == 2);
    puts("PASS: protected mesh pages handle read and write faults correctly.");
    return 0;
}
