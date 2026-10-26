/* C bridge between the guest file system (src/runtime_file.c) and the vendored ZArchive reader.
 * The reader is C++ and lives in the GPU library; the runtime stays plain C. Every entry point is
 * serialised because guest threads read the archive concurrently. */
#include "runtime_zarchive.h"

#include <zarchive/zarchivereader.h>

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <new>
#include <string>
#include <string_view>

struct ZArchive {
    ZArchiveReader* reader{};
    uint64_t size{};
    mutable std::mutex mutex;
};

namespace {
thread_local std::string open_error;

void set_error(std::string message) {
    open_error = std::move(message);
}

std::string_view relative_path(const char* path) {
    std::string_view view = path ? path : "";
    while (!view.empty() && view.front() == '/') {
        view.remove_prefix(1);
    }
    return view;
}
} // namespace

extern "C" {

ZArchive* zarchive_open(const char* path) {
    open_error.clear();
    if (!path || !*path) {
        set_error("empty path");
        return nullptr;
    }
    std::error_code ec;
    const uint64_t size = std::filesystem::file_size(path, ec);
    if (ec) {
        set_error("cannot stat the archive: " + ec.message());
        return nullptr;
    }
    ZArchiveReader* reader = nullptr;
    try {
        reader = ZArchiveReader::OpenFromFile(std::filesystem::path(path));
    } catch (const std::exception& error) {
        set_error(std::string("not a ZArchive: ") + error.what());
        return nullptr;
    }
    if (!reader) {
        set_error("not a ZArchive (bad footer or tables)");
        return nullptr;
    }
    auto* archive = new (std::nothrow) ZArchive;
    if (!archive) {
        delete reader;
        set_error("out of memory");
        return nullptr;
    }
    archive->reader = reader;
    archive->size = size;
    return archive;
}

void zarchive_close(ZArchive* archive) {
    if (!archive) {
        return;
    }
    delete archive->reader;
    delete archive;
}

uint64_t zarchive_size(const ZArchive* archive) {
    return archive ? archive->size : 0;
}

const char* zarchive_error(void) {
    return open_error.c_str();
}

int64_t zarchive_find(ZArchive* archive, const char* path) {
    if (!archive || !archive->reader) {
        return ZARCHIVE_NONE;
    }
    std::lock_guard lock(archive->mutex);
    try {
        const auto node = archive->reader->LookUp(relative_path(path), true, true);
        return node == ZARCHIVE_INVALID_NODE ? ZARCHIVE_NONE : static_cast<int64_t>(node);
    } catch (const std::exception&) {
        return ZARCHIVE_NONE;
    }
}

int zarchive_is_file(const ZArchive* archive, int64_t node) {
    if (!archive || !archive->reader || node < 0) {
        return 0;
    }
    std::lock_guard lock(archive->mutex);
    return archive->reader->IsFile(static_cast<ZArchiveNodeHandle>(node)) ? 1 : 0;
}

uint64_t zarchive_entry_size(const ZArchive* archive, int64_t node) {
    if (!archive || !archive->reader || node < 0) {
        return 0;
    }
    std::lock_guard lock(archive->mutex);
    return archive->reader->GetFileSize(static_cast<ZArchiveNodeHandle>(node));
}

int zarchive_child(ZArchive* archive, int64_t node, uint32_t index, char* name, size_t size,
                   int* is_file) {
    if (!archive || !archive->reader || node < 0) {
        return 0;
    }
    std::lock_guard lock(archive->mutex);
    ZArchiveReader::DirEntry entry{};
    try {
        if (!archive->reader->GetDirEntry(static_cast<ZArchiveNodeHandle>(node), index, entry)) {
            return 0;
        }
    } catch (const std::exception&) {
        return 0;
    }
    if (name && size) {
        const size_t length = std::min(entry.name.size(), size - 1);
        std::memcpy(name, entry.name.data(), length);
        name[length] = '\0';
    }
    if (is_file) {
        *is_file = entry.isFile ? 1 : 0;
    }
    return 1;
}

uint64_t zarchive_read(ZArchive* archive, int64_t node, uint64_t offset, void* buffer,
                       uint64_t length) {
    if (!archive || !archive->reader || node < 0 || !buffer || !length) {
        return 0;
    }
    std::lock_guard lock(archive->mutex);
    try {
        return archive->reader->ReadFromFile(static_cast<ZArchiveNodeHandle>(node), offset, length,
                                            buffer);
    } catch (const std::exception&) {
        return 0;
    }
}

int64_t zarchive_read_all(ZArchive* archive, const char* path, void* buffer, uint64_t size) {
    if (!archive || !buffer) {
        return -1;
    }
    const int64_t node = zarchive_find(archive, path);
    if (node == ZARCHIVE_NONE || !zarchive_is_file(archive, node)) {
        return -1;
    }
    const uint64_t length = zarchive_entry_size(archive, node);
    if (length > size) {
        return -1;
    }
    std::lock_guard lock(archive->mutex);
    try {
        const uint64_t read =
            archive->reader->ReadFromFile(static_cast<ZArchiveNodeHandle>(node), 0, length, buffer);
        return read == length ? static_cast<int64_t>(length) : -1;
    } catch (const std::exception&) {
        return -1;
    }
}

} // extern "C"
