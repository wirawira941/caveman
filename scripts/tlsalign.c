/* tlsalign.c — set PT_TLS.p_align to 64 so Android Bionic accepts the binary.
 *
 * Bionic requires an executable's TLS segment to be aligned to at least
 * (MAX_TLS_SLOT + 1) * sizeof(void*) = 64 bytes on ARM64, because ARM uses
 * TLS variant 1 (TP + 2-word TCB, then the executable's segment) and Bionic
 * parks its TCB in the alignment padding. A Go binary linked for musl (via
 * zig cc) gets p_align = 8, and Android aborts with:
 *
 *   executable's TLS segment is underaligned: alignment is 8,
 *   needs to be at least 64 for ARM64 Bionic
 *
 * Android's own toolchain gets this for free (crtbegin.o carries a 64-byte
 * aligned .tbss, and LLD applies its --android-tls overalignment). We are not
 * recognized as an Android target, so we set the field ourselves.
 *
 * Usage: tlsalign <elf-file> [...]
 * Prints the old -> new p_align for each file. Idempotent.
 */
#include <elf.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#if defined(__aarch64__) || defined(__x86_64__)
typedef Elf64_Ehdr Ehdr;
typedef Elf64_Phdr Phdr;
#define ELFMAG_OK(e) ((e)->e_ident[EI_CLASS] == ELFCLASS64)
#else
typedef Elf32_Ehdr Ehdr;
typedef Elf32_Phdr Phdr;
#define ELFMAG_OK(e) ((e)->e_ident[EI_CLASS] == ELFCLASS32)
#endif

/* (MAX_TLS_SLOT + 1) * sizeof(void*) on ARM64, per bionic_elf_tls.cpp. 32-bit
 * ARM needs 32; we only handle 64-bit here since that is what we build. */
#define NEEDED_TLS_ALIGN 64

static int patch(const char *path) {
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return 1; }

    struct stat st;
    if (fstat(fd, &st) != 0) { perror("fstat"); close(fd); return 1; }
    if (st.st_size < (off_t)sizeof(Ehdr)) {
        fprintf(stderr, "%s: too small to be an ELF\n", path);
        close(fd);
        return 1;
    }

    void *map = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); close(fd); return 1; }
    close(fd);

    Ehdr *eh = (Ehdr *)map;
    if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 || !ELFMAG_OK(eh)) {
        fprintf(stderr, "%s: not a %d-bit ELF\n", path,
                (int)(sizeof(void *) * 8));
        munmap(map, st.st_size);
        return 1;
    }

    Phdr *ph = (Phdr *)((char *)map + eh->e_phoff);
    int found = 0;
    for (int i = 0; i < eh->e_phnum; i++) {
        if (ph[i].p_type != PT_TLS) continue;
        found = 1;
        if (ph[i].p_align == NEEDED_TLS_ALIGN) {
            printf("%s: PT_TLS p_align already %d, nothing to do\n", path,
                   NEEDED_TLS_ALIGN);
            break;
        }
        printf("%s: PT_TLS p_align %llu -> %d\n", path,
               (unsigned long long)ph[i].p_align, NEEDED_TLS_ALIGN);
        ph[i].p_align = NEEDED_TLS_ALIGN;
        break;
    }

    if (!found) {
        /* No TLS segment: Bionic's special case skips the alignment check, so
         * a TLS-less binary needs no patching. */
        printf("%s: no PT_TLS segment, nothing to do\n", path);
    }

    /* Flushing a MAP_SHARED mapping writes it back to the file. */
    msync(map, st.st_size, MS_SYNC);
    munmap(map, st.st_size);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <elf-file>...\n", argv[0]);
        return 2;
    }
    int rc = 0;
    for (int i = 1; i < argc; i++)
        if (patch(argv[i]) != 0) rc = 1;
    return rc;
}
