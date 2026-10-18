// pluck-raw: decodes camera raw video (RED .R3D and Blackmagic RAW; Canon Cinema RAW Light to
// follow) for Pluck's Viewer. A separate program, so the camera makers' own libraries load in
// it alone (and a crash in them can't take Pluck down).
//
// Talks one JSON object per line on stdin/stdout. Frames go through a file Pluck maps into
// memory: 16-bit RGBA, top row first.
//
//   {"op":"open","path":"…"}                     → clip size, frame rate, frames, settings, metadata
//   {"op":"frame","index":n,"scale":1|2|4|8, "depth":8 (BGRA 8-bit, else RGBA 16-bit),
//    "buffer":"…","size":bytes,"look":"display|shot|log",
//    "iso":800,"kelvin":5600,"tint":0,"exposure":0} → {"ok":true,"width":w,"height":h}
//   {"op":"quit"}

#import <Foundation/Foundation.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <string>
#include <vector>

#if PLUCK_RED
#include "R3DSDK.h"
#include "R3DSDKMetal.h"
#import <Metal/Metal.h>
using namespace R3DSDK;
#endif

/// In a library (Quick Look, which may not start programs), replies are kept for the caller.
static bool libraryMode = false;
static NSDictionary *libraryReply = nil;

static void reply(NSDictionary *object) {
    if (libraryMode) { libraryReply = object; return; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void fail(NSString *problem) { reply(@{@"ok": @NO, @"problem": problem}); }

/// Where the camera libraries are: given with --libs (Quick Look's copy), or next to this program.
static std::string librariesFolder;

/// The folder this program is in (the camera libraries sit next to it).
static std::string helperFolder() {
    if (!librariesFolder.empty()) return librariesFolder;
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return ".";
    std::string full = [[[NSString stringWithUTF8String:path] stringByResolvingSymlinksInPath] UTF8String];
    return full.substr(0, full.find_last_of('/'));
}

/// Pluck's frame buffer, mapped once per path.
struct Mapped {
    std::string path;
    void *memory = nullptr;
    size_t size = 0;
    void *map(const std::string &to, size_t wanted) {
        if (to == path && wanted <= size) return memory;
        if (memory) munmap(memory, size);
        memory = nullptr;
        int fd = open(to.c_str(), O_RDWR);
        if (fd < 0) return nullptr;
        void *m = mmap(nullptr, wanted, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (m == MAP_FAILED) return nullptr;
        memory = m; size = wanted; path = to;
        return memory;
    }
};

/// A PCM .wav file: little-endian samples, interleaved.
struct WavFile {
    FILE *file = nullptr;
    uint32_t written = 0;
    bool open(const char *path, uint32_t rate, uint16_t channels, uint16_t bits) {
        file = fopen(path, "wb");
        if (!file) return false;
        uint16_t align = channels * (bits / 8);
        uint32_t byteRate = rate * align;
        uint16_t pcm = 1;
        uint32_t sixteen = 16, zero = 0;
        fwrite("RIFF", 1, 4, file); fwrite(&zero, 4, 1, file); fwrite("WAVEfmt ", 1, 8, file);
        fwrite(&sixteen, 4, 1, file); fwrite(&pcm, 2, 1, file); fwrite(&channels, 2, 1, file);
        fwrite(&rate, 4, 1, file); fwrite(&byteRate, 4, 1, file); fwrite(&align, 2, 1, file); fwrite(&bits, 2, 1, file);
        fwrite("data", 1, 4, file); fwrite(&zero, 4, 1, file);
        return true;
    }
    void add(const void *bytes, size_t count) { fwrite(bytes, 1, count, file); written += (uint32_t)count; }
    void close() {
        if (!file) return;
        uint32_t riff = 36 + written;
        fseek(file, 4, SEEK_SET); fwrite(&riff, 4, 1, file);
        fseek(file, 40, SEEK_SET); fwrite(&written, 4, 1, file);
        fclose(file);
        file = nullptr;
    }
};

// MARK: - RED

#if PLUCK_RED
static bool redReady = false;
static Clip *redClip = nullptr;

// The GPU path: the decoder unpacks frames on the CPU and Metal develops them on the GPU,
// much faster for large frames. Not in the Quick Look extensions, and off with PLUCK_RAW_CPU.
static id<MTLDevice> redDevice;
static id<MTLCommandQueue> redQueue;
static REDMetal *redMetal = nullptr;
static GpuDecoder *redGpu = nullptr;
static EXT_METAL_API redMetalAPI;

static bool startRed() {
    if (redReady) return true;
    std::string folder = helperFolder() + "/RED";
    InitializeStatus status = ISLibraryNotLoaded;
    if (!libraryMode && !getenv("PLUCK_RAW_CPU")) {
        status = InitializeSdk(folder.c_str(), OPTION_RED_METAL);
        if (status == ISInitializeOK) {
            redDevice = MTLCreateSystemDefaultDevice();
            redQueue = [redDevice newCommandQueue];
            int error = 0;
            if (redQueue) {
                redMetal = new REDMetal(redMetalAPI);
                if (redMetal->checkCompatibility(redQueue, error) == REDMetal::Status_Ok) {
                    redGpu = new GpuDecoder();
                    redGpu->Open();
                } else {
                    delete redMetal; redMetal = nullptr;
                }
            }
        } else {
            FinalizeSdk();
        }
    }
    if (status != ISInitializeOK) status = InitializeSdk(folder.c_str(), OPTION_RED_NONE);
    if (status != ISInitializeOK) {
        fail([NSString stringWithFormat:@"The RED decoder couldn’t start (%d).", (int)status]);
        FinalizeSdk();
        return false;
    }
    redReady = true;
    return true;
}

static void openRed(NSString *path) {
    if (!startRed()) return;
    delete redClip;
    redClip = new Clip(path.fileSystemRepresentation);
    if (redClip->Status() != LSClipLoaded) {
        fail(@"This R3D file can’t be read.");
        delete redClip; redClip = nullptr;
        return;
    }
    ImageProcessingSettings shot;
    redClip->GetDefaultImageProcessingSettings(shot);
    NSMutableArray *isos = [NSMutableArray array];
    for (size_t i = 0; i < ImageProcessingLimits::ISOCount; i++) [isos addObject:@(ImageProcessingLimits::ISOList[i])];
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < redClip->MetadataCount(); i++) {
        std::string key = redClip->MetadataItemKey(i), value = redClip->MetadataItemAsString(i);
        NSString *k = [NSString stringWithUTF8String:key.c_str()], *v = [NSString stringWithUTF8String:value.c_str()];
        if (k && v) meta[k] = v;
    }
    reply(@{@"ok": @YES, @"format": @"r3d", @"sdk": [NSString stringWithUTF8String:GetSdkVersion()],
            @"width": @(redClip->Width()), @"height": @(redClip->Height()),
            @"fps": @(redClip->VideoAudioFramerate()), @"frames": @(redClip->VideoFrameCount()),
            @"iso": @(shot.ISO), @"isos": isos,
            @"kelvin": @(shot.Kelvin), @"kelvinRange": @[@(ImageProcessingLimits::KelvinMin), @(ImageProcessingLimits::KelvinMax)],
            @"tint": @(shot.Tint), @"tintRange": @[@(ImageProcessingLimits::TintMin), @(ImageProcessingLimits::TintMax)],
            @"exposure": @(shot.ExposureAdjust),
            @"exposureRange": @[@(ImageProcessingLimits::ExposureAdjustMin), @(ImageProcessingLimits::ExposureAdjustMax)],
            @"ipp2": @(shot.Version == ColorVersion3),
            @"timecode": meta[@"start_edge_timecode"] ?: @"", @"absoluteTimecode": meta[@"start_absolute_timecode"] ?: @"",
            @"audioChannels": @(redClip->AudioChannelCount()),
            @"meta": meta});
}

/// The clip's sound as a .wav: 32-bit (24-bit audio in the top bits), as the camera recorded it.
static void audioRed(NSDictionary *request) {
    size_t channels = redClip->AudioChannelCount();
    unsigned long long total = redClip->AudioSampleCount();
    if (channels == 0 || total == 0) { fail(@"This clip has no sound."); return; }
    unsigned int rate = redClip->MetadataItemAsInt(RMD_SAMPLERATE);
    WavFile wav;
    if (!wav.open([request[@"to"] fileSystemRepresentation], rate ? rate : 48000, (uint16_t)channels, 32)) { fail(@"The sound couldn’t be written."); return; }
    const size_t size = 1 << 20;
    void *raw = nullptr;
    posix_memalign(&raw, 512, size);
    uint8_t *buffer = (uint8_t *)raw;
    unsigned long long at = 0;
    while (at < total) {
        size_t samples = size / (4 * channels);
        if (redClip->DecodeAudio(at, &samples, buffer, size) != DSDecodeOK || samples == 0) break;
        // Big-endian to little-endian.
        size_t bytes = samples * 4 * channels;
        for (size_t i = 0; i < bytes; i += 4) { std::swap(buffer[i], buffer[i + 3]); std::swap(buffer[i + 1], buffer[i + 2]); }
        wav.add(buffer, bytes);
        at += samples;
    }
    free(raw);
    wav.close();
    reply(@{@"ok": @YES, @"channels": @(channels), @"rate": @(rate)});
}

static Mapped redBuffer;
static std::vector<uint16_t> redRGB;

struct RedWait {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    DecodeStatus status = DSDecodeFailed;
};

static void redDecompressed(AsyncDecompressJob *job, DecodeStatus status) {
    RedWait *wait = (RedWait *)job->PrivateData;
    wait->status = status;
    dispatch_semaphore_signal(wait->done);
}

static void *redPacked = nullptr;
static size_t redPackedSize = 0;
static id<MTLBuffer> redRawDevice, redResult;

/// One frame through the GPU path: its 16-bit RGB (in the GPU's result buffer, shared with the
/// CPU), or null if it couldn't, to use the CPU.
static const uint16_t *frameRedGpu(size_t index, VideoDecodeMode mode, ImageProcessingSettings &settings, size_t pixels) {
    if (!redMetal || !redGpu || GpuDecoder::DecodeSupportedForClip(*redClip) != DSDecodeOK) return nullptr;
    AsyncDecompressJob job;
    job.Clip = redClip;
    job.Mode = mode;
    job.VideoFrameNo = index;
    job.VideoTrackNo = 0;
    job.AbortDecode = false;
    job.OutputFrameMetadata = nullptr;
    size_t size = GpuDecoder::GetSizeBufferNeeded(job);
    if (size == 0) return nullptr;
    if (size > redPackedSize) {
        free(redPacked);
        if (posix_memalign(&redPacked, 16, size) != 0) { redPacked = nullptr; redPackedSize = 0; return nullptr; }
        redPackedSize = size;
    }
    job.OutputBuffer = redPacked;
    job.OutputBufferSize = size;
    RedWait wait;
    job.PrivateData = &wait;
    job.Callback = redDecompressed;
    if (redGpu->DecodeForGpuSdk(job) != DSDecodeOK) return nullptr;
    dispatch_semaphore_wait(wait.done, DISPATCH_TIME_FOREVER);
    if (wait.status != DSDecodeOK) return nullptr;

    DebayerMetalJob *debayer = redMetal->createDebayerJob();
    debayer->raw_host_mem = redPacked;
    if (redRawDevice.length < size) redRawDevice = [redDevice newBufferWithLength:size options:MTLResourceStorageModeShared];
    debayer->raw_device_mem = redRawDevice;
    debayer->mode = mode;
    debayer->imageProcessingSettings = &settings;
    debayer->pixelType = PixelType_16Bit_RGB_Interleaved;
    debayer->batchMode = false;
    debayer->debayerJobCallback = nullptr;
    size_t resultSize = DebayerMetalJob::ResultFrameSize(*debayer);
    if (resultSize < pixels * 6) { redMetal->releaseDebayerJob(debayer); return nullptr; }
    if (redResult.length < resultSize) redResult = [redDevice newBufferWithLength:resultSize options:MTLResourceStorageModeShared];
    debayer->output_device_mem = redResult;
    debayer->output_device_mem_size = redResult.length;
    debayer->output_device_image = nil;
    int error = 0;
    REDMetal::Status status = redMetal->process(redQueue, debayer, error);
    redMetal->releaseDebayerJob(debayer);
    if (status != REDMetal::Status_Ok) return nullptr;
    return (const uint16_t *)redResult.contents;
}

static void frameRed(NSDictionary *request) {
    if (!redClip) { fail(@"No clip is open."); return; }
    int scale = [request[@"scale"] intValue];
    VideoDecodeMode mode = DECODE_FULL_RES_PREMIUM;
    switch (scale) {
        case 2: mode = DECODE_HALF_RES_GOOD; break;
        case 4: mode = DECODE_QUARTER_RES_GOOD; break;
        case 8: mode = DECODE_EIGHT_RES_GOOD; break;
        case 16: mode = DECODE_SIXTEENTH_RES_GOOD; break;
        default: scale = 1;
    }
    size_t width = redClip->Width() / scale, height = redClip->Height() / scale;
    size_t pixels = width * height;

    ImageProcessingSettings settings;
    redClip->GetDefaultImageProcessingSettings(settings);
    NSString *look = request[@"look"] ?: @"display";
    if (settings.Version == ColorVersion3) {
        if ([look isEqualToString:@"log"]) {
            settings.ImagePipelineMode = Primary_Development_Only;
        } else if ([look isEqualToString:@"display"]) {
            settings.ImagePipelineMode = Full_Graded;
            settings.ColorSpace = ImageColorRec709;
            settings.GammaCurve = ImageGammaBT1886;
            settings.OutputToneMap = ToneMap_Medium;
            settings.HighlightRollOff = RollOff_Medium;
        }
    }
    if (request[@"iso"]) settings.ISO = [request[@"iso"] unsignedIntegerValue];
    if (request[@"kelvin"]) settings.Kelvin = [request[@"kelvin"] floatValue];
    if (request[@"tint"]) settings.Tint = [request[@"tint"] floatValue];
    if (request[@"exposure"]) settings.ExposureAdjust = [request[@"exposure"] floatValue];

    size_t index = [request[@"index"] unsignedIntegerValue];
    const uint16_t *rgb = frameRedGpu(index, mode, settings, pixels);
    if (!rgb) {
        redRGB.resize(pixels * 3 + 8);
        // 16-byte aligned, as the decoder wants.
        uint16_t *cpu = (uint16_t *)(((uintptr_t)redRGB.data() + 15) & ~(uintptr_t)15);
        rgb = cpu;
        VideoDecodeJob job;
        job.Mode = mode;
        job.PixelType = PixelType_16Bit_RGB_Interleaved;
        job.OutputBuffer = cpu;
        job.OutputBufferSize = pixels * 3 * 2;
        job.ImageProcessing = &settings;
        job.HdrProcessing = nullptr;
        DecodeStatus status = redClip->DecodeVideoFrame(index, job);
        if (status != DSDecodeOK) { fail([NSString stringWithFormat:@"The frame couldn’t be decoded (%d).", (int)status]); return; }
    }

    // 8-bit BGRA for playing (half the bytes, and what the screen takes), else 16-bit RGBA.
    bool eight = [request[@"depth"] intValue] == 8;
    size_t bytes = pixels * (eight ? 4 : 8);
    void *mapped = redBuffer.map([request[@"buffer"] UTF8String], [request[@"size"] unsignedLongValue]);
    if (!mapped || bytes > redBuffer.size) { fail(@"The frame buffer is too small."); return; }
    if (eight) {
        uint8_t *out = (uint8_t *)mapped;
        for (size_t i = 0; i < pixels; i++) {
            out[i * 4] = rgb[i * 3 + 2] >> 8; out[i * 4 + 1] = rgb[i * 3 + 1] >> 8; out[i * 4 + 2] = rgb[i * 3] >> 8; out[i * 4 + 3] = 255;
        }
    } else {
        uint16_t *out = (uint16_t *)mapped;
        for (size_t i = 0; i < pixels; i++) {
            out[i * 4] = rgb[i * 3]; out[i * 4 + 1] = rgb[i * 3 + 1]; out[i * 4 + 2] = rgb[i * 3 + 2]; out[i * 4 + 3] = 65535;
        }
    }
    reply(@{@"ok": @YES, @"width": @(width), @"height": @(height), @"depth": @(eight ? 8 : 16)});
}
#endif

// MARK: - Blackmagic RAW

#if PLUCK_BRAW
#include "BlackmagicRawAPI.h"
#include <atomic>

static NSString *variantText(Variant &value) {
    switch (value.vt) {
        case blackmagicRawVariantTypeU8: case blackmagicRawVariantTypeU16: return [NSString stringWithFormat:@"%u", value.uiVal];
        case blackmagicRawVariantTypeS16: return [NSString stringWithFormat:@"%d", value.iVal];
        case blackmagicRawVariantTypeS32: return [NSString stringWithFormat:@"%d", value.intVal];
        case blackmagicRawVariantTypeU32: return [NSString stringWithFormat:@"%u", value.uintVal];
        case blackmagicRawVariantTypeFloat32: return [NSString stringWithFormat:@"%g", value.fltVal];
        case blackmagicRawVariantTypeFloat64: return [NSString stringWithFormat:@"%g", value.dblVal];
        case blackmagicRawVariantTypeString: return value.bstrVal ? (__bridge NSString *)value.bstrVal : @"";
        default: return nil;
    }
}

static double variantNumber(Variant &value) {
    switch (value.vt) {
        case blackmagicRawVariantTypeU8: case blackmagicRawVariantTypeU16: return value.uiVal;
        case blackmagicRawVariantTypeS16: return value.iVal;
        case blackmagicRawVariantTypeS32: return value.intVal;
        case blackmagicRawVariantTypeU32: return value.uintVal;
        case blackmagicRawVariantTypeFloat32: return value.fltVal;
        case blackmagicRawVariantTypeFloat64: return value.dblVal;
        default: return 0;
    }
}

/// What a read is for: the clip's own settings (from its first frame), or a picture.
struct BrawRequest {
    bool defaults = false;
    BlackmagicRawResolutionScale scale = blackmagicRawResolutionScaleFull;
    bool hasISO = false, hasKelvin = false, hasTint = false, hasExposure = false;
    bool eight = false;
    uint32_t iso = 0, kelvin = 0; int16_t tint = 0; float exposure = 0;
    IBlackmagicRawClipProcessingAttributes *clipAttributes = nullptr;
    // Results.
    HRESULT result = S_OK;
    NSMutableDictionary *settings = nil;
    void *out = nullptr; size_t outSize = 0;
    uint32_t width = 0, height = 0;
};

class BrawCallback : public IBlackmagicRawCallback {
public:
    BrawRequest *request = nullptr;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    void finish(HRESULT result) { request->result = result; dispatch_semaphore_signal(done); }

    void ReadComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawFrame *frame) override {
        job->Release();
        if (FAILED(result)) { finish(result); return; }
        IBlackmagicRawFrameProcessingAttributes *attributes = nullptr;
        result = frame->CloneFrameProcessingAttributes(&attributes);
        if (FAILED(result)) { finish(result); return; }
        if (request->defaults) {
            NSMutableDictionary *found = [NSMutableDictionary dictionary];
            struct { BlackmagicRawFrameProcessingAttribute attribute; NSString *name; } list[] = {
                {blackmagicRawFrameProcessingAttributeISO, @"iso"}, {blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin, @"kelvin"},
                {blackmagicRawFrameProcessingAttributeWhiteBalanceTint, @"tint"}, {blackmagicRawFrameProcessingAttributeExposure, @"exposure"}};
            for (auto &item : list) {
                Variant value; VariantInit(&value);
                if (SUCCEEDED(attributes->GetFrameAttribute(item.attribute, &value))) found[item.name] = @(variantNumber(value));
                VariantClear(&value);
                Variant low, high; VariantInit(&low); VariantInit(&high); bool readOnly = false;
                if (SUCCEEDED(attributes->GetFrameAttributeRange(item.attribute, &low, &high, &readOnly)))
                    found[[item.name stringByAppendingString:@"Range"]] = @[@(variantNumber(low)), @(variantNumber(high))];
                VariantClear(&low); VariantClear(&high);
            }
            uint32_t count = 0; bool readOnly = false;
            if (SUCCEEDED(attributes->GetISOList(nullptr, &count, &readOnly)) && count > 0) {
                std::vector<uint32_t> isos(count);
                if (SUCCEEDED(attributes->GetISOList(isos.data(), &count, &readOnly))) {
                    NSMutableArray *values = [NSMutableArray array];
                    for (uint32_t i = 0; i < count; i++) [values addObject:@(isos[i])];
                    found[@"isos"] = values;
                }
            }
            attributes->Release();
            request->settings = found;
            finish(S_OK);
            return;
        }
        Variant value; VariantInit(&value);
        if (request->hasISO) { value.vt = blackmagicRawVariantTypeU32; value.uintVal = request->iso; attributes->SetFrameAttribute(blackmagicRawFrameProcessingAttributeISO, &value); }
        if (request->hasKelvin) { value.vt = blackmagicRawVariantTypeU32; value.uintVal = request->kelvin; attributes->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin, &value); }
        if (request->hasTint) { value.vt = blackmagicRawVariantTypeS16; value.iVal = request->tint; attributes->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint, &value); }
        if (request->hasExposure) { value.vt = blackmagicRawVariantTypeFloat32; value.fltVal = request->exposure; attributes->SetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure, &value); }
        frame->SetResolutionScale(request->scale);
        frame->SetResourceFormat(request->eight ? blackmagicRawResourceFormatBGRAU8 : blackmagicRawResourceFormatRGBAU16);
        IBlackmagicRawJob *decode = nullptr;
        result = frame->CreateJobDecodeAndProcessFrame(request->clipAttributes, attributes, &decode);
        attributes->Release();
        if (SUCCEEDED(result)) result = decode->Submit();
        if (FAILED(result)) { if (decode) decode->Release(); finish(result); }
    }

    void ProcessComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawProcessedImage *image) override {
        job->Release();
        if (SUCCEEDED(result)) {
            void *pixels = nullptr; uint32_t size = 0;
            image->GetWidth(&request->width);
            image->GetHeight(&request->height);
            result = image->GetResource(&pixels);
            if (SUCCEEDED(result)) result = image->GetResourceSizeBytes(&size);
            if (SUCCEEDED(result)) {
                if (!request->out || size > request->outSize) result = E_FAIL;
                else memcpy(request->out, pixels, size);
            }
        }
        finish(result);
    }

    void ReadAudioComplete(IBlackmagicRawJob *, HRESULT, IBlackmagicRawAudioBuffer *) override {}
    void DecodeComplete(IBlackmagicRawJob *, HRESULT) override {}
    void TrimProgress(IBlackmagicRawJob *, float) override {}
    void TrimComplete(IBlackmagicRawJob *, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void *, HRESULT) override {}

    HRESULT QueryInterface(REFIID, LPVOID *out) override { *out = nullptr; return E_NOINTERFACE; }
    ULONG AddRef() override { return 1; }
    ULONG Release() override { return 1; }
};

