#include "DonkCrashC.h"

#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

#define DONK_SIGNAL_COUNT 7
#define DONK_ALT_STACK_SIZE (256 * 1024)
#define DONK_MESSAGE_LIMIT 8192
#define DONK_PATH_LIMIT 2048
#define DONK_READ_CHUNK 256
#define DONK_READ_PAGE 4096
#define DONK_WAIT_STEPS 200

// MARK: - State

typedef struct {
    _Atomic int state;
    uintptr_t load_address;
    intptr_t slide;
    uint64_t text_size;
    uint8_t uuid[16];
    const char *path;
    int32_t cpu_type;
    int32_t cpu_subtype;
    uint32_t file_type;
    uintptr_t crash_info;
} donk_image_slot_t;

typedef struct {
    int sig;
    int code;
    uintptr_t fault_address;
    int has_registers;
    uintptr_t pc;
    uintptr_t lr;
    uintptr_t fp;
    uintptr_t sp;
    uint64_t esr;
    uint64_t far;
    int has_exception_state;
} donk_machine_t;

typedef struct {
    uint64_t version;
    uint64_t message;
    uint64_t signature_string;
    uint64_t backtrace;
    uint64_t message2;
} donk_annotations_t;

typedef struct {
    int fd;
    size_t length;
    char buffer[1024];
} donk_writer_t;

static const int donk_signal_list[DONK_SIGNAL_COUNT] = { SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP };

static donk_image_slot_t g_images[DONK_CRASH_MAX_IMAGES];
static _Atomic size_t g_image_reserved = 0;
static _Atomic int g_images_registered = 0;
static pthread_mutex_t g_install_mutex = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int g_installed = 0;
static _Atomic int g_pending_fd = -1;
static _Atomic int g_exception_fd = -1;
static struct sigaction g_previous[DONK_SIGNAL_COUNT];
static int g_has_previous[DONK_SIGNAL_COUNT];
static uintptr_t g_address_mask = 0;
static _Atomic int g_installed_after_other = 0;
static _Atomic int g_handling = 0;
static _Atomic uintptr_t g_handling_thread = 0;
static char g_session_path[DONK_PATH_LIMIT];
static _Atomic int g_session_registered = 0;
static _Atomic int g_session_armed = 0;

static void donk_signal_handler(int sig, siginfo_t *info, void *context);

// MARK: - Memory

static int donk_read_memory(uintptr_t address, void *out, size_t size) {
    if (address == 0 || size == 0) {
        return 0;
    }
    vm_size_t read = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(), (vm_address_t)address, (vm_size_t)size, (vm_address_t)out, &read);
    return result == KERN_SUCCESS && read == size;
}

static uintptr_t donk_compute_address_mask(void) {
#if defined(__arm64__)
    uint64_t bits = 0;
    size_t length = sizeof(bits);
    if (sysctlbyname("machdep.virtual_address_size", &bits, &length, NULL, 0) == 0) {
        if (length == sizeof(uint32_t)) {
            bits &= 0xFFFFFFFFu;
        }
        if (bits >= 32 && bits < 64) {
            return (uintptr_t)((1ULL << bits) - 1);
        }
    }
#if TARGET_OS_SIMULATOR || TARGET_OS_OSX
    return (uintptr_t)0x00007FFFFFFFFFFFULL;
#else
    return (uintptr_t)0x0000000FFFFFFFFFULL;
#endif
#else
    return (uintptr_t)0x00007FFFFFFFFFFFULL;
#endif
}

static inline uintptr_t donk_strip(uintptr_t value) {
    uintptr_t mask = g_address_mask ? g_address_mask : (uintptr_t)0x00007FFFFFFFFFFFULL;
    return value & mask;
}

// MARK: - Writer

static void dw_flush(donk_writer_t *w) {
    size_t offset = 0;
    while (offset < w->length) {
        ssize_t written = write(w->fd, w->buffer + offset, w->length - offset);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (written == 0) {
            break;
        }
        offset += (size_t)written;
    }
    w->length = 0;
}

static void dw_char(donk_writer_t *w, char c) {
    if (w->length == sizeof(w->buffer)) {
        dw_flush(w);
    }
    w->buffer[w->length++] = c;
}

static void dw_str(donk_writer_t *w, const char *text) {
    while (*text) {
        dw_char(w, *text++);
    }
}

