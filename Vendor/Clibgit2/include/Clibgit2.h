/*
 * Umbrella header for the Clibgit2 module: libgit2's public C API. `git2.h`
 * and `git2/` beside this file are links into the Vendor/libgit2 submodule.
 */
#ifndef CLIBGIT2_H
#define CLIBGIT2_H

#include "git2.h"
#include "git2/sys/transport.h"

/* Wrappers for git_libgit2_opts(), which is variadic. */
int clibgit2_set_search_path(int level, const char *path);
int clibgit2_set_owner_validation(int enabled);

/* Sets libgit2's error message for the calling thread. */
void clibgit2_set_error(const char *message);

/*
 * The SSH transport. libgit2 is built without SSH; this registers a smart
 * subtransport for ssh://, ssh+git://, git+ssh:// and the scp-like
 * `user@host:path`, whose connection is made in Swift. The structs libgit2
 * wants, with their function pointers and embedded parents, are built here;
 * Swift only sees these callbacks, each given the context `create` returned.
 */
typedef struct {
	/* A new connection for one smart transport, whose remote callbacks'
	 * payload is `payload`. Returns NULL, with an error set, on failure. */
	void *(*create)(void *payload);
	/* Starts `service` (a git_smart_service_t) for `url`: the listing
	 * services connect, the ones after them carry on the same connection. */
	int (*action)(void *context, const char *url, int service);
	/* Reads at most `size` bytes; zero bytes read is the end of the stream. */
	int (*read)(void *context, char *buffer, size_t size, size_t *bytes_read);
	/* Writes all of `length` bytes, or fails. */
	int (*write)(void *context, const char *buffer, size_t length);
	/* Ends the connection; the context may be used for another action. */
	int (*close)(void *context);
	void (*free)(void *context);
} clibgit2_ssh_callbacks;

/* Registers the SSH transport. Call once, after git_libgit2_init(). */
int clibgit2_register_ssh_transport(const clibgit2_ssh_callbacks *callbacks);

#endif