static IBlackmagicRawFactory *brawFactory = nullptr;
static IBlackmagicRaw *brawCodec = nullptr;
static IBlackmagicRawClip *brawClip = nullptr;
static IBlackmagicRawClipProcessingAttributes *brawClipAttributes = nullptr;
static BrawCallback brawCallback;
static Mapped brawBuffer;
static NSArray *brawGammas, *brawGamuts;
static NSString *brawShotGamma, *brawShotGamut;

static bool startBraw() {
    if (brawCodec) return true;
    NSString *folder = [NSString stringWithUTF8String:(helperFolder() + "/BRAW").c_str()];
    brawFactory = CreateBlackmagicRawFactoryInstanceFromPath((__bridge CFStringRef)folder);
    if (!brawFactory || FAILED(brawFactory->CreateCodec(&brawCodec)) || FAILED(brawCodec->SetCallback(&brawCallback))) {
        fail(@"The Blackmagic RAW decoder couldn’t start.");
        return false;
    }
    return true;
}

/// Runs one read (and decode) and waits for it.
static HRESULT runBraw(BrawRequest &request, uint64_t index) {
    brawCallback.request = &request;
    IBlackmagicRawJob *read = nullptr;
    HRESULT result = brawClip->CreateJobReadFrame(index, &read);
    if (SUCCEEDED(result)) result = read->Submit();
    if (FAILED(result)) { if (read) read->Release(); return result; }
    dispatch_semaphore_wait(brawCallback.done, DISPATCH_TIME_FOREVER);
    return request.result;
}

