// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

#define _XOPEN_SOURCE 1

#include <time.h> // strftime()
#include <wchar.h> // wcwidth()
#include <locale.h> // localeconv()
#include <fnmatch.h> // fnmatch()
#if defined(__linux__)
#include <sys/vfs.h> // statfs()
#endif
#include <curses.h>
#include <zstd.h>