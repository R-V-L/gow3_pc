/* Read-only ZArchive (.zar) reader used by the guest file system.
 *
 * ZArchive (https://github.com/Exzap/ZArchive, MIT-0) stores the game folder at its root in
 * 64 KiB zstd-compressed blocks. The reader lives in the GPU library and exposes this small C API
 * so the C runtime can mount a .zar as /app0 without a C++ dependency of its own.
 *
 * Nodes are opaque handles; ZARCHIVE_NONE means "not found". Every function is safe to call from
 * several guest threads: the bridge serialises access to the underlying reader. */
#ifndef SPARTANPORT_RUNTIME_ZARCHIVE_H
#define SPARTANPORT_RUNTIME_ZARCHIVE_H

#include <stddef.h>
#include <stdint.h>

typedef struct ZArchive ZArchive;

#define ZARCHIVE_NONE (-1)

/* Opens a .zar; NULL when the file is missing or not a ZArchive. zarchive_error() names why. */
ZArchive *zarchive_open(const char *path);
void zarchive_close(ZArchive *archive);

/* Bytes of the .zar file itself. */
uint64_t zarchive_size(const ZArchive *archive);

/* Why the last open in this thread failed, or "" after a success. */
const char *zarchive_error(void);

/* Node of a path inside the archive ("sce_sys/param.sfo", "eboot.bin", "" for the root);
 * ZARCHIVE_NONE when it does not exist. Names are matched case-insensitively. */
int64_t zarchive_find(ZArchive *archive, const char *path);

int zarchive_is_file(const ZArchive *archive, int64_t node);
uint64_t zarchive_entry_size(const ZArchive *archive, int64_t node);

/* Lists one child of a directory node: writes its name (NUL-terminated, truncated to size) and
 * returns 1, or 0 past the end. */
int zarchive_child(ZArchive *archive, int64_t node, uint32_t index, char *name, size_t size,
                   int *is_file);

/* Reads up to length bytes at offset; returns the bytes read (short only at the end of the file),
 * or 0 when the range cannot be read. */
uint64_t zarchive_read(ZArchive *archive, int64_t node, uint64_t offset, void *buffer,
                       uint64_t length);

/* Whole file into buffer of at most size bytes; its length, or -1 when missing or too large. */
int64_t zarchive_read_all(ZArchive *archive, const char *path, void *buffer, uint64_t size);

#endif
