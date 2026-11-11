// Host tests for WQArchive: round trips, compatibility with zip/unzip/ditto and
// Python's zipfile (including ZIP64 records), and refusal of unsafe archives.
#import <Foundation/Foundation.h>
#import "../WQArchive.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; NSLog(@"FAIL line %d: %s", __LINE__, #cond); __VA_OPT__(NSLog(__VA_ARGS__);) } } while (0)

static int run(NSString *tool, NSArray<NSString *> *args, NSString *cwd)
{
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:tool];
    t.arguments = args;
    if (cwd) t.currentDirectoryURL = [NSURL fileURLWithPath:cwd];
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:nil]) return -1;
    [t waitUntilExit];
    return t.terminationStatus;
}

static NSString *tmpdir(NSString *name)
{
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@-%@", name, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void put(NSString *path, NSData *data)
{
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:path atomically:NO];
}

static NSData *randomData(NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithLength:n];
    arc4random_buf(d.mutableBytes, n);
    return d;
}

static BOOL sameTree(NSString *a, NSString *b)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *la = [[fm subpathsOfDirectoryAtPath:a error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSArray *lb = [[fm subpathsOfDirectoryAtPath:b error:nil] sortedArrayUsingSelector:@selector(compare:)];
    if (![la isEqualToArray:lb]) { NSLog(@"trees differ:\n%@\n%@", la, lb); return NO; }
    for (NSString *rel in la) {
        BOOL dir = NO;
        [fm fileExistsAtPath:[a stringByAppendingPathComponent:rel] isDirectory:&dir];
        if (dir) continue;
        if (![[NSData dataWithContentsOfFile:[a stringByAppendingPathComponent:rel]]
              isEqualToData:[NSData dataWithContentsOfFile:[b stringByAppendingPathComponent:rel]]]) {
            NSLog(@"contents differ: %@", rel); return NO;
        }
    }
    return YES;
}

static NSString *python(NSString *script, NSString *cwd)
{
    NSString *py = [cwd stringByAppendingPathComponent:@"make.py"];
    [script writeToFile:py atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return run(@"/usr/bin/python3", @[@"-I", py], cwd) == 0 ? cwd : nil;
}

int main(void)
{
    @autoreleasepool {
        WQArchiveIO *io = wq_archive_posix_io();
        NSFileManager *fm = NSFileManager.defaultManager;

        // Safe names.
        CHECK([wq_zip_safe_entry_path(@"a/b/c.txt") isEqualToString:@"a/b/c.txt"]);
        CHECK([wq_zip_safe_entry_path(@"a\\b.txt") isEqualToString:@"a/b.txt"]);
        CHECK([wq_zip_safe_entry_path(@"dir/") isEqualToString:@"dir"]);
        CHECK(wq_zip_safe_entry_path(@"../x") == nil);
        CHECK(wq_zip_safe_entry_path(@"a/../../x") == nil);
        CHECK(wq_zip_safe_entry_path(@"/etc/passwd") == nil);
        CHECK(wq_zip_safe_entry_path(@"C:/x") == nil);
        CHECK(wq_zip_safe_entry_path(@"./x") == nil);
        CHECK(wq_zip_safe_entry_path(@"") == nil);

        // Fixture: nested folders, an empty folder, an empty file, a big
        // random file, Unicode names, and a symbolic link (left out).
        NSString *src = tmpdir(@"src");
        NSString *tree = [src stringByAppendingPathComponent:@"Folder"];
        put([tree stringByAppendingPathComponent:@"a.txt"], [@"hello hello hello hello" dataUsingEncoding:NSUTF8StringEncoding]);
        put([tree stringByAppendingPathComponent:@"sub/deeper/b.bin"], randomData(3 * 1024 * 1024 + 17));
        put([tree stringByAppendingPathComponent:@"sub/empty.dat"], [NSData data]);
        put([tree stringByAppendingPathComponent:@"Grüße 日本.txt"], [@"unicode" dataUsingEncoding:NSUTF8StringEncoding]);
        [fm createDirectoryAtPath:[tree stringByAppendingPathComponent:@"emptydir"] withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createSymbolicLinkAtPath:[tree stringByAppendingPathComponent:@"link"] withDestinationPath:@"/etc/hosts" error:nil];
        NSString *single = [src stringByAppendingPathComponent:@"single.txt"];
        put(single, [@"just one file" dataUsingEncoding:NSUTF8StringEncoding]);

        // Round trip: folder + file into one archive.
        NSString *work = tmpdir(@"work");
        NSString *zip = [work stringByAppendingPathComponent:@"Archive.zip"];
        NSString *err = nil;
        NSUInteger skipped = 0;
        __block unsigned long long lastProgress = 0;
        BOOL ok = wq_zip_write(@[tree, single], zip, io, nil, ^(unsigned long long b) { lastProgress = b; }, &skipped, &err);
        CHECK(ok, @"zip write: %@", err);
        CHECK(skipped == 1, @"skipped %lu", (unsigned long)skipped);
        CHECK(lastProgress >= 3 * 1024 * 1024, @"progress %llu", lastProgress);
        CHECK(run(@"/usr/bin/unzip", @[@"-tqq", zip], nil) == 0, @"unzip -t rejects our ZIP");

        // The system's unzip sees the same tree (minus the link).
        NSString *viaUnzip = tmpdir(@"viaunzip");
        CHECK(run(@"/usr/bin/unzip", @[@"-qq", zip, @"-d", viaUnzip], nil) == 0);
        NSString *expected = tmpdir(@"expected");
        [fm copyItemAtPath:tree toPath:[expected stringByAppendingPathComponent:@"Folder"] error:nil];
        [fm removeItemAtPath:[expected stringByAppendingPathComponent:@"Folder/link"] error:nil];
        [fm copyItemAtPath:single toPath:[expected stringByAppendingPathComponent:@"single.txt"] error:nil];
        CHECK(sameTree(expected, viaUnzip), @"unzip output differs");

        // Our extractor.
        NSString *out = tmpdir(@"out");
        NSUInteger files = 0;
        __block unsigned long long extracted = 0;
        ok = wq_zip_extract(zip, out, io, 1ull << 40, nil, ^(unsigned long long b) { extracted = b; }, &files, &skipped, &err);
        CHECK(ok, @"extract: %@", err);
        CHECK(files == 5, @"files %lu", (unsigned long)files);
        CHECK(sameTree(expected, out), @"extract output differs");
        CHECK(extracted == 3 * 1024 * 1024 + 17 + 23 + 7 + 13, @"extracted bytes %llu", extracted);

        // Existing destination file name is refused (O_EXCL), not overwritten.
        CHECK(![fm fileExistsAtPath:[work stringByAppendingPathComponent:@"x"]]);
        CHECK(!wq_zip_write(@[single], zip, io, nil, nil, nil, &err), @"overwrote an existing zip");

        // Free-space limit.
        NSString *small = tmpdir(@"small");
        CHECK(!wq_zip_extract(zip, small, io, 1024, nil, nil, nil, nil, &err), @"size limit ignored");
        CHECK([fm contentsOfDirectoryAtPath:small error:nil].count == 0, @"size limit wrote files");

        // Cancellation removes the partial ZIP.
        NSString *cancelled = [work stringByAppendingPathComponent:@"cancel.zip"];
        CHECK(!wq_zip_write(@[tree], cancelled, io, ^BOOL { return YES; }, nil, nil, &err));
        CHECK(![fm fileExistsAtPath:cancelled], @"cancelled zip left behind");

        // Duplicate top-level names are refused.
        NSString *other = tmpdir(@"other");
        put([other stringByAppendingPathComponent:@"single.txt"], [NSData data]);
        CHECK(!wq_zip_write(@[single, [other stringByAppendingPathComponent:@"single.txt"]],
                            [work stringByAppendingPathComponent:@"dup.zip"], io, nil, nil, nil, &err));

        // Archives made by zip(1) and ditto (data descriptors, __MACOSX).
        NSString *zip1 = [work stringByAppendingPathComponent:@"zip1.zip"];
        CHECK(run(@"/usr/bin/zip", @[@"-qry", zip1, @"Folder", @"single.txt"], src) == 0);
        NSString *out1 = tmpdir(@"out1");
        CHECK(wq_zip_extract(zip1, out1, io, 1ull << 40, nil, nil, &files, &skipped, &err), @"zip(1): %@", err);
        CHECK(skipped == 1, @"zip -y link not skipped");
        CHECK(sameTree(expected, out1), @"zip(1) output differs");

        NSString *ditto = [work stringByAppendingPathComponent:@"ditto.zip"];
        CHECK(run(@"/usr/bin/ditto", @[@"-c", @"-k", @"--sequesterRsrc", @"--keepParent", tree, ditto], nil) == 0);
        NSString *out2 = tmpdir(@"out2");
        CHECK(wq_zip_extract(ditto, out2, io, 1ull << 40, nil, nil, &files, &skipped, &err), @"ditto: %@", err);
        NSString *expectedFolder = tmpdir(@"expfolder");
        [fm copyItemAtPath:[expected stringByAppendingPathComponent:@"Folder"] toPath:[expectedFolder stringByAppendingPathComponent:@"Folder"] error:nil];
        CHECK(sameTree(expectedFolder, out2), @"ditto output differs");

        // Python: ZIP64 records, stored entries, an unsafe name, an encrypted flag.
        NSString *py = tmpdir(@"py");
        CHECK(python(@"import zipfile\n"
                     "with zipfile.ZipFile('z64.zip','w',zipfile.ZIP_DEFLATED) as z:\n"
                     "    with z.open('big/x.txt','w',force_zip64=True) as f: f.write(b'x'*100000)\n"
                     "    z.writestr(zipfile.ZipInfo('stored.txt'), b'plain', compress_type=zipfile.ZIP_STORED)\n"
                     "with zipfile.ZipFile('evil.zip','w') as z:\n"
                     "    z.writestr('ok.txt', b'fine')\n"
                     "    z.writestr('../escape.txt', b'bad')\n"
                     "with zipfile.ZipFile('enc.zip','w') as z:\n"
                     "    i = zipfile.ZipInfo('secret.txt'); i.flag_bits |= 1\n"
                     "    z.writestr(i, b'xx')\n"
                     "d = bytearray(open('enc.zip','rb').read())\n"
                     "for sig, off in ((b'PK\\x03\\x04', 6), (b'PK\\x01\\x02', 8)):\n"
                     "    k = d.find(sig); d[k + off] |= 1\n"
                     "open('enc.zip','wb').write(d)\n"
                     "with zipfile.ZipFile('crc.zip','w',zipfile.ZIP_STORED) as z: z.writestr('c.txt', b'abcdef')\n"
                     "d = bytearray(open('crc.zip','rb').read()); j = d.find(b'abcdef'); d[j] ^= 1; open('crc.zip','wb').write(d)\n", py) != nil,
              @"python fixture failed");
        NSString *out3 = tmpdir(@"out3");
        CHECK(wq_zip_extract([py stringByAppendingPathComponent:@"z64.zip"], out3, io, 1ull << 40, nil, nil, &files, nil, &err), @"zip64: %@", err);
        CHECK([[NSData dataWithContentsOfFile:[out3 stringByAppendingPathComponent:@"big/x.txt"]] length] == 100000);
        CHECK([[NSString stringWithContentsOfFile:[out3 stringByAppendingPathComponent:@"stored.txt"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"plain"]);

        NSString *out4 = tmpdir(@"out4");
        CHECK(!wq_zip_extract([py stringByAppendingPathComponent:@"evil.zip"], out4, io, 1ull << 40, nil, nil, nil, nil, &err), @"unsafe zip extracted");
        CHECK([fm contentsOfDirectoryAtPath:out4 error:nil].count == 0, @"unsafe zip wrote files");
        CHECK(![fm fileExistsAtPath:[out4.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"escape.txt"]]);

        NSString *out5 = tmpdir(@"out5");
        CHECK(!wq_zip_extract([py stringByAppendingPathComponent:@"enc.zip"], out5, io, 1ull << 40, nil, nil, nil, nil, &err), @"encrypted zip extracted");

        NSString *out6 = tmpdir(@"out6");
        CHECK(!wq_zip_extract([py stringByAppendingPathComponent:@"crc.zip"], out6, io, 1ull << 40, nil, nil, nil, nil, &err), @"bad CRC accepted");
        CHECK([err containsString:@"校验和"], @"crc error text: %@", err);

        // Not a ZIP / truncated.
        NSString *junk = [work stringByAppendingPathComponent:@"junk.zip"];
        put(junk, randomData(5000));
        CHECK(!wq_zip_extract(junk, tmpdir(@"out7"), io, 1ull << 40, nil, nil, nil, nil, &err));
        NSData *whole = [NSData dataWithContentsOfFile:zip];
        NSString *cut = [work stringByAppendingPathComponent:@"cut.zip"];
        put(cut, [whole subdataWithRange:NSMakeRange(0, whole.length / 2)]);
        CHECK(!wq_zip_extract(cut, tmpdir(@"out8"), io, 1ull << 40, nil, nil, nil, nil, &err));
    }
    if (failures) { printf("WQArchiveTests: %d failure(s)\n", failures); return 1; }
    printf("WQArchiveTests: all passed\n");
    return 0;
}
