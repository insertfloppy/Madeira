#!/usr/bin/env python3
"""The raw-video colour converter in build/ntdll-unix/winegstreamer_unixlib_ios.c, on the host; no Wine runs.

Wine's video processor and colour converter MFTs (dlls/winegstreamer/video_processor.c,
color_convert.c) are shells around a raw-video wg_transform.  Madeira used to refuse every
transform that was not WMA, so a Media Foundation source reader that needed one (Unity's video
player asking for RGB32 from an H.264 MP4: The Planet Crafter's loading video) failed with
MF_E_TOPO_CODEC_NOT_FOUND and the game hung.  This drives the production wg_transform entries
the way video_processor.c does (create, push one picture, read until NEED_MORE_INPUT) and checks
the pixels: NV12/I420/YV12/YUY2 in, NV12/I420/YV12/YUY2/RGB32/ARGB32/ABGR32 out, BT.601 and
BT.709, bottom-up input and output, a caller pitch on the output sample, back-pressure, a buffer
too small, timestamps and flags, and the refusals (scaling, compressed input, RGB to YUV,
MADEIRA_WG_VCONV=0).

Environment: as tests/host/check-wma-decoder.py (MADEIRA_WINE_SRC, MADEIRA_WINE_BUILD,
MADEIRA_FFMPEG_TARBALL, MADEIRA_HOST_FFMPEG); the same host FFmpeg build is reused.
"""
from pathlib import Path
import hashlib, os, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
ntdll_unix = root / "build/ntdll-unix"
wine = Path(os.environ.get("MADEIRA_WINE_SRC") or root / "wine")
wine_build = Path(os.environ.get("MADEIRA_WINE_BUILD") or wine / "build-macos")
for need in [wine_build / "include/config.h", wine_build / "include/mfobjects.h", wine / "dlls/winegstreamer/unixlib.h"]:
    if not need.exists():
        sys.exit("SKIP-FAIL: %s is missing; point MADEIRA_WINE_BUILD at a configured Wine tree" % need)

# ------------------------------------------------------------------ source checks
unixlib = (ntdll_unix / "winegstreamer_unixlib_ios.c").read_text()
create = unixlib[unixlib.index("static NTSTATUS transform_create( struct wg_transform_create_params *params )"):]
create = create[:create.index("\n}\n")]
assert "return vconv_create( params );" in create, "transform_create must route raw video to the converter"
assert create.index("return vconv_create( params );") < create.index("if (!in || !out)"), "raw video must be routed before the audio refusal"
for fn in ["transform_destroy", "transform_push_data", "transform_read_data",
           "transform_get_output_type", "transform_set_output_type"]:
    body = unixlib[unixlib.index("static NTSTATUS %s(" % fn):]
    body = body[:body.index("\n}\n")]
    assert "get_vconv( handle )" in body, "%s must dispatch the converter" % fn
assert 'getenv( "MADEIRA_WG_VCONV" )' in unixlib
docs = (root / "docs/MEDIA.md").read_text()
assert "`MADEIRA_WG_VCONV`" in docs, "docs/MEDIA.md must list MADEIRA_WG_VCONV"
print("PASS: every wg_transform entry dispatches the converter; MADEIRA_WG_VCONV documented")

