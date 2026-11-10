/*
 * Fixed-arity wrappers for the libgit2 calls that are variadic in C, which
 * Swift cannot call.
 */
#include "Clibgit2.h"

int clibgit2_set_search_path(int level, const char *path)
{
	return git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, level, path);
}

int clibgit2_set_owner_validation(int enabled)
{
	return git_libgit2_opts(GIT_OPT_SET_OWNER_VALIDATION, enabled);
}
