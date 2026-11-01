#!/usr/bin/env python3
"""An x64 program's read of a system32 DLL opens the sysx64 file (opt-in).

build/wine-patches/0019 adds ios_sysx64_file_name to wine/dlls/ntdll/unix/file.c:
with env MADEIRA_SYSX64_FILE=1, NtCreateFile in an x64 process opens
C:\\windows\\sysx64\\<name>.dll instead of system32\\<name>.dll when the open only
reads an existing file. Black Ops III reads system32\\ntdll.dll for its x64
syscall stubs; the pure ARM64 file there has none. This check applies the
wine patches that touch file.c to a copy of the submodule's file, compiles the
region between the sysx64-file-test markers on the host with stubs for its
Wine neighbours, and checks:
  - CreateFileW-style reads of system32\\ntdll.dll and kernel32.dll (any case)
    get the sysx64 name, with the rest of the path kept;
  - the loader's own open shape keeps its name, except for ntdll.dll;
  - writes, creates, directories, open-by-id, subfolders of system32, non-DLL
    files, files sysx64 lacks, a root directory handle and a non-x64 process
    keep their name;
  - without MADEIRA_SYSX64_FILE=1 nothing changes.

Needs python3, git, a C compiler (CC) and the wine submodule checked out.
"""
import os, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
PATCHES = sorted((ROOT / "build/wine-patches").glob("*.patch"))
SRC = ROOT / "wine/dlls/ntdll/unix/file.c"

failures = []


def check(what, cond):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


if not SRC.exists():
    print("SKIP: wine submodule not checked out, 0019 not checked")
    sys.exit(0)