static NSArray *brawList(BlackmagicRawClipProcessingAttribute attribute) {
    uint32_t count = 0; bool readOnly = false;
    if (FAILED(brawClipAttributes->GetClipAttributeList(attribute, nullptr, &count, &readOnly)) || count == 0) return @[];
    std::vector<Variant> values(count);
    for (auto &value : values) VariantInit(&value);
    NSMutableArray *names = [NSMutableArray array];
    if (SUCCEEDED(brawClipAttributes->GetClipAttributeList(attribute, values.data(), &count, &readOnly)))
        for (uint32_t i = 0; i < count; i++) if (NSString *name = variantText(values[i])) [names addObject:[name copy]];
    for (auto &value : values) VariantClear(&value);
    return names;
}

static NSString *brawAttribute(BlackmagicRawClipProcessingAttribute attribute) {
    Variant value; VariantInit(&value);
    NSString *text = SUCCEEDED(brawClipAttributes->GetClipAttribute(attribute, &value)) ? [variantText(value) copy] : nil;
    VariantClear(&value);
    return text;
}

static void setBrawAttribute(BlackmagicRawClipProcessingAttribute attribute, NSString *text) {
    if (!text) return;
    Variant value; VariantInit(&value);
    value.vt = blackmagicRawVariantTypeString;
    value.bstrVal = (__bridge CFStringRef)text;
    brawClipAttributes->SetClipAttribute(attribute, &value);
}