static void dw_hex(donk_writer_t *w, uint64_t value) {
    static const char digits[] = "0123456789abcdef";
    char temp[16];
    int count = 0;
    do {
        temp[count++] = digits[value & 0xF];
        value >>= 4;
    } while (value != 0 && count < 16);
    dw_char(w, '0');
    dw_char(w, 'x');
    while (count > 0) {
        dw_char(w, temp[--count]);
    }
}

static void dw_hex_fixed(donk_writer_t *w, uint64_t value, int width) {
    static const char digits[] = "0123456789abcdef";
    for (int shift = (width - 1) * 4; shift >= 0; shift -= 4) {
        dw_char(w, digits[(value >> shift) & 0xF]);
    }
}

static void dw_unsigned(donk_writer_t *w, uint64_t value) {
    char temp[24];
    int count = 0;
    do {
        temp[count++] = (char)('0' + (value % 10));
        value /= 10;
    } while (value != 0 && count < 24);
    while (count > 0) {
        dw_char(w, temp[--count]);
    }
}

static void dw_signed(donk_writer_t *w, int64_t value) {
    if (value < 0) {
        dw_char(w, '-');
        dw_unsigned(w, (uint64_t)(-(value + 1)) + 1);
    } else {
        dw_unsigned(w, (uint64_t)value);
    }
}

static void dw_line_hex(donk_writer_t *w, const char *key, uint64_t value) {
    dw_str(w, key);
    dw_char(w, ' ');
    dw_hex(w, value);
    dw_char(w, '\n');
}

static void dw_line_signed(donk_writer_t *w, const char *key, int64_t value) {
    dw_str(w, key);
    dw_char(w, ' ');
    dw_signed(w, value);
    dw_char(w, '\n');
}

static void dw_escaped(donk_writer_t *w, unsigned char c) {
    static const char digits[] = "0123456789abcdef";
    switch (c) {
    case '\\':
        dw_char(w, '\\');
        dw_char(w, '\\');
        break;
    case '\n':
        dw_char(w, '\\');
        dw_char(w, 'n');
        break;
    case '\r':
        dw_char(w, '\\');
        dw_char(w, 'r');
        break;
    case '\t':
        dw_char(w, '\\');
        dw_char(w, 't');
        break;
    default:
        if (c < 0x20 || c == 0x7F) {
            dw_char(w, '\\');
            dw_char(w, 'x');
            dw_char(w, digits[(c >> 4) & 0xF]);
            dw_char(w, digits[c & 0xF]);
        } else {
            dw_char(w, (char)c);
        }
        break;
    }
}

static void dw_local_escaped(donk_writer_t *w, const char *text, size_t limit) {
    for (size_t i = 0; i < limit && text[i] != 0; i++) {
        dw_escaped(w, (unsigned char)text[i]);
    }
}

static void dw_remote_escaped(donk_writer_t *w, uintptr_t address, size_t limit) {
    char chunk[DONK_READ_CHUNK];
    size_t total = 0;
    while (total < limit) {
        size_t page_left = DONK_READ_PAGE - (size_t)(address % DONK_READ_PAGE);
        size_t want = sizeof(chunk);
        if (want > page_left) {
            want = page_left;
        }
        if (want > limit - total) {
            want = limit - total;
        }
        if (!donk_read_memory(address, chunk, want)) {
            return;
        }
        for (size_t i = 0; i < want; i++) {
            if (chunk[i] == 0) {
                return;
            }
            dw_escaped(w, (unsigned char)chunk[i]);
        }
        total += want;
        address += want;
    }
}

// MARK: - Report

static void donk_write_frames(donk_writer_t *w, const donk_machine_t *m) {
    if (!m->has_registers) {
        return;
    }
    dw_line_hex(w, "frame", m->pc);
    uintptr_t fp = donk_strip(m->fp);
    int count = 1;
    while (count < DONK_CRASH_MAX_FRAMES && fp != 0) {
        if ((fp & (sizeof(uintptr_t) - 1)) != 0) {
            break;
        }
        uintptr_t record[2] = { 0, 0 };
        if (!donk_read_memory(fp, record, sizeof(record))) {
            break;
        }
        uintptr_t next = donk_strip(record[0]);
        uintptr_t ret = donk_strip(record[1]);
        if (ret == 0) {
            break;
        }
        dw_line_hex(w, "frame", ret);
        count++;
        if (next <= fp) {
            break;
        }
        fp = next;
    }
}