# ------------------------------------------------------------------ host FFmpeg (shared with check-wma-decoder.py)
tarball = os.environ.get("MADEIRA_FFMPEG_TARBALL") or str(root / "build/ffmpeg/src/ffmpeg-7.1.1.tar.xz")
FLAGS = [
    "--disable-everything", "--disable-autodetect", "--disable-gpl", "--disable-nonfree", "--disable-version3",
    "--enable-decoder=wmav1,wmav2,wmapro,wmalossless,xma1,xma2",
    "--enable-decoder=mp1,mp2,mp3", "--enable-decoder=pcm_u8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le",
    "--enable-demuxer=mp3,wav,mov", "--enable-parser=mpegaudio",
    "--enable-encoder=wmav1,wmav2",
    "--disable-programs", "--disable-doc", "--disable-network", "--disable-avdevice", "--disable-swscale",
    "--disable-avfilter", "--disable-postproc", "--enable-avformat", "--enable-avcodec", "--enable-swresample",
    "--disable-asm", "--disable-shared", "--enable-static", "--enable-pic", "--disable-debug",
]
prefix = os.environ.get("MADEIRA_HOST_FFMPEG")
if not prefix:
    key = hashlib.sha256(" ".join(FLAGS).encode()).hexdigest()[:12]
    prefix = str(Path.home() / ".cache/madeira-host-ffmpeg" / ("7.1.1-" + key))
    if not (Path(prefix) / "lib/libavcodec.a").exists():
        assert Path(tarball).exists(), "no FFmpeg tarball at %s" % tarball
        src = Path(prefix + "-src")
        src.mkdir(parents=True, exist_ok=True)
        if not (src / "ffmpeg-7.1.1/configure").exists():
            subprocess.run(["tar", "-xJf", tarball, "-C", str(src)], check=True)
        bld = Path(prefix + "-build"); bld.mkdir(parents=True, exist_ok=True)
        print("building host FFmpeg into", prefix, flush=True)
        log = open(str(bld) + ".log", "w")
        subprocess.run([str(src / "ffmpeg-7.1.1/configure"), "--prefix=" + prefix, "--cc=cc"] + FLAGS,
                       cwd=bld, check=True, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run(["make", "-j%d" % (os.cpu_count() or 4)], cwd=bld, check=True, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run(["make", "install"], cwd=bld, check=True, stdout=log, stderr=subprocess.STDOUT)
inc, lib = Path(prefix) / "include", Path(prefix) / "lib"

# ------------------------------------------------------------------ harness
harness = r"""
#include "winegstreamer_unixlib_ios.c"
#include <math.h>

const struct mav_video_backend mav_apple_video_backend;
const struct mav_audio_backend mav_apple_audio_backend;

static int failures, checks;
static const char *name;
#define CHECK(c, ...) do { checks++; if (!(c)) { printf( "FAIL %s: ", name ); printf( __VA_ARGS__ ); printf( "\n" ); failures++; return; } } while (0)

enum { NV12 = 0x3231564e, I420 = 0x30323449, IYUV = 0x56555949, YV12 = 0x32315659, YUY2 = 0x32595559,
       RGB32 = 22, ARGB32 = 21, ABGR32 = 32, H264 = 0x34363248 };

static GUID subtype( UINT tag )
{
    GUID g = { tag, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
    return g;
}

static MFVIDEOFORMAT vf( UINT tag, UINT w, UINT h, BOOL bottom_up, int matrix, BOOL full )
{
    MFVIDEOFORMAT f;
    memset( &f, 0, sizeof(f) );
    f.dwSize = sizeof(f);
    f.guidFormat = subtype( tag );
    f.videoInfo.dwWidth = w;
    f.videoInfo.dwHeight = h;
    f.videoInfo.TransferMatrix = matrix;
    f.videoInfo.NominalRange = full ? MFNominalRange_0_255 : MFNominalRange_16_235;
    if (bottom_up) f.videoInfo.VideoFlags = MFVideoFlag_BottomUpLinearRep;
    return f;
}

static struct wg_media_type mt( MFVIDEOFORMAT *f )
{
    struct wg_media_type t;
    memset( &t, 0, sizeof(t) );
    t.major = madeira_MFMediaType_Video;
    t.format_size = sizeof(*f);
    t.u.video = f;
    return t;
}

static NTSTATUS make( MFVIDEOFORMAT *in, MFVIDEOFORMAT *out, wg_transform_t *handle )
{
    struct wg_transform_create_params p;
    NTSTATUS st;
    memset( &p, 0, sizeof(p) );
    p.input_type = mt( in );
    p.output_type = mt( out );
    st = transform_create( &p );
    *handle = p.transform;
    return st;
}

/* Reference picture: smooth Y ramp and chroma that varies with position, as top-down NV12. */
static BYTE ref_y( UINT x, UINT y ) { return (BYTE)(16 + (x * 7 + y * 3) % 220); }
static BYTE ref_u( UINT cx, UINT cy ) { return (BYTE)(64 + (cx * 5 + cy * 11) % 128); }
static BYTE ref_v( UINT cx, UINT cy ) { return (BYTE)(192 - (cx * 3 + cy * 7) % 128); }

/* Writes the reference picture in `tag` with default layout (stride 0 rules: the parser's
 * align4 NV12 stride for input), optionally bottom-up; returns its size. */
static size_t write_input( UINT tag, UINT w, UINT h, BOOL flip, BYTE *buf )
{
    enum mav_pixel_format fmt = vconv_pixel_format( &(GUID){ tag, 0, 0x10, { 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 } } );
    struct mav_layout l;
    UINT x, y, cw = (w + 1) / 2, ch = (h + 1) / 2;
    size_t size = vconv_layout( fmt, w, h, 0, FALSE, &l );
#define ROW(p, r, rows) (buf + l.offset[p] + (size_t)l.stride[p] * (flip ? (rows) - 1 - (r) : (r)))
    memset( buf, 0xcd, size );
    if (fmt == MAV_PIX_YUY2)
    {
        for (y = 0; y < h; y++)
            for (x = 0; x < w; x += 2)
            {
                BYTE *o = ROW( 0, y, h ) + 2 * x;
                o[0] = ref_y( x, y ); o[1] = ref_u( x / 2, y / 2 );
                o[2] = x + 1 < w ? ref_y( x + 1, y ) : ref_y( x, y ); o[3] = ref_v( x / 2, y / 2 );
            }
        return size;
    }
    for (y = 0; y < h; y++) for (x = 0; x < w; x++) ROW( 0, y, h )[x] = ref_y( x, y );
    for (y = 0; y < ch; y++)
        for (x = 0; x < cw; x++)
        {
            if (fmt == MAV_PIX_NV12) { ROW( 1, y, ch )[2 * x] = ref_u( x, y ); ROW( 1, y, ch )[2 * x + 1] = ref_v( x, y ); }
            else
            {
                int up = fmt == MAV_PIX_I420 ? 1 : 2;
                ROW( up, y, ch )[x] = ref_u( x, y );
                ROW( 3 - up, y, ch )[x] = ref_v( x, y );
            }
        }
#undef ROW
    return size;
}

static int clip( double v ) { return v < 0 ? 0 : v > 255 ? 255 : (int)lround( v ); }

/* Expected RGB of the reference picture at (x, y). */
static void ref_rgb( UINT x, UINT y, int bt709, int full, int rgb[3] )
{
    double Y = ref_y( x, y ), U = ref_u( x / 2, y / 2 ) - 128.0, V = ref_v( x / 2, y / 2 ) - 128.0;
    double kr = bt709 ? 0.2126 : 0.299, kb = bt709 ? 0.0722 : 0.114, kg = 1 - kr - kb;
    double ys = full ? 1.0 : 255.0 / 219.0, cs = full ? 1.0 : 255.0 / 224.0;
    double yy = (Y - (full ? 0 : 16)) * ys;
    rgb[0] = clip( yy + cs * 2 * (1 - kr) * V );
    rgb[2] = clip( yy + cs * 2 * (1 - kb) * U );
    rgb[1] = clip( yy - cs * (2 * (1 - kb) * kb / kg * U + 2 * (1 - kr) * kr / kg * V) );
}

/* Checks the output picture at pitch `stride` against the reference. */
static int verify( UINT tag, UINT w, UINT h, BOOL flip, UINT stride, int bt709, int full, const BYTE *buf, char *why )
{
    UINT x, y, cw = (w + 1) / 2;
    enum mav_pixel_format fmt = vconv_pixel_format( &(GUID){ tag, 0, 0x10, { 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 } } );
    struct mav_layout l;
    vconv_layout( fmt, w, h, stride, TRUE, &l );
#define ROW(p, r, rows) (buf + l.offset[p] + (size_t)l.stride[p] * (flip ? (rows) - 1 - (r) : (r)))
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++)
        {
            UINT cx = x / 2, cy = y / 2;
            int ey = ref_y( x, y ), eu = ref_u( cx, cy ), ev = ref_v( cx, cy ), gy = -1, gu = -1, gv = -1;
            if (vconv_is_rgb( fmt ))
            {
                int e[3], g[3], i, ri = fmt == MAV_PIX_RGBA ? 0 : 2;
                const BYTE *p = ROW( 0, y, h ) + 4 * x;
                ref_rgb( x, y, bt709, full, e );
                g[0] = p[ri]; g[1] = p[1]; g[2] = p[2 - ri];
                for (i = 0; i < 3; i++)
                    if (abs( g[i] - e[i] ) > 2)
                    {
                        sprintf( why, "pixel %u,%u rgb %d,%d,%d expected %d,%d,%d", x, y, g[0], g[1], g[2], e[0], e[1], e[2] );
                        return 0;
                    }
                if (p[3] != 0xff) { sprintf( why, "pixel %u,%u alpha %d", x, y, p[3] ); return 0; }
                continue;
            }
            switch (fmt)
            {
            case MAV_PIX_NV12: gy = ROW( 0, y, h )[x]; gu = ROW( 1, cy, l.chroma_height )[2 * cx]; gv = ROW( 1, cy, l.chroma_height )[2 * cx + 1]; break;
            case MAV_PIX_I420: gy = ROW( 0, y, h )[x]; gu = ROW( 1, cy, l.chroma_height )[cx]; gv = ROW( 2, cy, l.chroma_height )[cx]; break;
            case MAV_PIX_YV12: gy = ROW( 0, y, h )[x]; gv = ROW( 1, cy, l.chroma_height )[cx]; gu = ROW( 2, cy, l.chroma_height )[cx]; break;
            case MAV_PIX_YUY2:
            {
                const BYTE *p = ROW( 0, y, h ) + 4 * cx;
                gy = p[(x & 1) * 2]; gu = p[1]; gv = p[3];
                break;
            }
            default: break;
            }
            if (gy != ey || gu != eu || gv != ev)
            {
                sprintf( why, "pixel %u,%u yuv %d,%d,%d expected %d,%d,%d", x, y, gy, gu, gv, ey, eu, ev );
                return 0;
            }
        }
#undef ROW
    (void)cw;
    return 1;
}

static BYTE inbuf[4 << 20], outbuf[8 << 20];

static void convert( UINT in_tag, BOOL in_flip, UINT out_tag, BOOL out_flip, UINT w, UINT h, int matrix,
                     BOOL full, UINT out_stride )
{
    MFVIDEOFORMAT in = vf( in_tag, w, h, in_flip, matrix, full ), out = vf( out_tag, w, h, out_flip, 0, FALSE );
    struct wg_sample s;
    wg_transform_t t = 0;
    HRESULT hr = E_FAIL;
    NTSTATUS st;
    char why[256] = "";
    size_t in_size;
    int bt709 = matrix == MFVideoTransferMatrix_BT709 ? 1 : matrix == MFVideoTransferMatrix_BT601 ? 0 : h >= 720;
    static char label[200];

    snprintf( label, sizeof(label), "%.4s%s -> %s%s %ux%u %s%s stride %u",
              (char *)&in_tag, in_flip ? " (bottom-up)" : "",
              out_tag == RGB32 ? "RGB32" : out_tag == ARGB32 ? "ARGB32" : out_tag == ABGR32 ? "ABGR32" : (char[5]){ out_tag, out_tag >> 8, out_tag >> 16, out_tag >> 24, 0 },
              out_flip ? " (bottom-up)" : "", w, h, bt709 ? "bt709" : "bt601", full ? " full" : "", out_stride );
    name = label;

    CHECK( !(st = make( &in, &out, &t )) && t, "create returned %#x", (UINT)st );
    in_size = write_input( in_tag, w, h, in_flip, inbuf );

    memset( &s, 0, sizeof(s) );
    s.size = s.max_size = in_size;
    s.flags = WG_SAMPLE_FLAG_HAS_PTS | WG_SAMPLE_FLAG_HAS_DURATION;
    s.pts = 400000; s.duration = 333333;
    CHECK( !transform_push_data( t, &s, inbuf, &hr ) && hr == S_OK, "push hr %#x", (UINT)hr );
    hr = E_FAIL;
    CHECK( !transform_push_data( t, &s, inbuf, &hr ) && hr == MF_E_NOTACCEPTING, "second push should be refused, hr %#x", (UINT)hr );

    memset( &s, 0, sizeof(s) );
    s.max_size = 16;
    CHECK( !transform_read_data( t, &s, outbuf, &hr ) && hr == MF_E_BUFFERTOOSMALL && !s.size, "tiny read hr %#x", (UINT)hr );

    memset( outbuf, 0xab, sizeof(outbuf) );
    memset( &s, 0, sizeof(s) );
    s.max_size = sizeof(outbuf);
    s.stride = out_stride;
    CHECK( !transform_read_data( t, &s, outbuf, &hr ) && hr == S_OK, "read hr %#x", (UINT)hr );
    CHECK( (s.flags & WG_SAMPLE_FLAG_HAS_PTS) && s.pts == 400000, "pts lost (flags %#x)", (UINT)s.flags );
    CHECK( (s.flags & WG_SAMPLE_FLAG_HAS_DURATION) && s.duration == 333333, "duration lost" );
    CHECK( s.flags & WG_SAMPLE_FLAG_DISCONTINUITY, "first output must be a discontinuity" );
    CHECK( s.flags & WG_SAMPLE_FLAG_SYNC_POINT, "sync point" );
    {
        struct mav_layout l;
        enum mav_pixel_format of = vconv_pixel_format( &out.guidFormat );
        size_t want = vconv_layout( of, w, h, out_stride, TRUE, &l );
        CHECK( s.size == want, "size %u, expected %zu", (UINT)s.size, want );
    }
    CHECK( verify( out_tag, w, h, out_flip, out_stride, bt709, full, outbuf, why ), "%s", why );

    memset( &s, 0, sizeof(s) );
    s.max_size = sizeof(outbuf);
    CHECK( !transform_read_data( t, &s, outbuf, &hr ) && hr == MF_E_TRANSFORM_NEED_MORE_INPUT, "drained read hr %#x", (UINT)hr );

    /* the next picture is not a discontinuity, and pushing works again */
    memset( &s, 0, sizeof(s) );
    s.size = s.max_size = in_size;
    CHECK( !transform_push_data( t, &s, inbuf, &hr ) && hr == S_OK, "push 2 hr %#x", (UINT)hr );
    memset( &s, 0, sizeof(s) );
    s.max_size = sizeof(outbuf);
    s.stride = out_stride;
    CHECK( !transform_read_data( t, &s, outbuf, &hr ) && hr == S_OK, "read 2 hr %#x", (UINT)hr );
    CHECK( !(s.flags & (WG_SAMPLE_FLAG_DISCONTINUITY | WG_SAMPLE_FLAG_HAS_PTS)), "second picture flags %#x", (UINT)s.flags );
    CHECK( verify( out_tag, w, h, out_flip, out_stride, bt709, full, outbuf, why ), "picture 2: %s", why );

    transform_destroy( t );
    printf( "PASS %s\n", label );
}

static void refused( const char *what, MFVIDEOFORMAT in, MFVIDEOFORMAT out )
{
    wg_transform_t t = 0;
    NTSTATUS st = make( &in, &out, &t );
    name = what;
    CHECK( st && !t, "should be refused, got %#x", (UINT)st );
    printf( "PASS refused: %s\n", what );
}

static void output_type_roundtrip(void)
{
    MFVIDEOFORMAT in = vf( NV12, 64, 32, FALSE, 0, FALSE ), out = vf( RGB32, 64, 32, TRUE, 0, FALSE ), got, nv;
    struct wg_media_type t = { 0 }, nt;
    wg_transform_t h;
    name = "output type";
    CHECK( !make( &in, &out, &h ), "create" );
    t.major = madeira_MFMediaType_Video;
    CHECK( transform_get_output_type( h, &t ) == STATUS_BUFFER_TOO_SMALL && t.format_size == sizeof(MFVIDEOFORMAT), "size probe" );
    t.u.video = &got;
    CHECK( !transform_get_output_type( h, &t ) && !memcmp( &got, &out, sizeof(out) ), "get" );
    nv = vf( ARGB32, 64, 32, FALSE, 0, FALSE );
    nt = mt( &nv );
    CHECK( !transform_set_output_type( h, &nt ), "set ARGB32" );
    CHECK( !transform_get_output_type( h, &t ) && IsEqualGUID( &got.guidFormat, &nv.guidFormat ), "get after set" );
    nv = vf( RGB32, 32, 32, FALSE, 0, FALSE );
    nt = mt( &nv );
    CHECK( transform_set_output_type( h, &nt ), "a size change must be refused" );
    transform_destroy( h );
    printf( "PASS output type: two-phase get, set, size change refused\n" );
}

int main( int argc, char **argv )
{
    static const UINT yuv_in[] = { NV12, I420, IYUV, YV12, YUY2 };
    static const UINT outs[] = { NV12, I420, YV12, YUY2, RGB32, ARGB32, ABGR32 };
    unsigned int i, j;

    if (argc > 1 && !strcmp( argv[1], "off" ))
    {
        refused( "MADEIRA_WG_VCONV=0", vf( NV12, 64, 32, FALSE, 0, FALSE ), vf( RGB32, 64, 32, FALSE, 0, FALSE ) );
        return failures ? 1 : 0;
    }

    for (i = 0; i < ARRAY_SIZE(yuv_in); i++)
        for (j = 0; j < ARRAY_SIZE(outs); j++)
            convert( yuv_in[i], FALSE, outs[j], FALSE, 64, 36, MFVideoTransferMatrix_BT601, FALSE, 0 );
    /* the loading-video case: 1080p H.264 decoded to NV12, Unity wants RGB32, video processor sets bottom-up */
    convert( NV12, FALSE, RGB32, TRUE, 1920, 1080, MFVideoTransferMatrix_BT709, FALSE, 0 );
    convert( NV12, FALSE, ARGB32, TRUE, 1920, 1080, 0, FALSE, 0 );
    convert( NV12, FALSE, RGB32, FALSE, 1280, 720, MFVideoTransferMatrix_BT709, TRUE, 1280 * 4 + 256 );
    /* bottom-up input, odd sizes, caller pitch */
    convert( NV12, TRUE, I420, FALSE, 62, 34, 0, FALSE, 0 );
    convert( I420, TRUE, NV12, TRUE, 66, 30, 0, FALSE, 0 );
    convert( YUY2, TRUE, ARGB32, FALSE, 50, 20, MFVideoTransferMatrix_BT601, TRUE, 0 );
    convert( NV12, FALSE, NV12, FALSE, 99, 51, 0, FALSE, 128 );
    convert( NV12, FALSE, I420, FALSE, 64, 32, 0, FALSE, 96 );
    convert( NV12, FALSE, YUY2, FALSE, 63, 31, 0, FALSE, 0 );
    /* RGB passthrough with a flip */
    {
        MFVIDEOFORMAT in = vf( RGB32, 8, 4, TRUE, 0, FALSE ), out = vf( RGB32, 8, 4, FALSE, 0, FALSE );
        wg_transform_t t; struct wg_sample s = { 0 }; HRESULT hr; UINT y, x; int ok = 1;
        name = "RGB32 bottom-up -> top-down";
        CHECK( !make( &in, &out, &t ), "create" );
        for (y = 0; y < 4; y++) for (x = 0; x < 32; x++) inbuf[y * 32 + x] = (BYTE)(y * 40 + x);
        s.size = s.max_size = 128;
        CHECK( !transform_push_data( t, &s, inbuf, &hr ) && hr == S_OK, "push" );
        memset( &s, 0, sizeof(s) ); s.max_size = sizeof(outbuf);
        CHECK( !transform_read_data( t, &s, outbuf, &hr ) && hr == S_OK && s.size == 128, "read" );
        for (y = 0; y < 4; y++) if (memcmp( outbuf + y * 32, inbuf + (3 - y) * 32, 32 )) ok = 0;
        CHECK( ok, "rows not flipped" );
        transform_destroy( t );
        printf( "PASS %s\n", name );
    }
    output_type_roundtrip();
    refused( "scaling 64x36 -> 32x18", vf( NV12, 64, 36, FALSE, 0, FALSE ), vf( RGB32, 32, 18, FALSE, 0, FALSE ) );
    refused( "H.264 input (compressed)", vf( H264, 64, 36, FALSE, 0, FALSE ), vf( NV12, 64, 36, FALSE, 0, FALSE ) );
    refused( "RGB32 -> NV12", vf( RGB32, 64, 36, FALSE, 0, FALSE ), vf( NV12, 64, 36, FALSE, 0, FALSE ) );
    refused( "unknown output subtype", vf( NV12, 64, 36, FALSE, 0, FALSE ), vf( 0x31313131, 64, 36, FALSE, 0, FALSE ) );
    printf( "%d checks, %d failure(s)\n", checks, failures );
    return failures ? 1 : 0;
}
"""

with tempfile.TemporaryDirectory() as tmp:
    h = Path(tmp) / "vconv_host.c"
    h.write_text(harness)
    exe = Path(tmp) / "vconv_host"
    cc = os.environ.get("CC", "cc")
    cmd = [cc, "-O1", "-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined",
           "-fno-strict-aliasing", "-Wno-int-conversion", "-Wno-implicit-function-declaration",
           "-include", str(wine_build / "include/config.h"),
           "-I" + str(ntdll_unix), "-I" + str(wine / "dlls/winegstreamer"),
           "-I" + str(wine_build / "include"), "-I" + str(wine / "include"), "-I" + str(inc),
           "-D__WINESRC__", "-D_NTSYSTEM_", "-D_ACRTIMP=", "-DWINBASEAPI=", "-DWINE_UNIX_LIB",
           str(h), "-o", str(exe),
           str(lib / "libavformat.a"), str(lib / "libavcodec.a"), str(lib / "libswresample.a"), str(lib / "libavutil.a"),
           "-lm", "-lpthread"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-6000:], r.stderr[-6000:])
        sys.exit("FAIL: harness did not compile")
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0" if sys.platform == "darwin" else "detect_leaks=1")
    env.pop("MADEIRA_WG_VCONV", None)
    ok = True
    for label, extra_env, args in [("converter on (default)", {}, []), ("MADEIRA_WG_VCONV=0", {"MADEIRA_WG_VCONV": "0"}, ["off"])]:
        print("--- %s ---" % label, flush=True)
        r = subprocess.run([str(exe)] + args, env=dict(env, **extra_env), capture_output=True, text=True)
        sys.stdout.write(r.stdout)
        if r.returncode:
            ok = False
            print("\n".join(r.stderr.splitlines()[-40:]))
    sys.exit(0 if ok else "FAIL: video converter host test")