static void openBraw(NSString *path) {
    if (!startBraw()) return;
    if (brawClipAttributes) { brawClipAttributes->Release(); brawClipAttributes = nullptr; }
    if (brawClip) { brawClip->Release(); brawClip = nullptr; }
    if (FAILED(brawCodec->OpenClip((__bridge CFStringRef)path, &brawClip))) { fail(@"This Blackmagic RAW file can’t be read."); return; }
    brawClip->QueryInterface(IID_IBlackmagicRawClipProcessingAttributes, (void **)&brawClipAttributes);
    uint32_t width = 0, height = 0; float fps = 0; uint64_t frames = 0;
    brawClip->GetWidth(&width); brawClip->GetHeight(&height); brawClip->GetFrameRate(&fps); brawClip->GetFrameCount(&frames);
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    IBlackmagicRawMetadataIterator *iterator = nullptr;
    if (SUCCEEDED(brawClip->GetMetadataIterator(&iterator)) && iterator) {
        do {
            CFStringRef key = nullptr; Variant value; VariantInit(&value);
            if (SUCCEEDED(iterator->GetKey(&key)) && key && SUCCEEDED(iterator->GetData(&value))) {
                if (NSString *text = variantText(value)) meta[[(__bridge NSString *)key copy]] = [text copy];
            }
            VariantClear(&value);
        } while (iterator->Next() == S_OK);
        iterator->Release();
    }
    brawGammas = brawClipAttributes ? brawList(blackmagicRawClipProcessingAttributeGamma) : @[];
    brawGamuts = brawClipAttributes ? brawList(blackmagicRawClipProcessingAttributeGamut) : @[];
    brawShotGamma = brawClipAttributes ? brawAttribute(blackmagicRawClipProcessingAttributeGamma) : nil;
    brawShotGamut = brawClipAttributes ? brawAttribute(blackmagicRawClipProcessingAttributeGamut) : nil;
    BrawRequest request;
    request.defaults = true;
    NSMutableDictionary *answer = [@{@"ok": @YES, @"format": @"braw", @"width": @(width), @"height": @(height),
                                     @"fps": @(fps), @"frames": @(frames), @"meta": meta,
                                     @"gammas": brawGammas, @"gamuts": brawGamuts} mutableCopy];
    if (brawShotGamma) answer[@"gamma"] = brawShotGamma;
    CFStringRef timecode = nullptr;
    if (SUCCEEDED(brawClip->GetTimecodeForFrame(0, &timecode)) && timecode) {
        answer[@"timecode"] = [(__bridge NSString *)timecode copy];
        CFRelease(timecode);
    }
    IBlackmagicRawClipAudio *audio = nullptr;
    uint32_t audioChannels = 0;
    if (SUCCEEDED(brawClip->QueryInterface(IID_IBlackmagicRawClipAudio, (void **)&audio)) && audio) {
        audio->GetAudioChannelCount(&audioChannels);
        audio->Release();
    }
    answer[@"audioChannels"] = @(audioChannels);
    if (SUCCEEDED(runBraw(request, 0)) && request.settings) [answer addEntriesFromDictionary:request.settings];
    reply(answer);
}

