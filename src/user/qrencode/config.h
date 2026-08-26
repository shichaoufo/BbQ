#ifndef CONFIG_H
#define CONFIG_H

/* Define to 1 if you have the <inttypes.h> header file. */
#undef HAVE_INTTYPES_H

/* Define to 1 if you have the `malloc' function. */
#define HAVE_MALLOC 1

/* Define to 1 if you have the <memory.h> header file. */
#undef HAVE_MEMORY_H

/* Define to 1 if you have the <stdint.h> header file. */
#define HAVE_STDINT_H 1

/* Define to 1 if you have the <stdlib.h> header file. */
#define HAVE_STDLIB_H 1

/* Define to 1 if you have the `strdup' function. */
#define HAVE_STRDUP 1

/* Define to 1 if you have the <strings.h> header file. */
#undef HAVE_STRINGS_H

/* Define to 1 if you have the <string.h> header file. */
#define HAVE_STRING_H 1

/* Define to 1 if you have the `strndup' function. */
#define HAVE_STRNDUP 1

/* Define to 1 if you have the <unistd.h> header file. */
#undef HAVE_UNISTD_H

/* Define to the address where bug reports for this package should be sent. */
#undef PACKAGE_BUGREPORT

/* Define to the full name of this package. */
#define PACKAGE_NAME "qrencode"

/* Define to the full name and version of this package. */
#define PACKAGE_STRING "qrencode 4.1.1"

/* Define to the one symbol short name of this package. */
#define PACKAGE_TARNAME "qrencode"

/* Define to the home page for this package. */
#undef PACKAGE_URL

/* Define to the version of this package. */
#define PACKAGE_VERSION "4.1.1"

/* Define to 1 if you have the ANSI C header files. */
#define STDC_HEADERS 1

/* Version number of package */
#define VERSION "4.1.1"

/* Major version number of package */
#define MAJOR_VERSION 4

/* Minor version number of package */
#define MINOR_VERSION 1

/* Micro version number of package */
#define MICRO_VERSION 1

/* Define to 1 if building shared library */
#undef ENABLE_SHARED

/* Define to 1 if building static library */
#define ENABLE_STATIC 1

/* Define to empty if `const' does not conform to ANSI C. */
#undef const

/* Define to inline if that's what the C compiler uses. */
#ifndef inline
#  if defined(__GNUC__) || defined(__clang__)
#    define inline __inline__
#  elif defined(_MSC_VER)
#    define inline __inline
#  else
#    define inline
#  endif
#endif

/* Define to `static' when building a shared library. */
#ifdef ENABLE_SHARED
#  define STATIC_IN_RELEASE extern
#else
#  define STATIC_IN_RELEASE static
#endif

#endif /* CONFIG_H */