static void donk_write_annotations(donk_writer_t *w, long index, uintptr_t address) {
    donk_annotations_t annotations;
    memset(&annotations, 0, sizeof(annotations));
    if (!donk_read_memory(address, &annotations, sizeof(annotations))) {
        return;
    }
    if (annotations.version == 0 || annotations.version > 64) {
        return;
    }
    const struct {
        const char *key;
        uint64_t pointer;
    } fields[] = {
        { "message", annotations.message },
        { "signature", annotations.signature_string },
        { "message2", annotations.message2 },
        { "backtrace", annotations.backtrace },
    };
    for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
        if (fields[i].pointer == 0) {
            continue;
        }
        dw_str(w, "crashinfo ");
        dw_signed(w, index);
        dw_char(w, ' ');
        dw_str(w, fields[i].key);
        dw_char(w, ' ');
        dw_remote_escaped(w, (uintptr_t)fields[i].pointer, DONK_MESSAGE_LIMIT);
        dw_char(w, '\n');
    }
}

static void donk_write_images(donk_writer_t *w, int annotations_only) {
    size_t reserved = atomic_load_explicit(&g_image_reserved, memory_order_acquire);
    if (reserved > DONK_CRASH_MAX_IMAGES) {
        reserved = DONK_CRASH_MAX_IMAGES;
    }
    for (size_t i = 0; i < reserved; i++) {
        donk_image_slot_t *slot = &g_images[i];
        if (atomic_load_explicit(&slot->state, memory_order_acquire) != 1) {
            continue;
        }
        if (annotations_only) {
            if (slot->crash_info != 0) {
                donk_write_annotations(w, (long)i, slot->crash_info);
            }
            continue;
        }
        dw_str(w, "image ");
        dw_unsigned(w, i);
        dw_char(w, ' ');
        dw_hex(w, slot->load_address);
        dw_char(w, ' ');
        dw_hex(w, (uint64_t)slot->slide);
        dw_char(w, ' ');
        dw_hex(w, slot->text_size);
        dw_char(w, ' ');
        for (int b = 0; b < 16; b++) {
            dw_hex_fixed(w, slot->uuid[b], 2);
        }
        dw_char(w, ' ');
        dw_signed(w, slot->cpu_type);
        dw_char(w, ' ');
        dw_signed(w, slot->cpu_subtype);
        dw_char(w, ' ');
        dw_unsigned(w, slot->file_type);
        dw_char(w, ' ');
        if (slot->path != NULL) {
            dw_remote_escaped(w, (uintptr_t)slot->path, DONK_PATH_LIMIT);
        }
        dw_char(w, '\n');
    }
}

static void donk_write_report(int fd, const donk_machine_t *m, const void *extra_annotations) {
    if (fd < 0) {
        return;
    }
    ftruncate(fd, 0);
    lseek(fd, 0, SEEK_SET);
    donk_writer_t w;
    w.fd = fd;
    w.length = 0;

    dw_str(&w, "donk-crash ");
    dw_unsigned(&w, DONK_CRASH_FORMAT_VERSION);
    dw_char(&w, '\n');
#if defined(__arm64__)
    dw_str(&w, "arch arm64\n");
#elif defined(__x86_64__)
    dw_str(&w, "arch x86_64\n");
#else
    dw_str(&w, "arch unknown\n");
#endif
    dw_line_signed(&w, "signal", m->sig);
    dw_line_signed(&w, "code", m->code);
    dw_line_hex(&w, "addr", m->fault_address);
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) == 0) {
        dw_str(&w, "time ");
        dw_unsigned(&w, (uint64_t)now.tv_sec);
        dw_char(&w, '.');
        uint64_t micros = (uint64_t)now.tv_nsec / 1000;
        char digits[6];
        for (int i = 5; i >= 0; i--) {
            digits[i] = (char)('0' + (micros % 10));
            micros /= 10;
        }
        for (int i = 0; i < 6; i++) {
            dw_char(&w, digits[i]);
        }
        dw_char(&w, '\n');
    }
    dw_line_signed(&w, "pid", getpid());
    dw_line_signed(&w, "main", pthread_main_np());
    dw_line_hex(&w, "thread", (uint64_t)pthread_mach_thread_np(pthread_self()));
    if (m->has_registers) {
        dw_line_hex(&w, "pc", m->pc);
#if defined(__arm64__)
        dw_line_hex(&w, "lr", m->lr);
#endif
        dw_line_hex(&w, "fp", m->fp);
        dw_line_hex(&w, "sp", m->sp);
    }
    if (m->has_exception_state) {
        dw_line_hex(&w, "esr", m->esr);
        dw_line_hex(&w, "far", m->far);
    }
    donk_write_frames(&w, m);
    dw_flush(&w);

    if (extra_annotations != NULL) {
        donk_write_annotations(&w, -1, (uintptr_t)extra_annotations);
    }
    donk_write_images(&w, 1);
    dw_flush(&w);
    donk_write_images(&w, 0);
    dw_flush(&w);

    char name[64];
    memset(name, 0, sizeof(name));
    if (pthread_getname_np(pthread_self(), name, sizeof(name)) == 0 && name[0] != 0) {
        dw_str(&w, "threadname ");
        dw_local_escaped(&w, name, sizeof(name));
        dw_char(&w, '\n');
    }
    const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    if (label != NULL) {
        dw_str(&w, "queue ");
        dw_remote_escaped(&w, (uintptr_t)label, 256);
        dw_char(&w, '\n');
    }
    dw_str(&w, "end\n");
    dw_flush(&w);
}