/// The first of these that the clip offers.
static NSString *firstOf(NSArray *offered, NSArray *wanted) {
    for (NSString *name in wanted) for (NSString *one in offered) if ([one caseInsensitiveCompare:name] == NSOrderedSame) return one;
    return nil;
}

/// The clip's sound as a .wav, as recorded.
static void audioBraw(NSDictionary *request) {
    IBlackmagicRawClipAudio *audio = nullptr;
    if (FAILED(brawClip->QueryInterface(IID_IBlackmagicRawClipAudio, (void **)&audio)) || !audio) { fail(@"This clip has no sound."); return; }
    uint32_t bits = 0, channels = 0, rate = 0; uint64_t total = 0;
    audio->GetAudioBitDepth(&bits); audio->GetAudioChannelCount(&channels); audio->GetAudioSampleRate(&rate); audio->GetAudioSampleCount(&total);
    WavFile wav;
    if (channels == 0 || total == 0 || bits == 0) { audio->Release(); fail(@"This clip has no sound."); return; }
    if (!wav.open([request[@"to"] fileSystemRepresentation], rate, (uint16_t)channels, (uint16_t)bits)) { audio->Release(); fail(@"The sound couldn’t be written."); return; }
    const uint32_t chunk = 48000;
    std::vector<uint8_t> buffer(chunk * channels * ((bits + 7) / 8));
    uint64_t at = 0;
    while (at < total) {
        uint32_t samples = 0, bytes = 0;
        if (FAILED(audio->GetAudioSamples((int64_t)at, buffer.data(), (uint32_t)buffer.size(), chunk, &samples, &bytes)) || samples == 0) break;
        wav.add(buffer.data(), bytes);
        at += samples;
    }
    wav.close();
    audio->Release();
    reply(@{@"ok": @YES, @"channels": @(channels), @"rate": @(rate)});
}

