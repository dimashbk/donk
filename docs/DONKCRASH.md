# DonkCrash — design notes

DonkCrash stores crash reports on the device and lets the user share them. It coexists with Firebase Crashlytics.

## Integration

```swift
func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    DonkCrash.install()          // or Donk.installCrashReporter()
    FirebaseApp.configure()      // after Donk
    return true
}
```

`install()` must run **before** `FirebaseApp.configure()`, on the main thread (see *Alternate stacks*). Crashlytics saves the signal actions that exist when it installs and restores exactly those at crash time; whatever was installed after it is overwritten.

### How Crashlytics 11.x hands crashes back (verified against `FIRCLSSignal.c` / `FIRCLSMachException.c`)

- **Signal path** (`FIRCLSSignalHandler`, used for `SIGABRT`/`SIGSYS` and any signal not caught as a Mach exception): it resets all seven handlers to `SIG_DFL`, **unmasks every signal** (`sigprocmask(SIG_UNBLOCK, <full set>)`), records its report, reinstalls the saved pre-existing actions and **calls the pre-existing handler directly** with the original `(sig, info, uap)`. Then it returns. It never re-raises.
- **Mach path** (`EXC_BAD_ACCESS`, `EXC_BAD_INSTRUCTION`, `EXC_ARITHMETIC`, `EXC_BREAKPOINT`, `EXC_GUARD`): its exception thread unregisters its ports, reinstalls the saved pre-existing signal actions, records, and replies `KERN_SUCCESS`. The crashed thread resumes, re-executes the faulting instruction, faults again, and the kernel delivers the BSD signal to whatever action is now installed — Donk's, when Donk was installed first.

Crash flow with both installed in the right order (Donk first, Crashlytics second):

| Crash | Who sees it first | How Donk gets it | How the process dies |
|---|---|---|---|
| Hardware fault (segfault, Swift trap, `brk`) | Crashlytics' Mach thread | kernel delivers the re-fault signal to Donk | Donk restores `SIG_DFL` and returns; the instruction faults a third time and the kernel terminates with the original exception |
| `abort()`, uncaught `NSException`, `raise`/`kill`, `SIGSYS` | Crashlytics' signal handler | called directly, with every signal unmasked | Donk blocks the signal, re-raises it and returns; it is delivered after Crashlytics returns and `sigreturn` restores the original mask, so the process dies at the original site |

In the wrong order (Donk after Crashlytics) software signals still reach Donk first and are chained to Crashlytics, but every hardware fault bypasses Donk: the Mach thread restores Crashlytics' pre-existing actions (`SIG_DFL`) and the re-fault terminates the process directly.

### Install-order detection

`install()` checks the actions it replaces. If `SIGSEGV` or `SIGTRAP` already has a function handler (not `SIG_DFL`/`SIG_IGN`), another reporter was installed earlier: `DonkCrash.installedAfterAnotherReporter` becomes `true`, a fault-level `os_log` (subsystem `io.github.donk`, category `crash`) says *"donk was installed after another crash reporter — hardware crashes won't be captured; call Donk.installCrashReporter() before FirebaseApp.configure()"*, and the crash list shows the same warning card.

Crashes under the Xcode debugger are caught by LLDB first (Mach exception ports); relaunch without the debugger to record them.

## Files

Everything lives in `Library/Application Support/Donk/Crashes/`:

| File | Writer | When |
|---|---|---|
| `Raw/pending.donkcrash` | C signal handler | at crash time, through an fd opened at install |
| `Raw/exception.json` | NSException handler (Swift) | at crash time, through an fd opened at install |
| `Raw/launch.json` | `install()` | every launch (app version/build/OS of that session) |
| `Raw/session.json` | session tracking | while the app is in the foreground |
| `Raw/Inbox/<batch>.<slot>` | `install()` | the previous session's files are renamed here |
| `Raw/Quarantine/<batch>.<slot>` | inbox processing | batches that failed to parse more than 3 times (newest 10 kept) |
| `<uuid>.json` | report store | one `CrashReport` per file (max 200, oldest pruned) |

On launch `install()` renames the previous session's non-empty raw files into `Raw/Inbox/` under one batch name (an atomic `rename`), installs the handlers (which recreate empty raw files), and parses the inbox on a utility queue.

- A batch is deleted only after its report has been handed to the store, so a crash during processing or an early second crash never loses data.
- If any file of a batch cannot be read (for example protected data is unavailable before the first unlock after a reboot), the whole batch is kept untouched and retried on the next launch.
- A batch whose signal or exception record is present but cannot be parsed is retried; after the 4th failed attempt it is moved to `Raw/Quarantine/`. Attempt counts live in the settings file.
- If the record files cannot be opened at install time, the handlers are installed anyway (fd `-1` means "skip the write, still chain"), `DonkCrash.isInstalled` is `true`, and the files are reopened on `protectedDataDidBecomeAvailable` / `didBecomeActive`.