// MARK: - Images

static uint64_t donk_parse_image(donk_image_slot_t *slot, const struct mach_header *header) {
    uint64_t text_address = 0;
    if (header->magic != MH_MAGIC_64 && header->magic != MH_CIGAM_64) {
        return 0;
    }
    const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
    const uint8_t *cursor = (const uint8_t *)(header64 + 1);
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize == 0) {
            break;
        }
        if (command->cmd == LC_UUID) {
            const struct uuid_command *uuid = (const struct uuid_command *)command;
            memcpy(slot->uuid, uuid->uuid, 16);
        } else if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, SEG_TEXT, sizeof(segment->segname)) == 0) {
                slot->text_size = segment->vmsize;
                text_address = segment->vmaddr;
            }
        }
        cursor += command->cmdsize;
    }
    unsigned long size = 0;
    uint8_t *section = getsectiondata(header64, "__DATA", "__crash_info", &size);
    if (section == NULL) {
        section = getsectiondata(header64, "__DATA_DIRTY", "__crash_info", &size);
    }
    if (section != NULL && size >= sizeof(donk_annotations_t)) {
        slot->crash_info = (uintptr_t)section;
    }
    return text_address;
}

static int donk_has_image(uintptr_t load_address) {
    size_t reserved = atomic_load_explicit(&g_image_reserved, memory_order_acquire);
    if (reserved > DONK_CRASH_MAX_IMAGES) {
        reserved = DONK_CRASH_MAX_IMAGES;
    }
    for (size_t i = 0; i < reserved; i++) {
        if (g_images[i].load_address == load_address && atomic_load_explicit(&g_images[i].state, memory_order_acquire) == 1) {
            return 1;
        }
    }
    return 0;
}

static void donk_insert_image(const struct mach_header *header, intptr_t slide, int computes_slide, const char *fallback_path) {
    if (header == NULL) {
        return;
    }
    size_t index = atomic_fetch_add_explicit(&g_image_reserved, 1, memory_order_acq_rel);
    if (index >= DONK_CRASH_MAX_IMAGES) {
        return;
    }
    donk_image_slot_t *slot = &g_images[index];
    slot->load_address = (uintptr_t)header;
    slot->slide = slide;
    slot->text_size = 0;
    memset(slot->uuid, 0, sizeof(slot->uuid));
    slot->cpu_type = header->cputype;
    slot->cpu_subtype = header->cpusubtype;
    slot->file_type = header->filetype;
    slot->crash_info = 0;
    slot->path = NULL;
    uint64_t text_address = donk_parse_image(slot, header);
    if (computes_slide && text_address != 0) {
        slot->slide = (intptr_t)((uintptr_t)header - (uintptr_t)text_address);
    }
    Dl_info info;
    if (dladdr(header, &info) != 0 && info.dli_fname != NULL) {
        slot->path = info.dli_fname;
    } else {
        slot->path = fallback_path;
    }
    atomic_store_explicit(&slot->state, 1, memory_order_release);
}

static void donk_add_image(const struct mach_header *header, intptr_t slide) {
    donk_insert_image(header, slide, 0, NULL);
}