static void frameBraw(NSDictionary *request) {
    BrawRequest job;
    int scale = [request[@"scale"] intValue];
    job.scale = scale >= 8 ? blackmagicRawResolutionScaleEighth : scale >= 4 ? blackmagicRawResolutionScaleQuarter
        : scale >= 2 ? blackmagicRawResolutionScaleHalf : blackmagicRawResolutionScaleFull;
    job.eight = [request[@"depth"] intValue] == 8;
    if (request[@"iso"]) { job.hasISO = true; job.iso = [request[@"iso"] unsignedIntValue]; }
    if (request[@"kelvin"]) { job.hasKelvin = true; job.kelvin = [request[@"kelvin"] unsignedIntValue]; }
    if (request[@"tint"]) { job.hasTint = true; job.tint = (int16_t)[request[@"tint"] intValue]; }
    if (request[@"exposure"]) { job.hasExposure = true; job.exposure = [request[@"exposure"] floatValue]; }
    NSString *look = request[@"look"] ?: @"display";
    if (brawClipAttributes) {
        if ([look isEqualToString:@"display"]) {
            setBrawAttribute(blackmagicRawClipProcessingAttributeGamma, firstOf(brawGammas, @[@"Blackmagic Design Extended Video", @"Blackmagic Design Video", @"Rec.709"]));
            setBrawAttribute(blackmagicRawClipProcessingAttributeGamut, firstOf(brawGamuts, @[@"Rec.709"]));
        } else if ([look isEqualToString:@"log"]) {
            setBrawAttribute(blackmagicRawClipProcessingAttributeGamma, firstOf(brawGammas, @[@"Blackmagic Design Film"]));
            setBrawAttribute(blackmagicRawClipProcessingAttributeGamut, firstOf(brawGamuts, @[@"Blackmagic Design"]));
        } else {
            setBrawAttribute(blackmagicRawClipProcessingAttributeGamma, brawShotGamma);
            setBrawAttribute(blackmagicRawClipProcessingAttributeGamut, brawShotGamut);
        }
    }
    job.clipAttributes = brawClipAttributes;
    job.outSize = [request[@"size"] unsignedLongValue];
    job.out = brawBuffer.map([request[@"buffer"] UTF8String], job.outSize);
    if (!job.out) { fail(@"The frame buffer couldn’t be opened."); return; }
    if (FAILED(runBraw(job, [request[@"index"] unsignedLongLongValue]))) { fail(@"The frame couldn’t be decoded."); return; }
    reply(@{@"ok": @YES, @"width": @(job.width), @"height": @(job.height), @"depth": @(job.eight ? 8 : 16)});
}
#endif