if not CC:
    sys.exit("no C compiler (set CC)")

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef uint16_t WCHAR;
typedef unsigned short USHORT;
typedef unsigned int ULONG, ACCESS_MASK;
typedef int BOOL;
typedef int NTSTATUS;
typedef void *HANDLE;
#define TRUE 1
#define FALSE 0
#define MAX_PATH 260
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
typedef struct { USHORT Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { ULONG Length; HANDLE RootDirectory; UNICODE_STRING *ObjectName; ULONG Attributes; } OBJECT_ATTRIBUTES;
typedef struct { int dummy; } FILE_BASIC_INFORMATION;
#define GENERIC_READ 0x80000000u
#define GENERIC_WRITE 0x40000000u
#define GENERIC_EXECUTE 0x20000000u
#define GENERIC_ALL 0x10000000u
#define MAXIMUM_ALLOWED 0x02000000u
#define DELETE 0x00010000u
#define WRITE_DAC 0x00040000u
#define WRITE_OWNER 0x00080000u
#define SYNCHRONIZE 0x00100000u
#define FILE_READ_DATA 0x1u
#define FILE_WRITE_DATA 0x2u
#define FILE_APPEND_DATA 0x4u
#define FILE_WRITE_EA 0x10u
#define FILE_READ_ATTRIBUTES 0x80u
#define FILE_WRITE_ATTRIBUTES 0x100u
#define FILE_SHARE_READ 1u
#define FILE_SHARE_WRITE 2u
#define FILE_SHARE_DELETE 4u
#define FILE_OPEN 1u
#define FILE_CREATE 2u
#define FILE_OPEN_IF 3u
#define FILE_DIRECTORY_FILE 0x1u
#define FILE_SYNCHRONOUS_IO_NONALERT 0x20u
#define FILE_NON_DIRECTORY_FILE 0x40u
#define FILE_DELETE_ON_CLOSE 0x1000u
#define FILE_OPEN_BY_FILE_ID 0x2000u

static int x64_process = 1;
int ios_is_arm64ec_cur(void) { return x64_process; }

static char buf[4][600];
static int bufi;
static const char *narrow( const UNICODE_STRING *us )
{
    char *b = buf[bufi++ & 3];
    int i, n = us->Length / 2;
    for (i = 0; i < n && i < 599; i++) b[i] = (char)us->Buffer[i];
    b[i] = 0;
    return b;
}
#define debugstr_us narrow

/* sysx64 has these */
static const char *const present[] = { "\\??\\C:\\windows\\sysx64\\ntdll.dll", "\\??\\C:\\windows\\sysx64\\kernel32.dll",
                                       "\\??\\C:\\Windows\\sysx64\\NTDLL.DLL", "\\??\\C:\\windows\\sysx64\\KERNEL32.dll" };
static int queries;
NTSTATUS NtQueryAttributesFile( const OBJECT_ATTRIBUTES *attr, FILE_BASIC_INFORMATION *info )
{
    const char *n = narrow( attr->ObjectName );
    unsigned i;
    (void)info;
    queries++;
    if (attr->ObjectName->Buffer[attr->ObjectName->Length / 2] != 0) return 0xc000000d;  /* must stay terminated */
    for (i = 0; i < ARRAY_SIZE(present); i++) if (!strcmp( n, present[i] )) return 0;
    return 0xc0000034;
}

@@REGION@@

static int run( const char *path, ACCESS_MASK access, ULONG sharing, ULONG disposition, ULONG options,
                HANDLE root, char *out )
{
    WCHAR name[600], xpath[MAX_PATH];
    UNICODE_STRING us, x;
    OBJECT_ATTRIBUTES attr;
    int i, n = strlen( path );
    for (i = 0; i < n; i++) name[i] = (unsigned char)path[i];
    us.Buffer = name; us.Length = us.MaximumLength = n * 2;
    attr.Length = sizeof(attr); attr.RootDirectory = root; attr.ObjectName = &us; attr.Attributes = 0x40;
    if (!ios_sysx64_file_name( &attr, access, sharing, disposition, options, &x, xpath )) { strcpy( out, "-" ); return 0; }
    strcpy( out, narrow( &x ) );
    return 1;
}

int main( int argc, char **argv )
{
    /* lines: path|access|sharing|disposition|options|root|x64 */
    char line[800], out[800];
    while (fgets( line, sizeof(line), stdin ))
    {
        char *f[7], *p = line;
        int i;
        line[strcspn( line, "\n" )] = 0;
        for (i = 0; i < 7; i++) { f[i] = p; p = strchr( p, '|' ); if (p) *p++ = 0; else break; }
        x64_process = atoi( f[6] );
        run( f[0], strtoul( f[1], 0, 0 ), strtoul( f[2], 0, 0 ), strtoul( f[3], 0, 0 ), strtoul( f[4], 0, 0 ),
             (HANDLE)(uintptr_t)strtoul( f[5], 0, 0 ), out );
        printf( "%s\n", out );
    }
    (void)argc; (void)argv;
    return 0;
}
'''

GR, SYNC, RATTR = 0x80000000, 0x100000, 0x80
CREATEFILE_READ = GR | SYNC | RATTR
NONDIR_SYNC = 0x40 | 0x20
SHARE_R, SHARE_RD, SHARE_RW = 1, 5, 3
S32 = "\\??\\C:\\windows\\system32\\"
X64 = "\\??\\C:\\windows\\sysx64\\"

CASES = [
    # (what, path, access, sharing, disposition, options, root, x64, expected)
    ("CreateFileW read of system32\\ntdll.dll gets sysx64", S32 + "ntdll.dll", CREATEFILE_READ, SHARE_R, 1, NONDIR_SYNC, 0, 1, X64 + "ntdll.dll"),
    ("mixed-case path keeps its other parts", "\\??\\C:\\Windows\\System32\\NTDLL.DLL", CREATEFILE_READ, SHARE_RW, 1, NONDIR_SYNC, 0, 1, "\\??\\C:\\Windows\\sysx64\\NTDLL.DLL"),
    ("kernel32.dll read gets sysx64", S32 + "kernel32.dll", CREATEFILE_READ, SHARE_R, 1, NONDIR_SYNC, 0, 1, X64 + "kernel32.dll"),
    ("loader-shaped open of kernel32 keeps its name", S32 + "kernel32.dll", GR | SYNC, SHARE_RD, 1, NONDIR_SYNC, 0, 1, "-"),
    ("loader-shaped open (share read only) keeps its name", S32 + "kernel32.dll", GR | SYNC, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
    ("loader-shaped open of ntdll still gets sysx64", S32 + "ntdll.dll", GR | SYNC, SHARE_RD, 1, NONDIR_SYNC, 0, 1, X64 + "ntdll.dll"),
    ("raw NtOpenFile with FILE_READ_DATA gets sysx64", S32 + "ntdll.dll", 0x1 | SYNC, SHARE_R, 1, 0x20, 0, 1, X64 + "ntdll.dll"),
    ("a write keeps its name", S32 + "ntdll.dll", CREATEFILE_READ | 0x40000000, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
    ("FILE_WRITE_ATTRIBUTES keeps its name", S32 + "ntdll.dll", CREATEFILE_READ | 0x100, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
    ("DELETE keeps its name", S32 + "ntdll.dll", CREATEFILE_READ | 0x10000, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
    ("MAXIMUM_ALLOWED keeps its name", S32 + "ntdll.dll", 0x02000000, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
    ("FILE_OPEN_IF keeps its name", S32 + "ntdll.dll", CREATEFILE_READ, SHARE_R, 3, NONDIR_SYNC, 0, 1, "-"),
    ("a directory open keeps its name", S32 + "ntdll.dll", CREATEFILE_READ, SHARE_R, 1, 0x21, 0, 1, "-"),
    ("open by file id keeps its name", S32 + "ntdll.dll", CREATEFILE_READ, SHARE_R, 1, 0x2060, 0, 1, "-"),
    ("delete-on-close keeps its name", S32 + "ntdll.dll", CREATEFILE_READ, SHARE_R, 1, 0x1060, 0, 1, "-"),
    ("a subfolder of system32 keeps its name", S32 + "drivers\\ntdll.dll", CREATEFILE_READ, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
    ("a non-DLL keeps its name", S32 + "ntdll.exe", CREATEFILE_READ, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
    ("a DLL sysx64 lacks keeps its name", S32 + "d3d11.dll", CREATEFILE_READ, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
    ("a relative open (root handle) keeps its name", "ntdll.dll", CREATEFILE_READ, SHARE_R, 1, NONDIR_SYNC, 0x44, 1, "-"),
    ("a non-x64 process keeps its name", S32 + "ntdll.dll", CREATEFILE_READ, SHARE_R, 1, NONDIR_SYNC, 0, 0, "-"),
    ("syswow64 keeps its name", "\\??\\C:\\windows\\syswow64\\ntdll.dll", CREATEFILE_READ, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
    ("a game folder's ntdll.dll keeps its name", "\\??\\C:\\Games\\BO3\\ntdll.dll", CREATEFILE_READ, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
    ("a short name keeps its name", "\\windows\\system32\\a", CREATEFILE_READ, SHARE_R, 1, NONDIR_SYNC, 0, 1, "-"),
]

tmp = Path(tempfile.mkdtemp(prefix="sysx64-file-"))
try:
    # Patch a copy with every wine patch that touches file.c, so the check runs
    # whether or not apply.sh has run on the submodule.
    work = tmp / "wine"
    (work / "dlls/ntdll/unix").mkdir(parents=True)
    shutil.copy(SRC, work / "dlls/ntdll/unix/file.c")
    subprocess.run(["git", "init", "-q", str(work)], check=True)
    for patch in PATCHES:
        inc = ["--include=dlls/ntdll/unix/file.c"]
        if "dlls/ntdll/unix/file.c" not in patch.read_text(errors="replace"):
            continue
        rev = subprocess.run(["git", "-C", str(work), "apply", *inc, "--reverse", "--check", str(patch)], capture_output=True)
        if rev.returncode != 0:
            subprocess.run(["git", "-C", str(work), "apply", *inc, str(patch)], check=True)
    text = (work / "dlls/ntdll/unix/file.c").read_text()
    begin = text.index("/* sysx64-file-test:begin */")
    end = text.index("/* sysx64-file-test:end */")
    region = text[begin:end]
    check("the region has the helper and NtCreateFile calls it",
          "static BOOL ios_sysx64_file_name(" in region
          and "if (ios_sysx64_file_name( attr, access, sharing, disposition, options, &x64_name, x64_path ))" in text)

    harness = tmp / "harness.c"
    harness.write_text(HARNESS.replace("@@REGION@@", region))
    exe = tmp / "harness"
    flags = ["-O1", "-g", "-Wall", "-Wno-unused-function"]
    san = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
    if subprocess.run([CC, *flags, *san, "-o", str(exe), str(harness)], capture_output=True).returncode != 0:
        build = subprocess.run([CC, *flags, "-o", str(exe), str(harness)], capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stderr)
            sys.exit("harness did not compile")

    stdin = "".join(f"{c[1]}|{c[2]}|{c[3]}|{c[4]}|{c[5]}|{c[6]}|{c[7]}\n" for c in CASES)

    def outputs(env_value):
        env = dict(os.environ)
        env.pop("MADEIRA_SYSX64_FILE", None)
        if env_value is not None:
            env["MADEIRA_SYSX64_FILE"] = env_value
        r = subprocess.run([str(exe)], input=stdin, capture_output=True, text=True, env=env)
        if r.returncode != 0:
            print(r.stderr)
        return r.returncode, r.stdout.splitlines(), r.stderr

    rc, got, log = outputs("1")
    check("the harness ran cleanly with the switch on", rc == 0 and len(got) == len(CASES))
    for case, line in zip(CASES, got):
        check(case[0], line == case[8])
    check("the redirect is logged with [sysx64-file]", "[sysx64-file] x64 read of" in log)

    for value in (None, "0", "11"):
        rc, got, _ = outputs(value)
        check(f"MADEIRA_SYSX64_FILE={value!r}: nothing changes",
              rc == 0 and len(got) == len(CASES) and all(line == "-" for line in got))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