static void donk_add_dyld_image(void) {
    struct task_dyld_info info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&info, &count) != KERN_SUCCESS || info.all_image_info_addr == 0) {
        return;
    }
    const struct dyld_all_image_infos *infos = (const struct dyld_all_image_infos *)(uintptr_t)info.all_image_info_addr;
    if (infos->version < 2 || infos->dyldImageLoadAddress == NULL) {
        return;
    }
    const struct mach_header *header = infos->dyldImageLoadAddress;
    if (donk_has_image((uintptr_t)header)) {
        return;
    }
    donk_insert_image(header, 0, 1, "/usr/lib/dyld");
}

static void donk_remove_image(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    size_t reserved = atomic_load_explicit(&g_image_reserved, memory_order_acquire);
    if (reserved > DONK_CRASH_MAX_IMAGES) {
        reserved = DONK_CRASH_MAX_IMAGES;
    }
    for (size_t i = 0; i < reserved; i++) {
        donk_image_slot_t *slot = &g_images[i];
        if (slot->load_address == (uintptr_t)header && atomic_load_explicit(&slot->state, memory_order_acquire) == 1) {
            atomic_store_explicit(&slot->state, 2, memory_order_release);
        }
    }
}

void donk_crash_register_images(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&g_images_registered, &expected, 1)) {
        return;
    }
    if (g_address_mask == 0) {
        g_address_mask = donk_compute_address_mask();
    }
    _dyld_register_func_for_add_image(donk_add_image);
    _dyld_register_func_for_remove_image(donk_remove_image);
    donk_add_dyld_image();
}

size_t donk_crash_image_count(void) {
    size_t reserved = atomic_load_explicit(&g_image_reserved, memory_order_acquire);
    return reserved > DONK_CRASH_MAX_IMAGES ? DONK_CRASH_MAX_IMAGES : reserved;
}

int donk_crash_image_at(size_t index, donk_crash_image_t *out) {
    if (out == NULL || index >= donk_crash_image_count()) {
        return 0;
    }
    donk_image_slot_t *slot = &g_images[index];
    if (atomic_load_explicit(&slot->state, memory_order_acquire) != 1) {
        return 0;
    }
    out->load_address = slot->load_address;
    out->slide = slot->slide;
    out->text_size = slot->text_size;
    memcpy(out->uuid, slot->uuid, 16);
    out->path = slot->path;
    out->cpu_type = slot->cpu_type;
    out->cpu_subtype = slot->cpu_subtype;
    out->file_type = slot->file_type;
    out->crash_info = slot->crash_info;
    return 1;
}

// MARK: - Signals

static int donk_signal_index(int sig) {
    for (int i = 0; i < DONK_SIGNAL_COUNT; i++) {
        if (donk_signal_list[i] == sig) {
            return i;
        }
    }
    return -1;
}

static void donk_extract_machine(donk_machine_t *m, int sig, siginfo_t *info, void *context) {
    memset(m, 0, sizeof(*m));
    m->sig = sig;
    if (info != NULL) {
        m->code = info->si_code;
        m->fault_address = (uintptr_t)info->si_addr;
    }
    ucontext_t *uc = (ucontext_t *)context;
    if (uc == NULL || uc->uc_mcontext == NULL) {
        return;
    }
#if defined(__arm64__)
#if __has_feature(ptrauth_calls)
    m->pc = donk_strip((uintptr_t)ptrauth_strip(uc->uc_mcontext->__ss.__opaque_pc, ptrauth_key_process_independent_code));
    m->lr = donk_strip((uintptr_t)ptrauth_strip(uc->uc_mcontext->__ss.__opaque_lr, ptrauth_key_process_independent_code));
    m->fp = (uintptr_t)uc->uc_mcontext->__ss.__opaque_fp;
    m->sp = (uintptr_t)uc->uc_mcontext->__ss.__opaque_sp;
#else
    m->pc = donk_strip((uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss));
    m->lr = donk_strip((uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss));
    m->fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
    m->sp = (uintptr_t)__darwin_arm_thread_state64_get_sp(uc->uc_mcontext->__ss);
#endif
    m->esr = uc->uc_mcontext->__es.__esr;
    m->far = uc->uc_mcontext->__es.__far;
    m->has_exception_state = 1;
    m->has_registers = 1;
#elif defined(__x86_64__)
    m->pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
    m->fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
    m->sp = (uintptr_t)uc->uc_mcontext->__ss.__rsp;
    m->far = uc->uc_mcontext->__es.__faultvaddr;
    m->has_exception_state = 1;
    m->has_registers = 1;
#endif
}