// MARK: -

/// One request, answered with reply() or fail().
static void handle(NSDictionary *request) {
    NSString *op = [request isKindOfClass:NSDictionary.class] ? request[@"op"] : nil;
    if (!op) { fail(@"Bad request."); return; }
    NSString *path = request[@"path"];
    NSString *ext = path.pathExtension.lowercaseString;
    if ([op isEqualToString:@"open"]) {
        // One clip open at a time: a helper that opens clip after clip (thumbnails) must not
        // answer for the clip it had before, in the other format.
#if PLUCK_RED
        if (![ext isEqualToString:@"r3d"] && redClip) { delete redClip; redClip = nullptr; }
#endif
#if PLUCK_BRAW
        if (![ext isEqualToString:@"braw"] && brawClip) {
            if (brawClipAttributes) { brawClipAttributes->Release(); brawClipAttributes = nullptr; }
            brawClip->Release(); brawClip = nullptr;
        }
#endif
#if PLUCK_RED
        if ([ext isEqualToString:@"r3d"]) { openRed(path); return; }
#endif
#if PLUCK_BRAW
        if ([ext isEqualToString:@"braw"]) { openBraw(path); return; }
#endif
        fail(@"Pluck can’t play this kind of raw file yet.");
    } else if ([op isEqualToString:@"frame"]) {
#if PLUCK_RED
        if (redClip) { frameRed(request); return; }
#endif
#if PLUCK_BRAW
        if (brawClip) { frameBraw(request); return; }
#endif
        fail(@"No clip is open.");
    } else if ([op isEqualToString:@"audio"]) {
#if PLUCK_RED
        if (redClip) { audioRed(request); return; }
#endif
#if PLUCK_BRAW
        if (brawClip) { audioBraw(request); return; }
#endif
        fail(@"No clip is open.");
    } else {
        fail(@"Unknown request.");
    }
}

