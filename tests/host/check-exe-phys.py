#!/usr/bin/env python3
"""exe-phys-mb: reported physical memory for named programs only (build/ntdll-unix/virtual_ios.c).

Ubisoft Connect on build 58 (2026-10-31): upc.exe, its Chromium browser process, started six
renderers beside its two services and three Chromium helpers and ran out of 4 GB windows
("BOOT FAILED at stage 'guest-window-reserve'"); its CEF setup ignores
--renderer-process-limit. Chromium keeps at most physical MB / 2 / 60 renderers (at least 3),
so `exe-phys-mb = upc.exe:479` caps it at three.

Compiles the production ios_exe_phys_bytes against a fake PEB and config and checks: only the
named program (last path component, any case, either slash) gets the figure; several entries
and spaces work; a value outside 64..65536 MB or an unset key reports nothing; a different
game's lines are read again (MADEIRA_CFG_GAME). Also checks textually that the total
(virtual_get_system_info) and the available memory (ios_avail_phys) both use it, and that the
guest-window registry holds ten entries.
"""
import subprocess, sys, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text().replace('\r\n', '\n')
a = src.index('static unsigned long long ios_exe_phys_bytes( void )')
b = src.index('\n}\n', a) + 3
fn = src[a:b]

assert '#define IOS_WOW_MAX_WINDOWS 10' in src, 'ten guest-window registry entries'
avail = src[src.index('unsigned long long ios_avail_phys( unsigned long long host_free )'):]
avail = avail[:avail.index('\n}\n')]
assert 'ios_exe_phys_bytes()' in avail and 'value > own' in avail, 'available memory never above the total told'
total = src[src.index('/* exe-phys-mb (ios_exe_phys_bytes): this program alone is told N MB */'):][:900]
assert 'info->MmHighestPhysicalPage = max( 1, own / page_size );' in total, 'total physical memory told'

prog = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef uint16_t WCHAR;
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { UNICODE_STRING ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
static PEB cur_peb; static RTL_USER_PROCESS_PARAMETERS cur_pp; static WCHAR buf[260];
static void *ios_jit_current_peb(void) { return &cur_peb; }
static const char *cfg_value; static int cfg_reads;
static int madeira_cfg_get(const char *k, char *o, size_t c)
{ cfg_reads++; if (!cfg_value || strcmp(k, "exe-phys-mb")) return 0; snprintf(o, c, "%s", cfg_value); return 1; }
#define dprintf(fd, ...) fprintf(stderr, __VA_ARGS__)
''' + fn + r'''
static void exe(const char *p)
{ size_t i, n = strlen(p); for (i = 0; i < n; i++) buf[i] = (WCHAR)p[i];
  cur_pp.ImagePathName.Buffer = buf; cur_pp.ImagePathName.Length = (unsigned short)(n * 2); cur_peb.ProcessParameters = &cur_pp; }
#define CHECK(c, m) do { if (!(c)) { printf("FAIL: %s\n", m); return 1; } } while (0)
int main(void)
{
    setenv("MADEIRA_CFG_GAME", "ubisoft", 1);
    cfg_value = "upc.exe:479; Battle.net.exe:600";
    exe("C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\upc.exe");
    CHECK(ios_exe_phys_bytes() == 479ull << 20, "upc.exe gets 479 MB");
    exe("C:/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UPC.EXE");
    CHECK(ios_exe_phys_bytes() == 479ull << 20, "any case, forward slashes");
    exe("C:\\Program Files (x86)\\Battle.net\\Battle.net.exe");
    CHECK(ios_exe_phys_bytes() == 600ull << 20, "second entry after a space");
    exe("C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\UplayWebCore.exe");
    CHECK(ios_exe_phys_bytes() == 0, "a program not named keeps the real figure");
    exe("C:\\x\\xupc.exe");
    CHECK(ios_exe_phys_bytes() == 0, "names match whole");
    CHECK(cfg_reads == 1, "read once per game");
    cfg_value = "upc.exe:32";
    setenv("MADEIRA_CFG_GAME", "other", 1);
    exe("C:\\u\\upc.exe");
    CHECK(ios_exe_phys_bytes() == 0 && cfg_reads == 2, "re-read for another game; below 64 MB ignored");
    cfg_value = NULL;
    setenv("MADEIRA_CFG_GAME", "third", 1);
    CHECK(ios_exe_phys_bytes() == 0, "unset key");
    printf("PASS: exe-phys-mb reports N MB only to the named programs, per game; total and available both use it; 10 window entries\n");
    return 0;
}
'''
with tempfile.TemporaryDirectory() as d:
    c = Path(d) / 't.c'; c.write_text(prog)
    exe = Path(d) / 't'
    r = subprocess.run(['cc', '-std=gnu11', '-Wall', '-fsanitize=address,undefined', '-o', str(exe), str(c)],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stderr); sys.exit(1)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    print(r.stdout.strip() or r.stderr)
    sys.exit(r.returncode)
