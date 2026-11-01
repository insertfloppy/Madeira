#!/usr/bin/env python3
"""A controller turned on mid-game is announced with WM_DEVICECHANGE (ml2190); no Wine runs.

SDL2, GLFW, Unreal Engine and DirectInput games enumerate controllers once and
look again only on WM_DEVICECHANGE, which a Madeira session (no PlugPlay
service) never sent. build/win32u-unix/driver_ios.c ios_pad_hotplug_poll
compares the connected XInput slots at message polls and has each thread send
its own windows the arrival / removal and DBT_DEVNODES_CHANGED. Compiles the
production code with stubs and checks:
  - nothing is announced for slots already connected at a thread's first poll;
  - a slot that connects later: DBT_DEVICEARRIVAL with a HID and an XUSB
    device interface to the thread's top-level and message-only windows,
    then DBT_DEVNODES_CHANGED to its top-level windows only;
  - other threads' windows get nothing from this thread; each thread
    announces the change once, at its own poll;
  - removal sends DBT_DEVICEREMOVECOMPLETE;
  - polls without QS_SENDMESSAGE (GetAsyncKeyState) deliver nothing;
  - the slots are sampled at most every 250 ms;
  - MADEIRA_PAD_HOTPLUG=0 turns it off;
and textually that every message poll passes through it.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
driver = (root / 'build/win32u-unix/driver_ios.c').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


events = function(driver, 'static BOOL winios_drv_process_events( DWORD mask )')
assert 'ios_pad_hotplug_poll( mask );' in events
assert driver.index('static void ios_pad_hotplug_poll( DWORD mask );') < driver.index('static BOOL winios_drv_process_events( DWORD mask )')
start = driver.index('static unsigned int ios_pad_hotplug_mask')
body = driver[start:driver.index('\n}\n', driver.index('static void ios_pad_hotplug_poll( DWORD mask )\n{')) + 3]
print('PASS: every message poll passes through ios_pad_hotplug_poll')

harness = r'''
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <time.h>
typedef int BOOL; typedef unsigned int DWORD; typedef unsigned int UINT; typedef void *HWND;
typedef unsigned short WCHAR; typedef unsigned char BYTE; typedef unsigned long WPARAM; typedef long LPARAM; typedef long LRESULT;
typedef struct { unsigned int Data1; unsigned short Data2, Data3; unsigned char Data4[8]; } GUID;
typedef struct { DWORD dbch_size, dbch_devicetype, dbch_reserved; } DEV_BROADCAST_HDR;
typedef struct { DWORD dbcc_size, dbcc_devicetype, dbcc_reserved; GUID dbcc_classguid; WCHAR dbcc_name[1]; } DEV_BROADCAST_DEVICEINTERFACE_W;
#define TRUE 1
#define FALSE 0
#define FIELD_OFFSET(t, f) offsetof(t, f)
#define WM_DEVICECHANGE 0x0219
#define DBT_DEVNODES_CHANGED 0x0007
#define DBT_DEVICEARRIVAL 0x8000
#define DBT_DEVICEREMOVECOMPLETE 0x8004
#define DBT_DEVTYP_DEVICEINTERFACE 5
#define QS_SENDMESSAGE 0x0040
#define QS_ALLINPUT 0x04ff
#define QS_INPUT 0x0407
#define WINIOS_GAMEPAD_MAX 4
#define FAIL(...) do { fprintf(stderr, __VA_ARGS__); exit(1); } while (0)
#define dprintf(fd, ...) fprintf(stderr, __VA_ARGS__)

static unsigned int connected, samples;
static long long clock_ns;
static __thread DWORD current_tid;
#define MSG_PARENT ((HWND)0x100)
/* top-level: 0x10 (tid 1), 0x20 (tid 2); message-only: 0x30 (tid 1) */
struct sent { HWND hwnd; DWORD tid; WPARAM wp; int kind; int size; char name[160]; };
static struct sent sent[64]; static int nsent;
static pthread_mutex_t sent_lock = PTHREAD_MUTEX_INITIALIZER;

static int winios_gamepad_get_state( int index, void *out ) { (void)out; if (index == 0) samples++; return (connected >> index) & 1; }
static DWORD GetCurrentThreadId(void) { return current_tid; }
static DWORD GetCurrentProcessId(void) { return 0x24; }
static HWND get_hwnd_message_parent(void) { return MSG_PARENT; }
static BOOL is_window( HWND h ) { return h != 0; }
static DWORD get_window_thread( HWND h, DWORD *pid ) { (void)pid; return h == (HWND)0x20 ? 2 : 1; }
static HWND *list_window_children( HWND parent )
{
    HWND *l = calloc( 4, sizeof(HWND) );
    if (parent == MSG_PARENT) l[0] = (HWND)0x30;
    else { l[0] = (HWND)0x10; l[1] = (HWND)0x20; }
    return l;
}
static LRESULT send_message( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    struct sent *s;
    if (msg != WM_DEVICECHANGE) FAIL( "sent message %#x\n", msg );
    if (get_window_thread( hwnd, NULL ) != current_tid) FAIL( "sent to another thread's window %p\n", hwnd );
    pthread_mutex_lock( &sent_lock );
    s = &sent[nsent++];
    memset( s, 0, sizeof(*s) );
    s->hwnd = hwnd; s->tid = current_tid; s->wp = wp; s->kind = -1;
    if (wp & 0x8000)
    {
        const DEV_BROADCAST_DEVICEINTERFACE_W *d = (const void *)lp;
        int i;
        if (d->dbcc_devicetype != DBT_DEVTYP_DEVICEINTERFACE) FAIL( "devicetype %u\n", d->dbcc_devicetype );
        s->kind = d->dbcc_classguid.Data1 == 0x4d1e55b2 ? 0 : d->dbcc_classguid.Data1 == 0xec87f1e3 ? 1 : 9;
        s->size = d->dbcc_size;
        for (i = 0; d->dbcc_name[i] && i < 159; i++) s->name[i] = (char)d->dbcc_name[i];
        if ((int)(offsetof(DEV_BROADCAST_DEVICEINTERFACE_W, dbcc_name) + (i + 1) * sizeof(WCHAR)) != s->size)
            FAIL( "dbcc_size %d for a %d-character name\n", s->size, i );
    }
    else if (lp) FAIL( "DBT_DEVNODES_CHANGED with lParam\n" );
    pthread_mutex_unlock( &sent_lock );
    return 1;
}
static int fake_clock_gettime( clockid_t id, struct timespec *ts )
{
    (void)id; ts->tv_sec = clock_ns / 1000000000LL; ts->tv_nsec = clock_ns % 1000000000LL; return 0;
}
#define clock_gettime fake_clock_gettime
''' + body + r'''
/* One long-lived second thread: each run_thread2() lets it make one poll. */
#include <semaphore.h>
static sem_t go2, done2;
static void *thread2( void *arg )
{
    current_tid = 2;
    for (;;) { sem_wait( &go2 ); ios_pad_hotplug_poll( QS_ALLINPUT ); sem_post( &done2 ); }
    return arg;
}
static void run_thread2(void)
{
    static pthread_t t;
    if (!t) { sem_init( &go2, 0, 0 ); sem_init( &done2, 0, 0 ); pthread_create( &t, NULL, thread2, NULL ); }
    sem_post( &go2 ); sem_wait( &done2 );
}
static int count( HWND h, WPARAM wp, int kind )
{
    int i, n = 0;
    for (i = 0; i < nsent; i++) if (sent[i].hwnd == h && sent[i].wp == wp && (kind < 0 || sent[i].kind == kind)) n++;
    return n;
}

int main(void)
{
    int i;
    current_tid = 1;
    clock_ns = 5000000000LL;
    connected = 0x2;                    /* player 2 already on */
    ios_pad_hotplug_poll( QS_ALLINPUT );
    run_thread2();
    if (nsent) FAIL( "announced a pad that was already connected\n" );

    connected = 0x3;                    /* player 1 turned on mid-game */
    clock_ns += 100000000LL;
    ios_pad_hotplug_poll( QS_ALLINPUT );
    if (nsent) FAIL( "sampled again within 250 ms\n" );
    clock_ns += 200000000LL;
    ios_pad_hotplug_poll( QS_INPUT );
    if (nsent) FAIL( "delivered from a poll without QS_SENDMESSAGE\n" );
    ios_pad_hotplug_poll( QS_ALLINPUT );
    if (count( (HWND)0x10, DBT_DEVICEARRIVAL, 0 ) != 1 || count( (HWND)0x10, DBT_DEVICEARRIVAL, 1 ) != 1)
        FAIL( "top-level window: no HID + XUSB arrival\n" );
    if (count( (HWND)0x30, DBT_DEVICEARRIVAL, 0 ) != 1 || count( (HWND)0x30, DBT_DEVICEARRIVAL, 1 ) != 1)
        FAIL( "message-only window (SDL2): no HID + XUSB arrival\n" );
    if (count( (HWND)0x10, DBT_DEVNODES_CHANGED, -1 ) != 1) FAIL( "top-level window: no DBT_DEVNODES_CHANGED\n" );
    if (count( (HWND)0x30, DBT_DEVNODES_CHANGED, -1 )) FAIL( "message-only window got DBT_DEVNODES_CHANGED\n" );
    if (count( (HWND)0x20, DBT_DEVICEARRIVAL, -1 ) || count( (HWND)0x20, DBT_DEVNODES_CHANGED, -1 ))
        FAIL( "thread 1 announced to thread 2's window\n" );
    for (i = 0; i < nsent; i++)
        if (sent[i].wp == DBT_DEVICEARRIVAL && !strstr( sent[i].name, "madeira-pad0" )) FAIL( "arrival names %s, not slot 0\n", sent[i].name );
    if (!strstr( sent[0].name, "IG_" ) && !strstr( sent[1].name, "IG_" )) FAIL( "HID path lacks IG_\n" );
    if (nsent != 5) FAIL( "%d messages from thread 1, expected 5\n", nsent );
    ios_pad_hotplug_poll( QS_ALLINPUT );
    if (nsent != 5) FAIL( "announced twice\n" );
    run_thread2();                      /* thread 2 announces at its own poll */
    if (count( (HWND)0x20, DBT_DEVICEARRIVAL, -1 ) != 2 || count( (HWND)0x20, DBT_DEVNODES_CHANGED, -1 ) != 1)
        FAIL( "thread 2 did not announce to its window\n" );
    nsent = 0;

    connected = 0x2;                    /* player 1 off */
    clock_ns += 300000000LL;
    ios_pad_hotplug_poll( QS_ALLINPUT );
    if (count( (HWND)0x10, DBT_DEVICEREMOVECOMPLETE, -1 ) != 2 || count( (HWND)0x30, DBT_DEVICEREMOVECOMPLETE, -1 ) != 2 ||
        count( (HWND)0x10, DBT_DEVNODES_CHANGED, -1 ) != 1 || count( (HWND)0x10, DBT_DEVICEARRIVAL, -1 ))
        FAIL( "removal not announced\n" );
    puts( "PASS: arrival/removal reach the thread's own top-level and message-only windows, once, at most every 250 ms" );
    return 0;
}
'''

off_harness = harness.replace('int main(void)\n{', 'int main_on(void)\n{', 1) + r'''
int main(void)
{
    setenv( "MADEIRA_PAD_HOTPLUG", "0", 1 );
    current_tid = 1; clock_ns = 5000000000LL; connected = 0;
    ios_pad_hotplug_poll( QS_ALLINPUT );
    connected = 1; clock_ns += 1000000000LL;
    ios_pad_hotplug_poll( QS_ALLINPUT );
    if (nsent || samples) FAIL( "MADEIRA_PAD_HOTPLUG=0 still announced or sampled\n" );
    puts( "PASS: MADEIRA_PAD_HOTPLUG=0 turns it off" );
    return 0;
}
'''

cc = os.environ.get('CC') or shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
with tempfile.TemporaryDirectory() as tmp:
    for name, src in (('on', harness), ('off', off_harness)):
        c = Path(tmp) / f'{name}.c'
        exe = Path(tmp) / name
        c.write_text(src)
        subprocess.run([cc, '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function', '-pthread', str(c), '-o', str(exe)], check=True)
        out = subprocess.run([str(exe)], capture_output=True, text=True)
        if out.returncode: raise SystemExit(f"FAIL ({name}): " + out.stderr.strip())
        print(out.stdout.strip())