static void finish() {
#if PLUCK_RED
    delete redClip;
    redClip = nullptr;
    if (redReady) FinalizeSdk();
    redReady = false;
#endif
#if PLUCK_BRAW
    if (brawClipAttributes) brawClipAttributes->Release();
    if (brawClip) brawClip->Release();
    if (brawCodec) { brawCodec->FlushJobs(); brawCodec->Release(); }
    if (brawFactory) brawFactory->Release();
    brawClipAttributes = nullptr; brawClip = nullptr; brawCodec = nullptr; brawFactory = nullptr;
#endif
}

#if PLUCK_RAW_LIBRARY
// MARK: - As a library

/// Where the camera libraries are.
extern "C" void pluck_raw_set_libraries(const char *folder) { librariesFolder = folder; }

/// One request as JSON, its reply as JSON (free it). One clip per process; not for several
/// threads at once.
extern "C" char *pluck_raw_request(const char *json) {
    @autoreleasepool {
        libraryMode = true;
        libraryReply = nil;
        NSData *data = [NSData dataWithBytes:json length:strlen(json)];
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([request[@"op"] isEqualToString:@"quit"]) { finish(); libraryReply = @{@"ok": @YES}; }
        else handle(request);
        NSData *out = [NSJSONSerialization dataWithJSONObject:libraryReply ?: @{@"ok": @NO} options:0 error:nil];
        char *text = (char *)malloc(out.length + 1);
        memcpy(text, out.bytes, out.length);
        text[out.length] = 0;
        return text;
    }
}
#else
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i + 1 < argc; i++) if (strcmp(argv[i], "--libs") == 0) librariesFolder = argv[i + 1];
        if (argc > 1 && strcmp(argv[1], "formats") == 0) {
            NSMutableArray *formats = [NSMutableArray array];
#if PLUCK_RED
            [formats addObject:@"r3d"];
#endif
#if PLUCK_BRAW
            [formats addObject:@"braw"];
#endif
            reply(@{@"ok": @YES, @"formats": formats});
            return 0;
        }
        char *line = nullptr;
        size_t capacity = 0;
        while (getline(&line, &capacity, stdin) > 0) {
            @autoreleasepool {
                NSData *data = [NSData dataWithBytes:line length:strlen(line)];
                NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([request isKindOfClass:NSDictionary.class] && [request[@"op"] isEqualToString:@"quit"]) break;
                handle(request);
            }
        }
        free(line);
        finish();
    }
    return 0;
}
#endif