Settings (`detectsUncleanExits`, processed MetricKit signatures, inbox attempt counts) live in `Donk/crash-settings.json`.

## Signal handler (DonkCrashC)

- Signals: `SIGABRT SIGBUS SIGFPE SIGILL SIGSEGV SIGSYS SIGTRAP` (the Crashlytics set). `SIGPIPE` is never touched.
- `SA_SIGINFO | SA_ONSTACK`. See *Alternate stacks* below.
- Idempotent install; `donk_crash_uninstall()` restores the previous actions only where Donk's handler is still current.
- Binary image table: `_dyld_register_func_for_add_image`/`remove_image` fill a static 2048-slot array (lock-free reservation with an atomic counter, a per-slot release-store marks the slot valid). Each slot keeps the load address, slide, `__TEXT` size, UUID, path pointer (from `dladdr` outside the handler), CPU type, file type and the address of `__DATA,__crash_info` (also `__DATA_DIRTY`). dyld itself is added from `TASK_DYLD_INFO`.
- The handler takes an atomic guard. A second crashing thread waits up to 2 s for the first writer; a nested crash on the same thread skips writing. It uses only `write`, `ftruncate`, `lseek`, `vm_read_overwrite`, `clock_gettime`, `pthread_*_np` reads, `sigaction`, `pthread_sigmask` and `raise`: no malloc, no ObjC/Swift, no stdio, no `dladdr`.
- Record: signal, `si_code`, `si_addr`, time, pid, main-thread flag, PC/LR/FP/SP (+ ESR/FAR on arm64; RIP/RBP/RSP on x86_64), a frame-pointer walk of up to 128 frames (8-byte aligned, strictly increasing FP, every read through `vm_read_overwrite`, PAC bits stripped with a mask derived from `machdep.virtual_address_size`), every `crash_info` message (bounded, page-safe copies; this is where the Swift runtime puts `Fatal error: …` and libsystem puts `abort() called`), the image table, thread name and dispatch queue label. Text format, one `key value` per line, values escaped (`\\ \n \r \t \xHH`), terminated by `end`.

### Alternate stacks

`sigaltstack` is per thread. Every call to `donk_crash_install_alternate_stack()` that has to install one maps a **fresh** region (never shared, never reused): one `PROT_NONE` guard page followed by 256 KB, so an overflow of the handler itself faults on the guard instead of corrupting neighbouring memory. A thread that already has an enabled alternate stack of at least 256 KB keeps it.

Only the main thread gets one. `install()` installs it synchronously when called on the main thread and otherwise hops to the main queue (`DispatchQueue.main.async`, never `sync`, to avoid deadlocking a host that waits on the installing thread); worker threads, including the GCD thread that called `install()`, are left alone. A stack overflow on a secondary thread therefore has no alternate stack and is not recorded (Crashlytics behaves the same). Crashlytics replaces the main thread's alternate stack with its own when it installs after Donk; Donk's handler then runs on that stack, which is fine.

### Chaining and re-raising

After writing, the handler reinstalls the saved previous action for the signal.

- **Previous action is a function** (a reporter installed before Donk): call it directly with `(sig, info, context)` if it had `SA_SIGINFO`, else `(sig)`, and return. Whatever it does next is its decision, exactly as if Donk were not installed.
- **Previous action is `SIG_DFL`** (or `SIG_IGN` for a fault that cannot be ignored), decided per signal:
  - *Hardware faults re-execute.* `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE` raised by the CPU, and `SIGTRAP` when the PC points at an arm64 `brk` (Swift traps: `fatalError`, force unwrap, bounds checks, overflow; on the simulator `brk` arrives with `si_code == 0`, so the instruction check is required). The handler **returns**; the faulting instruction runs again, faults again, and with `SIG_DFL` installed the kernel terminates the process with the *original* exception (`EXC_BAD_ACCESS`, `EXC_BREAKPOINT`, …). The OS report stays faithful.
  - *Software signals are re-raised after return.* `SIGABRT` (`abort()`, uncaught exceptions), `SIGSYS`, `SIGTRAP` on x86_64, and any of the seven sent by `kill`/`raise`/`pthread_kill`. Returning alone would continue execution, so the handler blocks the signal with `pthread_sigmask(SIG_BLOCK)`, calls `raise(sig)` (the signal becomes pending) and **returns**. The signal is delivered — with the default action — only when the outermost handler returns and `sigreturn` restores the interrupted context's mask, so the OS, MetricKit and Xcode Organizer see the crash at the original site (`__pthread_kill` ← `abort` ← …), not inside Donk. Blocking matters because a reporter that calls Donk directly may have unmasked everything (Crashlytics does); a bare `raise` would then terminate inside `donk_chain`.
  - *Telling them apart.* Darwin fills a hardware-looking `si_code` (`BUS_ADRERR`, `SEGV_ACCERR`, `ILL_ILLOPN`, …) even for `raise(SIGSEGV)`/`kill`, so `si_code` alone is not enough. A signal counts as software when `si_code` is `0`/`SI_USER`/`SI_QUEUE` **or** the PC sits right after a syscall instruction (`svc` on arm64, `syscall` on x86_64): that is where `__pthread_kill`/`__kill` return.