static int donk_follows_syscall(uintptr_t pc) {
#if defined(__arm64__)
    uint32_t instruction = 0;
    if (pc < 4 || (pc & 0x3) != 0 || !donk_read_memory(pc - 4, &instruction, sizeof(instruction))) {
        return 0;
    }
    return (instruction & 0xFFE0001Fu) == 0xD4000001u;
#elif defined(__x86_64__)
    uint8_t bytes[2] = { 0, 0 };
    if (pc < 2 || !donk_read_memory(pc - 2, bytes, sizeof(bytes))) {
        return 0;
    }
    return bytes[0] == 0x0F && bytes[1] == 0x05;
#else
    (void)pc;
    return 0;
#endif
}

static int donk_is_user_sent(const siginfo_t *info, uintptr_t pc) {
    if (info == NULL) {
        return 1;
    }
    if (info->si_code == 0 || info->si_code == SI_USER || info->si_code == SI_QUEUE) {
        return 1;
    }
    return donk_follows_syscall(pc);
}

static int donk_pc_is_trap_instruction(uintptr_t pc) {
#if defined(__arm64__)
    uint32_t instruction = 0;
    if (pc == 0 || (pc & 0x3) != 0 || !donk_read_memory(pc, &instruction, sizeof(instruction))) {
        return 0;
    }
    return (instruction & 0xFFE0001Fu) == 0xD4200000u;
#else
    (void)pc;
    return 0;
#endif
}

static int donk_reexecutes(int sig, const siginfo_t *info, uintptr_t pc) {
    switch (sig) {
    case SIGSEGV:
    case SIGBUS:
    case SIGILL:
    case SIGFPE:
        return !donk_is_user_sent(info, pc);
    case SIGTRAP:
        return donk_pc_is_trap_instruction(pc);
    default:
        return 0;
    }
}

static void donk_set_default(int sig) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    sigaction(sig, &action, NULL);
}

static void donk_raise_after_return(int sig) {
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked, sig);
    pthread_sigmask(SIG_BLOCK, &blocked, NULL);
    raise(sig);
}

static void donk_chain(int sig, siginfo_t *info, void *context, uintptr_t pc) {
    int index = donk_signal_index(sig);
    struct sigaction previous;
    memset(&previous, 0, sizeof(previous));
    previous.sa_handler = SIG_DFL;
    if (index >= 0 && g_has_previous[index]) {
        previous = g_previous[index];
    }
    sigaction(sig, &previous, NULL);

    void *handler = (previous.sa_flags & SA_SIGINFO) ? (void *)previous.sa_sigaction : (void *)previous.sa_handler;
    if (handler != (void *)SIG_DFL && handler != (void *)SIG_IGN && handler != (void *)donk_signal_handler) {
        if (previous.sa_flags & SA_SIGINFO) {
            previous.sa_sigaction(sig, info, context);
        } else {
            previous.sa_handler(sig);
        }
        return;
    }
    if (handler == (void *)SIG_IGN && !donk_reexecutes(sig, info, pc)) {
        return;
    }
    donk_set_default(sig);
    if (!donk_reexecutes(sig, info, pc)) {
        donk_raise_after_return(sig);
    }
}

static void donk_signal_handler(int sig, siginfo_t *info, void *context) {
    int saved_errno = errno;
    uintptr_t self = (uintptr_t)pthread_self();
    donk_machine_t machine;
    donk_extract_machine(&machine, sig, info, context);
    int expected = 0;
    if (atomic_compare_exchange_strong(&g_handling, &expected, 1)) {
        atomic_store(&g_handling_thread, self);
        donk_write_report(atomic_load(&g_pending_fd), &machine, NULL);
        atomic_store(&g_handling, 2);
    } else if (atomic_load(&g_handling_thread) != self) {
        for (int step = 0; step < DONK_WAIT_STEPS && atomic_load(&g_handling) == 1; step++) {
            struct timespec pause = { 0, 10 * 1000 * 1000 };
            nanosleep(&pause, NULL);
        }
    }
    donk_chain(sig, info, context, machine.pc);
    errno = saved_errno;
}

