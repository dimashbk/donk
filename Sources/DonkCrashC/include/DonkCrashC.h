#ifndef DONK_CRASH_C_H
#define DONK_CRASH_C_H

#include <signal.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DONK_CRASH_FORMAT_VERSION 1
#define DONK_CRASH_MAX_IMAGES 2048
#define DONK_CRASH_MAX_FRAMES 128

typedef struct {
    uint64_t load_address;
    int64_t slide;
    uint64_t text_size;
    uint8_t uuid[16];
    const char *_Nullable path;
    int32_t cpu_type;
    int32_t cpu_subtype;
    uint32_t file_type;
    uint64_t crash_info;
} donk_crash_image_t;

int donk_crash_install(const char *_Nullable pending_path, const char *_Nullable exception_path);
int donk_crash_open_records(const char *_Nullable pending_path, const char *_Nullable exception_path);
void donk_crash_uninstall(void);
int donk_crash_is_installed(void);
int donk_crash_installed_after_other_handler(void);
int donk_crash_install_alternate_stack(void);
size_t donk_crash_alternate_stack_size(void);
int donk_crash_debugger_attached(void);
int donk_crash_track_session_marker(const char *_Nullable path);

void donk_crash_register_images(void);
size_t donk_crash_image_count(void);
int donk_crash_image_at(size_t index, donk_crash_image_t *_Nonnull out);

int donk_crash_write_exception(const void *_Nonnull bytes, size_t length);

uint64_t donk_crash_address_mask(void);
const int *_Nonnull donk_crash_signals(size_t *_Nonnull count);
void *_Nullable donk_crash_handler_address(void);
void *_Nullable donk_crash_current_handler(int sig);
int donk_crash_previous_action(int sig, struct sigaction *_Nonnull out);

int donk_crash_debug_write_report(
    int fd,
    int sig,
    int code,
    uint64_t fault_address,
    uint64_t pc,
    uint64_t lr,
    uint64_t fp,
    uint64_t sp,
    const void *_Nullable annotations
);
void donk_crash_debug_reset_guard(void);
void donk_crash_debug_remove_session_marker(void);

#ifdef __cplusplus
}
#endif

#endif
