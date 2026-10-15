/* bbport (macOS): the heap for host objects the game sees (thread handles and TLS, mutexes,
 * condition variables, semaphores, rwlocks, TLS blocks). PS4 code packs such pointers into
 * 40 bits; on Linux the non-PIE brk heap keeps them low, while macOS's malloc places its
 * regions near 0x7f0000000000. runtime.h routes the runtime's malloc family here.
 *
 * Size classes with free lists in one arena below the PS4 user range; larger blocks are
 * rounded to pages and reused by exact size. Pointers from elsewhere (strdup, the system's
 * libraries) are passed to the system's free and realloc. */
#ifdef __APPLE__
#define BB_LOW_HEAP_IMPL
#include "runtime.h"
#include <errno.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define ARENA_BASE UINT64_C(0xe00000000)
#define ARENA_SIZE (UINT64_C(4) << 30)
#define HEADER 16u
#define LARGE (64u * 1024)
#define PAGE_BYTES 4096u
#define MAGIC UINT32_C(0x4c4f5748)

typedef struct { uint32_t magic, back; uint64_t size; } Header; /* size: the block's capacity */
typedef struct Free { struct Free *next; uint64_t size; } Free;

static const uint32_t classes[] = {16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048,
                                   3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, LARGE};
#define CLASSES (sizeof(classes) / sizeof(*classes))
static Free *lists[CLASSES], *large;
static unsigned char *arena, *arena_next, *arena_end;
static os_unfair_lock heap_lock = OS_UNFAIR_LOCK_INIT;

static int arena_ready(void) {
    if (arena) return 1;
    void *p = mmap((void *)ARENA_BASE, ARENA_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return 0;
    if ((uintptr_t)p + ARENA_SIZE > UINT64_C(1) << 40) {
        munmap(p, ARENA_SIZE);
        fputs("STOP: no address space below 1 TiB for the runtime heap\n", stderr);
        exit(21);
    }
    arena = arena_next = p;
    arena_end = arena + ARENA_SIZE;
    return 1;
}
static int owned(const void *p) { return arena && (const unsigned char *)p >= arena && (const unsigned char *)p < arena_end; }
static unsigned class_of(uint64_t size) {
    unsigned c = 0;
    while (c < CLASSES - 1 && classes[c] < size) ++c;
    return c;
}
/* A block of at least `size` bytes (header included), lock held. */
static void *take(uint64_t size, uint64_t *capacity) {
    if (size <= LARGE) {
        const unsigned c = class_of(size);
        *capacity = classes[c];
        if (lists[c]) { Free *f = lists[c]; lists[c] = f->next; return f; }
    } else {
        size = (size + PAGE_BYTES - 1) & ~(uint64_t)(PAGE_BYTES - 1);
        *capacity = size;
        for (Free **f = &large; *f; f = &(*f)->next)
            if ((*f)->size == size) { Free *found = *f; *f = found->next; return found; }
    }
    if ((uint64_t)(arena_end - arena_next) < *capacity) return NULL;
    void *p = arena_next;
    arena_next += *capacity;
    return p;
}
void *runtime_low_aligned_alloc(size_t alignment, size_t size) {
    if (alignment < HEADER) alignment = HEADER;
    if (alignment & (alignment - 1)) { errno = EINVAL; return NULL; }
    os_unfair_lock_lock(&heap_lock);
    if (!arena_ready()) { os_unfair_lock_unlock(&heap_lock); errno = ENOMEM; return NULL; }
    uint64_t capacity;
    unsigned char *block = take((uint64_t)size + HEADER + (alignment > HEADER ? alignment : 0), &capacity);
    os_unfair_lock_unlock(&heap_lock);
    if (!block) { errno = ENOMEM; return NULL; }
    uintptr_t payload = ((uintptr_t)block + HEADER + alignment - 1) & ~(uintptr_t)(alignment - 1);
    Header *h = (Header *)(payload - HEADER);
    h->magic = MAGIC;
    h->back = (uint32_t)((uintptr_t)h - (uintptr_t)block);
    h->size = capacity;
    return (void *)payload;
}
void *runtime_low_malloc(size_t size) { return runtime_low_aligned_alloc(HEADER, size); }
void *runtime_low_calloc(size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) { errno = ENOMEM; return NULL; }
    void *p = runtime_low_malloc(count * size);
    if (p) memset(p, 0, count * size);
    return p;
}
static Header *header_of(void *p) {
    Header *h = (Header *)((unsigned char *)p - HEADER);
    if (h->magic != MAGIC) { fprintf(stderr, "STOP: runtime heap: bad block %p\n", p); abort(); }
    return h;
}
void runtime_low_free(void *p) {
    if (!p) return;
    if (!owned(p)) { free(p); return; }
    Header *h = header_of(p);
    unsigned char *block = (unsigned char *)h - h->back;
    const uint64_t capacity = h->size;
    h->magic = 0;
    Free *f = (Free *)block;
    f->size = capacity;
    os_unfair_lock_lock(&heap_lock);
    if (capacity <= LARGE) { const unsigned c = class_of(capacity); f->next = lists[c]; lists[c] = f; }
    else { f->next = large; large = f; }
    os_unfair_lock_unlock(&heap_lock);
}
void *runtime_low_realloc(void *p, size_t size) {
    if (!p) return runtime_low_malloc(size);
    if (!owned(p)) return realloc(p, size);
    Header *h = header_of(p);
    const uint64_t room = h->size - h->back - HEADER;
    if (size <= room) return p;
    void *q = runtime_low_malloc(size);
    if (!q) return NULL;
    memcpy(q, p, room);
    runtime_low_free(p);
    return q;
}
char *runtime_low_strdup(const char *s) {
    const size_t n = strlen(s) + 1;
    char *p = runtime_low_malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}
#endif