size_t donk_crash_alternate_stack_size(void) {
    return DONK_ALT_STACK_SIZE;
}

int donk_crash_install_alternate_stack(void) {
    stack_t current;
    memset(&current, 0, sizeof(current));
    if (sigaltstack(NULL, &current) == 0 && !(current.ss_flags & SS_DISABLE) && current.ss_size >= DONK_ALT_STACK_SIZE) {
        return 0;
    }
    size_t guard = (size_t)getpagesize();
    size_t length = guard + DONK_ALT_STACK_SIZE;
    void *memory = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (memory == MAP_FAILED) {
        return -1;
    }
    if (mprotect(memory, guard, PROT_NONE) != 0) {
        munmap(memory, length);
        return -1;
    }
    stack_t stack;
    memset(&stack, 0, sizeof(stack));
    stack.ss_sp = (char *)memory + guard;
    stack.ss_size = DONK_ALT_STACK_SIZE;
    stack.ss_flags = 0;
    if (sigaltstack(&stack, NULL) != 0) {
        munmap(memory, length);
        return -1;
    }
    return 1;
}

// MARK: - Public

static int donk_open_record(const char *path) {
    if (path == NULL) {
        return -1;
    }
    return open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
}

static int donk_is_foreign_handler(const struct sigaction *action) {
    void *handler = (action->sa_flags & SA_SIGINFO) ? (void *)action->sa_sigaction : (void *)action->sa_handler;
    return handler != (void *)SIG_DFL && handler != (void *)SIG_IGN && handler != (void *)donk_signal_handler;
}

int donk_crash_open_records(const char *pending_path, const char *exception_path) {
    pthread_mutex_lock(&g_install_mutex);
    int result = 0;
    if (pending_path != NULL && atomic_load(&g_pending_fd) < 0) {
        int fd = donk_open_record(pending_path);
        if (fd >= 0) {
            atomic_store(&g_pending_fd, fd);
        } else {
            result = -1;
        }
    }
    if (exception_path != NULL && atomic_load(&g_exception_fd) < 0) {
        int fd = donk_open_record(exception_path);
        if (fd >= 0) {
            atomic_store(&g_exception_fd, fd);
        } else {
            result = -1;
        }
    }
    pthread_mutex_unlock(&g_install_mutex);
    return result;
}

int donk_crash_install(const char *pending_path, const char *exception_path) {
    pthread_mutex_lock(&g_install_mutex);
    if (atomic_load(&g_installed)) {
        pthread_mutex_unlock(&g_install_mutex);
        return 0;
    }
    if (g_address_mask == 0) {
        g_address_mask = donk_compute_address_mask();
    }
    donk_crash_register_images();
    int result = 0;
    if (pending_path != NULL) {
        int fd = donk_open_record(pending_path);
        atomic_store(&g_pending_fd, fd);
        if (fd < 0) {
            result = 1;
        }
    }
    if (exception_path != NULL) {
        int fd = donk_open_record(exception_path);
        atomic_store(&g_exception_fd, fd);
        if (fd < 0) {
            result = 1;
        }
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = donk_signal_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    int after_other = 0;
    for (int i = 0; i < DONK_SIGNAL_COUNT; i++) {
        struct sigaction previous;
        memset(&previous, 0, sizeof(previous));
        if (sigaction(donk_signal_list[i], &action, &previous) == 0) {
            g_previous[i] = previous;
            g_has_previous[i] = 1;
            if ((donk_signal_list[i] == SIGSEGV || donk_signal_list[i] == SIGTRAP) && donk_is_foreign_handler(&previous)) {
                after_other = 1;
            }
        } else {
            g_has_previous[i] = 0;
        }
    }
    atomic_store(&g_installed_after_other, after_other);
    atomic_store(&g_handling, 0);
    atomic_store(&g_installed, 1);
    pthread_mutex_unlock(&g_install_mutex);
    return result;
}

int donk_crash_installed_after_other_handler(void) {
    return atomic_load(&g_installed_after_other);
}

void donk_crash_uninstall(void) {
    pthread_mutex_lock(&g_install_mutex);
    if (!atomic_load(&g_installed)) {
        pthread_mutex_unlock(&g_install_mutex);
        return;
    }
    for (int i = 0; i < DONK_SIGNAL_COUNT; i++) {
        struct sigaction current;
        memset(&current, 0, sizeof(current));
        if (sigaction(donk_signal_list[i], NULL, &current) != 0) {
            continue;
        }
        if ((current.sa_flags & SA_SIGINFO) && (void *)current.sa_sigaction == (void *)donk_signal_handler && g_has_previous[i]) {
            sigaction(donk_signal_list[i], &g_previous[i], NULL);
        }
        g_has_previous[i] = 0;
    }
    int pending = atomic_exchange(&g_pending_fd, -1);
    if (pending >= 0) {
        close(pending);
    }
    int exception = atomic_exchange(&g_exception_fd, -1);
    if (exception >= 0) {
        close(exception);
    }
    atomic_store(&g_installed_after_other, 0);
    atomic_store(&g_installed, 0);
    pthread_mutex_unlock(&g_install_mutex);
}

int donk_crash_is_installed(void) {
    return atomic_load(&g_installed);
}

int donk_crash_write_exception(const void *bytes, size_t length) {
    int fd = atomic_load(&g_exception_fd);
    if (fd < 0 || bytes == NULL) {
        return -1;
    }
    if (ftruncate(fd, 0) != 0) {
        return -1;
    }
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = pwrite(fd, (const char *)bytes + offset, length - offset, (off_t)offset);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (written == 0) {
            return -1;
        }
        offset += (size_t)written;
    }
    return 0;
}

