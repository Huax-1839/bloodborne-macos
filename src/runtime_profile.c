// SPDX-License-Identifier: GPL-2.0-or-later
/* Guest program-counter sampler (diagnosis: does a guest thread spin or compute?).
 *
 *   BB_GUEST_PROFILE=<seconds>   off by default (no thread, no handler). Every <seconds> a report
 *                                of the hottest guest program counters goes to stdout.
 *   BB_GUEST_PROFILE_US=<us>     sampling period, default 1000 (minimum 50).
 *   BB_GUEST_PROFILE_ALL=1       round-robin over all live guest threads instead of "main" only.
 *
 * The host thread "bb:GuestProf" samples the target thread every period without signals (a signal
 * interrupts blocking calls the game depends on): thread_suspend, thread_get_state
 * (x86_THREAD_STATE64: under Rosetta the translated guest's x86 registers) for RIP/RBP/RSP, safe
 * reads of the return address from the RBP frame (as in probe.c's dump_frames) and of the word at
 * [RSP] when it points into the image (the return address when the thread sits in a frameless
 * leaf helper), thread_resume; the sample is aggregated after the resume. Report format (stdout):
 *
 *   Guest profile (<s> s, <n> samples, thread <name|all>): top RIPs
 *     <pct>% rip=image+0x<off> caller=image+0x<off> pause=<y|n> [rsp0=image+0x<off>] [thread=<name>] [sym=<name>]
 *     ...                                   (up to 25 lines, by count; exact RIPs, keyed with caller and rsp0)
 *     bytes image+0x<start>: <hex>          (top 8 distinct in-image RIPs, guest code [rip-48, rip+32),
 *                                            so the RIP is byte 48 of the dump)
 *     samples outside the guest image: <pct>%
 *
 * Addresses outside the image print as an absolute 0x<addr> (and sym=<symbol> from dladdr).
 * pause=y when the two bytes at rip or at rip-2 are F3 90 (x86 PAUSE). The histogram is reset
 * after every report. */
#define _GNU_SOURCE
#include "runtime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <dlfcn.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <sys/uio.h>
#include <mach/thread_act.h>
#include <mach/thread_status.h>

enum { TABLE=1<<16, MAX_THREADS=64, TOP_LINES=25, TOP_DUMPS=8, BEFORE=48, AFTER=32 };
typedef struct { uint64_t rip, caller, rsp0, tid; } Slot;
static uintptr_t image_lo, image_hi;
static pid_t self_pid;

static int read_safe(uintptr_t address, void *out, size_t size) {
    struct iovec local={out,size}, remote={(void *)address,size};
    return address && process_vm_readv(self_pid,&local,1,&remote,1,0)==(ssize_t)size;
}
/* One sample of a thread. Between suspend and resume only Mach calls run (no locks the target
 * could hold). Returns 0 when the thread's state could not be read. */
static int sample_thread(thread_t port, uint64_t tid, Slot *out) {
    if (thread_suspend(port)!=KERN_SUCCESS) return 0;
    x86_thread_state64_t state;
    mach_msg_type_number_t count=x86_THREAD_STATE64_COUNT;
    int ok=thread_get_state(port,x86_THREAD_STATE64,(thread_state_t)&state,&count)==KERN_SUCCESS;
    uintptr_t frame[2], caller=0, rsp0=0;
    if (ok) {
        const uintptr_t rbp=(uintptr_t)state.__rbp, rsp=(uintptr_t)state.__rsp;
        if ((rbp&7)==0 && read_safe(rbp,frame,sizeof(frame)) && frame[0]>rbp) caller=frame[1];
        if ((rsp&7)==0 && read_safe(rsp,&rsp0,sizeof(rsp0)) && !(rsp0>=image_lo && rsp0<image_hi)) rsp0=0;
    }
    thread_resume(port);
    if (!ok) return 0;
    *out=(Slot){(uint64_t)state.__rip,caller,rsp0,tid};
    return 1;
}

typedef struct { uint64_t rip, caller, rsp0, tid, count; } Entry;
typedef struct { uint64_t rip, count; } RipTotal;
typedef struct { uint64_t tid; char name[32]; } ThreadName;
static Entry *table;
static uint64_t table_used, total, dropped;
static ThreadName names[MAX_THREADS];
static size_t name_count;