- **Previous action is `SIG_IGN` for a software signal**: return; the signal stays ignored as before.

## Uncaught NSException

`NSSetUncaughtExceptionHandler`, chained to `NSGetUncaughtExceptionHandler()`. The handler (normal context) serializes name, reason, `userInfo` (stringified, 64 entries × 4 KB max), `callStackReturnAddresses`, `callStackSymbols`, thread info and the images referenced by the backtrace, writes the JSON through the pre-opened fd, then calls the previous handler. The runtime then aborts; the `SIGABRT` record from the same session is merged into one `exception` report: the exception backtrace becomes the main frames, the abort thread is kept as "Signal Thread".

## Next launch: symbolication

Each address is mapped to the image that contained it in the crashed process (load address + `__TEXT` size), then to the same image in the current process — matched by **UUID**, or by path when no UUID is available, never across different UUIDs (an updated binary is not symbolicated) — and translated by offset (ASLR). `dladdr` gives the nearest symbol; return addresses (every frame but the first) are looked up at `address - 1` so `noreturn` calls resolve to the caller. Swift names go through `swift_demangle` (found with `dlsym`), C++ names through `__cxa_demangle`. Exception frames fall back to the system's `callStackSymbols` when an image cannot be matched.

Leaf functions: frame 1 is LR when LR resolves to a different function than PC and is not already the first frame-pointer return address.

App frames: the main executable and every image inside the crashed app bundle (including `*.debug.dylib` in Xcode debug builds and embedded frameworks).

`dladdr` only sees symbols present in the binary. Release builds strip local symbols, and shared-cache system libraries only export public names. In a stripped app `dladdr` returns the nearest *exported* symbol — usually `__mh_execute_header`, the image header itself — so a resolved name is discarded when it is an image-header symbol (`_mh_execute_header`, `_mh_dylib_header`, `_mh_bundle_header`, `__dso_handle`) or when the address is more than 64 KB past it. Such frames show `image + offset`, the UI marks them "unsymbolicated (use atos)", and the text report keeps Apple's `0x… <load> + <offset>` form so `symbolicatecrash`/`atos` can process it. The report also carries a Binary Images section and a ready `atos -o <App>.app.dSYM/Contents/Resources/DWARF/<App> -arch arm64 -l <load> <address>` line for the top app frame.

## MetricKit

A `MXMetricManagerSubscriber` is added after the inbox is processed; `pastDiagnosticPayloads` are consumed too. Crash, hang and CPU-exception diagnostics become `metricKit` reports. The `callStackTree` JSON is summarized by following the attributed thread (or the heaviest sample path for hang/CPU trees). Frames are symbolicated by binary UUID + `offsetIntoBinaryTextSegment` when that build is the one running. Each payload is identified by a stable FNV-1a signature (category + end time + payload JSON) so redelivered payloads are ignored. MetricKit does not deliver on the simulator.

## Unclean exits

`session.json` is written on `didBecomeActive` and removed on `didEnterBackground`, `willTerminate` and by an `atexit` handler (so `exit()` is a clean exit). If a batch contains the marker but no crash record, an `uncleanExit` report is created ("possibly killed by the system (OOM/watchdog) or a debugger"), unless:

- the marker belongs to a different app version/build or OS version (updates and OS upgrades kill apps legitimately), or
- the marker records that a debugger was attached (`P_TRACED` from `sysctl(KERN_PROC_PID)` when the marker was written): stopping a debug session from Xcode is not reported.

Background launches never write the marker. `simctl terminate` or reinstalling a running build without a debugger still counts as an unclean exit. Toggle with `DonkCrash.detectsUncleanExits` (default `true`, persisted).