uint64_t donk_crash_address_mask(void) {
    if (g_address_mask == 0) {
        g_address_mask = donk_compute_address_mask();
    }
    return g_address_mask;
}

const int *donk_crash_signals(size_t *count) {
    *count = DONK_SIGNAL_COUNT;
    return donk_signal_list;
}

void *donk_crash_handler_address(void) {
    return (void *)donk_signal_handler;
}

void *donk_crash_current_handler(int sig) {
    struct sigaction current;
    memset(&current, 0, sizeof(current));
    if (sigaction(sig, NULL, &current) != 0) {
        return NULL;
    }
    if (current.sa_flags & SA_SIGINFO) {
        return (void *)current.sa_sigaction;
    }
    return (void *)current.sa_handler;
}

int donk_crash_debugger_attached(void) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return 0;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

static void donk_remove_session_marker(void) {
    if (atomic_load(&g_session_armed) && g_session_path[0] != 0) {
        unlink(g_session_path);
    }
}

int donk_crash_track_session_marker(const char *path) {
    if (path == NULL) {
        atomic_store(&g_session_armed, 0);
        return 0;
    }
    size_t length = strlen(path);
    if (length == 0 || length >= sizeof(g_session_path)) {
        return -1;
    }
    pthread_mutex_lock(&g_install_mutex);
    memcpy(g_session_path, path, length + 1);
    atomic_store(&g_session_armed, 1);
    int expected = 0;
    int result = 0;
    if (atomic_compare_exchange_strong(&g_session_registered, &expected, 1)) {
        result = atexit(donk_remove_session_marker) == 0 ? 0 : -1;
    }
    pthread_mutex_unlock(&g_install_mutex);
    return result;
}

int donk_crash_previous_action(int sig, struct sigaction *out) {
    int index = donk_signal_index(sig);
    if (index < 0 || !g_has_previous[index] || out == NULL) {
        return 0;
    }
    *out = g_previous[index];
    return 1;
}

int donk_crash_debug_write_report(int fd, int sig, int code, uint64_t fault_address, uint64_t pc, uint64_t lr, uint64_t fp, uint64_t sp, const void *annotations) {
    if (g_address_mask == 0) {
        g_address_mask = donk_compute_address_mask();
    }
    donk_crash_register_images();
    donk_machine_t machine;
    memset(&machine, 0, sizeof(machine));
    machine.sig = sig;
    machine.code = code;
    machine.fault_address = (uintptr_t)fault_address;
    machine.pc = donk_strip((uintptr_t)pc);
    machine.lr = donk_strip((uintptr_t)lr);
    machine.fp = (uintptr_t)fp;
    machine.sp = (uintptr_t)sp;
    machine.has_registers = 1;
    donk_write_report(fd, &machine, annotations);
    return 0;
}

void donk_crash_debug_remove_session_marker(void) {
    donk_remove_session_marker();
}

void donk_crash_debug_reset_guard(void) {
    atomic_store(&g_handling, 0);
    atomic_store(&g_handling_thread, 0);
}