static uint64_t hash(const Entry *e) {
    uint64_t h=e->rip*0x9E3779B97F4A7C15ull;
    h^=(e->caller+0x7F4A7C15ull)*0xC2B2AE3D27D4EB4Full; h^=h>>29;
    h^=(e->rsp0+0x165667B1ull)*0x9E3779B97F4A7C15ull; h^=h>>31;
    h^=e->tid*0xFF51AFD7ED558CCDull;
    return h^(h>>32);
}
static void add_sample(const Slot *s) {
    ++total;
    Entry key={s->rip,s->caller,s->rsp0,s->tid,0};
    for (uint64_t i=0,at=hash(&key);i<TABLE && table_used<=TABLE*3/4;++i) {
        Entry *e=&table[(at+i)%TABLE];
        if (!e->count) { *e=key; e->count=1; ++table_used; return; }
        if (e->rip==key.rip && e->caller==key.caller && e->rsp0==key.rsp0 && e->tid==key.tid) { ++e->count; return; }
    }
    ++dropped;
}
static int inside(uint64_t a) { return a>=image_lo && a<image_hi; }
/* "image+0x..." for guest image addresses, else the absolute address; "none" for 0. */
static void format_address(char *out, size_t size, uint64_t a) {
    if (!a) snprintf(out,size,"none");
    else if (inside(a)) snprintf(out,size,"image+0x%lx",(unsigned long)(a-image_lo));
    else snprintf(out,size,"0x%lx",(unsigned long)a);
}
static int has_pause(uint64_t rip) {
    unsigned char b[4];
    if (!inside(rip) || !read_safe((uintptr_t)rip-2,b,sizeof(b))) return 0;
    return (b[0]==0xF3 && b[1]==0x90) || (b[2]==0xF3 && b[3]==0x90);
}
static const char *thread_name(uint64_t tid) {
    for (size_t i=0;i<name_count;++i) if (names[i].tid==tid) return names[i].name;
    return "?";
}
static int by_count(const void *a, const void *b) {
    const uint64_t x=((const Entry *)a)->count, y=((const Entry *)b)->count;
    return x<y ? 1 : x>y ? -1 : 0;
}
static int by_total(const void *a, const void *b) {
    const uint64_t x=((const RipTotal *)a)->count, y=((const RipTotal *)b)->count;
    return x<y ? 1 : x>y ? -1 : 0;
}
static void report(double seconds, const char *target, int all) {
    Entry *rows=malloc(table_used*sizeof(*rows)+1);
    RipTotal *rips=malloc(table_used*sizeof(*rips)+1);
    if (!rows || !rips) { free(rows); free(rips); return; }
    size_t n=0, distinct=0;
    uint64_t outside=0;
    for (uint64_t i=0;i<TABLE;++i) if (table[i].count) rows[n++]=table[i];
    for (size_t i=0;i<n;++i) {
        if (!inside(rows[i].rip)) { outside+=rows[i].count; continue; }
        size_t j=0;
        while (j<distinct && rips[j].rip!=rows[i].rip) ++j;
        if (j==distinct) rips[distinct++]=(RipTotal){rows[i].rip,0};
        rips[j].count+=rows[i].count;
    }
    qsort(rows,n,sizeof(*rows),by_count);
    qsort(rips,distinct,sizeof(*rips),by_total);
    printf("Guest profile (%.1f s, %lu samples, thread %s): top RIPs\n",seconds,(unsigned long)total,target);
    for (size_t i=0;i<n && i<TOP_LINES;++i) {
        char rip[48], caller[48], rsp0[48], extra[160]="";
        format_address(rip,sizeof(rip),rows[i].rip); format_address(caller,sizeof(caller),rows[i].caller);
        size_t at=0;
        if (rows[i].rsp0) { format_address(rsp0,sizeof(rsp0),rows[i].rsp0); at+=(size_t)snprintf(extra+at,sizeof(extra)-at," rsp0=%s",rsp0); }
        if (all) at+=(size_t)snprintf(extra+at,sizeof(extra)-at," thread=%s",thread_name(rows[i].tid));
        Dl_info where;
        if (!inside(rows[i].rip) && dladdr((void *)(uintptr_t)rows[i].rip,&where) && where.dli_sname)
            snprintf(extra+at,sizeof(extra)-at," sym=%s",where.dli_sname);
        printf("  %.1f%% rip=%s caller=%s pause=%c%s\n",total ? 100.0*(double)rows[i].count/(double)total : 0.0,rip,caller,
               has_pause(rows[i].rip) ? 'y' : 'n',extra);
    }
    for (size_t i=0;i<distinct && i<TOP_DUMPS;++i) {
        unsigned char code[BEFORE+AFTER];
        const uint64_t start=rips[i].rip-BEFORE;
        if (!read_safe((uintptr_t)start,code,sizeof(code))) { printf("  bytes image+0x%lx: unreadable\n",(unsigned long)(start-image_lo)); continue; }
        char hex[sizeof(code)*2+1];
        for (size_t b=0;b<sizeof(code);++b) snprintf(hex+b*2,3,"%02x",code[b]);
        printf("  bytes image+0x%lx: %s\n",(unsigned long)(start-image_lo),hex);
    }
    printf("  samples outside the guest image: %.1f%%%s\n",total ? 100.0*(double)outside/(double)total : 0.0,
           dropped ? " (histogram full: some samples dropped)" : "");
    free(rows); free(rips);
}

