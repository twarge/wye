/*
 * Build configuration for the libgit2 sources in Vendor/libgit2, standing in
 * for the header CMake would generate. One configuration serves macOS, iOS
 * and visionOS.
 */
#ifndef INCLUDE_features_h__
#define INCLUDE_features_h__

#define GIT_THREADS 1
#define GIT_ARCH_64 1

#define GIT_USE_ICONV 1
#define GIT_USE_NSEC 1
#define GIT_USE_STAT_MTIMESPEC 1
#define GIT_USE_FUTIMENS 1

/*
 * POSIX regcomp(): regcomp_l() is unavailable on iOS, and an app that never
 * calls setlocale() stays in the "C" locale that libgit2 expects.
 */
#define GIT_REGEX_REGCOMP
#define GIT_QSORT_BSD

/* HTTPS through the system TLS stack; no bundled crypto library. */
#define GIT_HTTPS 1
#define GIT_SECURE_TRANSPORT 1
#define GIT_HTTPPARSER_BUILTIN 1

#define GIT_SHA1_COLLISIONDETECT 1
#define GIT_SHA256_COMMON_CRYPTO 1

#define GIT_COMPRESSION_ZLIB 1

/*
 * getentropy() is public on macOS only, declared in <sys/random.h>. Where the
 * header is absent (iOS, visionOS) libgit2 seeds from /dev/urandom instead.
 */
#if __has_include(<sys/random.h>)
# include <sys/types.h>
# include <sys/random.h>
# define GIT_RAND_GETENTROPY 1
#endif

#define GIT_IO_POLL 1
#define GIT_IO_SELECT 1

#endif
