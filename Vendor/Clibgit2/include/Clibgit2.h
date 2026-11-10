/*
 * Umbrella header for the Clibgit2 module: libgit2's public C API. `git2.h`
 * and `git2/` beside this file are links into the Vendor/libgit2 submodule.
 */
#ifndef CLIBGIT2_H
#define CLIBGIT2_H

#include "git2.h"

/* Wrappers for git_libgit2_opts(), which is variadic. */
int clibgit2_set_search_path(int level, const char *path);
int clibgit2_set_owner_validation(int enabled);

#endif