static void *profiler_main(void *unused) {
    (void)unused;
    pthread_setname_np(pthread_self(),"bb:GuestProf");
    const char *seconds_text=getenv("BB_GUEST_PROFILE"), *us_text=getenv("BB_GUEST_PROFILE_US"), *all_text=getenv("BB_GUEST_PROFILE_ALL");
    const double interval=strtod(seconds_text,NULL);
    long period_us=us_text ? strtol(us_text,NULL,10) : 1000;
    if (period_us<50) period_us=us_text ? 50 : 1000;
    const int all=all_text && *all_text && strcmp(all_text,"0");
    table=calloc(TABLE,sizeof(*table));
    if (!table) return NULL;
    printf("Runtime: guest profile every %.1f s, sampling %s every %ld us\n",interval,all ? "all guest threads" : "thread main",period_us);
    uint64_t rotate=0;
    struct timespec start, next, now;
    clock_gettime(CLOCK_MONOTONIC,&start);
    next=start;
    for (;;) {
        uintptr_t hosts[MAX_THREADS]; uint64_t tids[MAX_THREADS]; char thread_names[MAX_THREADS][32];
        const size_t count=runtime_thread_guest_hosts(hosts,tids,thread_names,MAX_THREADS);
        name_count=0;
        for (size_t i=0;i<count;++i) { names[i].tid=tids[i]; snprintf(names[i].name,sizeof(names[i].name),"%s",thread_names[i]); ++name_count; }
        for (size_t i=0;i<count;++i)
            if (all ? i==rotate%count : !strcmp(thread_names[i],"main")) {
                Slot slot;
                if (hosts[i]!=(uintptr_t)pthread_self() && sample_thread(pthread_mach_thread_np((pthread_t)hosts[i]),tids[i],&slot)) add_sample(&slot);
            }
        ++rotate;
        next.tv_nsec+=period_us*1000L;
        while (next.tv_nsec>=1000000000L) { next.tv_nsec-=1000000000L; ++next.tv_sec; }
        clock_gettime(CLOCK_MONOTONIC,&now);
        const double elapsed=(double)(now.tv_sec-start.tv_sec)+(double)(now.tv_nsec-start.tv_nsec)*1e-9;
        if (elapsed>=interval) {
            report(elapsed,all ? "all" : "main",all);
            memset(table,0,TABLE*sizeof(*table));
            table_used=total=dropped=0;
            start=now; next=now;
            continue;
        }
        const long sleep_ns=(next.tv_sec-now.tv_sec)*1000000000L+(next.tv_nsec-now.tv_nsec);
        if (sleep_ns>0) { struct timespec t={sleep_ns/1000000000L,sleep_ns%1000000000L}; nanosleep(&t,NULL); }
        else next=now; /* fell behind: no burst of catch-up samples */
    }
    return NULL;
}

void runtime_profile_start(const void *image, size_t size) {
    static int started;
    const char *seconds=getenv("BB_GUEST_PROFILE");
    if (started || !seconds || !*seconds || strtod(seconds,NULL)<=0) return;
    started=1;
    image_lo=(uintptr_t)image; image_hi=image_lo+size;
    self_pid=getpid();
    pthread_t thread;
    if (pthread_create(&thread,NULL,profiler_main,NULL)) { fputs("Runtime: BB_GUEST_PROFILE: cannot start the profiler thread\n",stderr); return; }
    pthread_detach(thread);
}
#else /* Mach thread sampling only */
void runtime_profile_start(const void *image, size_t size) { (void)image; (void)size; }
#endif
