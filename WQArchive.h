//
//  WQArchive.h
//  WQ Files
//
//  Minimal ZIP writer and reader (stored and deflate, via zlib). Files are
//  read through a small I/O table, so the same code works on other apps'
//  containers (through WQAccess) and on plain files in host tests.
//
//  Writing: ZIP64 — no 4 GB or 65535-entry limit. Entries whose size is
//  within 16 MB of 4 GB, entries past a 4 GB offset, and archives with
//  65535+ entries use the 0x0001 extra field (0xFFFFFFFF placeholders +
//  64-bit values) and, when the end-of-central-directory fields overflow,
//  the ZIP64 end-of-central-directory record. Reading also understands
//  ZIP64. Extraction never creates symbolic links, refuses entry
//  names that would leave the target folder, checks every entry's size and
//  CRC, and writes only into the (local, empty) folder it is given.
//

#import <Foundation/Foundation.h>
#import <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQArchiveIO : NSObject
// lstat-like: does not follow a final symbolic link. NO if missing.
@property (nonatomic, copy) BOOL (^stat)(NSString *path, struct stat *st);
// Names of the entries in a folder, or nil.
@property (nonatomic, copy) NSArray<NSString *> *_Nullable (^list)(NSString *dir);
// A read-only descriptor for a regular file (not following links), or -1.
@property (nonatomic, copy) int (^openRead)(NSString *path);
@end

// Plain POSIX calls; for local files and tests.
WQArchiveIO *wq_archive_posix_io(void);

typedef BOOL (^WQArchiveCancelled)(void);
// Bytes read (writing) or written (extracting) so far.
typedef void (^WQArchiveProgress)(unsigned long long bytes);

// Writes a ZIP of `paths` (files and folders, recursively; each one appears
// under its own name at the top of the archive) to the new local file
// `zipPath`. Symbolic links and special files are left out and counted in
// *skipped. A failed or cancelled write removes zipPath.
BOOL wq_zip_write(NSArray<NSString *> *paths, NSString *zipPath, WQArchiveIO *io,
                  WQArchiveCancelled _Nullable cancelled, WQArchiveProgress _Nullable progress,
                  NSUInteger *_Nullable skipped, NSString *_Nullable *_Nullable errorText);

// Extracts the ZIP at zipPath (read through io) into the existing local folder
// outDir. Refuses archives that would unpack to more than maxBytes, encrypted
// entries and unsupported compression. Symbolic links in the archive are left
// out (counted in *skipped); macOS "__MACOSX" metadata is ignored. On failure
// outDir may hold a partial result; the caller removes it.
BOOL wq_zip_extract(NSString *zipPath, NSString *outDir, WQArchiveIO *io, unsigned long long maxBytes,
                    WQArchiveCancelled _Nullable cancelled, WQArchiveProgress _Nullable progress,
                    NSUInteger *_Nullable files, NSUInteger *_Nullable skipped,
                    NSString *_Nullable *_Nullable errorText);

// A safe relative path for an entry name ("a/b/c"; backslashes count as
// separators), or nil for absolute names, "." / ".." components or empty names.
NSString *_Nullable wq_zip_safe_entry_path(NSString *name);

NS_ASSUME_NONNULL_END
