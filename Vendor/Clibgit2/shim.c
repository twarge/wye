/*
 * Fixed-arity wrappers for the libgit2 calls that are variadic in C, which
 * Swift cannot call, and the C half of the SSH transport.
 */
#include <stdlib.h>
#include <string.h>
#include "Clibgit2.h"
#include "git2/sys/errors.h"
#include "git2/sys/remote.h"

int clibgit2_set_search_path(int level, const char *path)
{
	return git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, level, path);
}

int clibgit2_set_owner_validation(int enabled)
{
	return git_libgit2_opts(GIT_OPT_SET_OWNER_VALIDATION, enabled);
}

void clibgit2_set_error(const char *message)
{
	git_error_set_str(GIT_ERROR_SSH, message);
}

/* MARK: SSH transport */

static clibgit2_ssh_callbacks ssh_callbacks;

typedef struct {
	git_smart_subtransport parent;
	/* One stream, reused: the transport is stateful, so the action after a
	 * listing carries on the listing's connection. */
	git_smart_subtransport_stream stream;
	git_transport *owner;
	void *context;
} ssh_subtransport;

static int ssh_stream_read(git_smart_subtransport_stream *stream, char *buffer, size_t size, size_t *bytes_read)
{
	ssh_subtransport *transport = (ssh_subtransport *)stream->subtransport;
	*bytes_read = 0;
	return ssh_callbacks.read(transport->context, buffer, size, bytes_read);
}

static int ssh_stream_write(git_smart_subtransport_stream *stream, const char *buffer, size_t length)
{
	ssh_subtransport *transport = (ssh_subtransport *)stream->subtransport;
	return ssh_callbacks.write(transport->context, buffer, length);
}

/* The stream lives inside the subtransport; closing it is close's job. */
static void ssh_stream_free(git_smart_subtransport_stream *stream)
{
	(void)stream;
}

static int ssh_action(git_smart_subtransport_stream **out, git_smart_subtransport *subtransport,
                      const char *url, git_smart_service_t service)
{
	ssh_subtransport *transport = (ssh_subtransport *)subtransport;
	int error;

	if (!transport->context) {
		/* The remote callbacks are only known once the transport is
		 * connecting, so the Swift side is made here, at the first action. */
		git_remote_connect_options options = GIT_REMOTE_CONNECT_OPTIONS_INIT;
		void *payload;
		if ((error = git_transport_remote_connect_options(&options, transport->owner)) < 0)
			return error;
		payload = options.callbacks.payload;
		git_remote_connect_options_dispose(&options);
		if (!(transport->context = ssh_callbacks.create(payload)))
			return -1;
	}
	if ((error = ssh_callbacks.action(transport->context, url, (int)service)) < 0)
		return error;

	transport->stream.subtransport = subtransport;
	transport->stream.read = ssh_stream_read;
	transport->stream.write = ssh_stream_write;
	transport->stream.free = ssh_stream_free;
	*out = &transport->stream;
	return 0;
}

static int ssh_close(git_smart_subtransport *subtransport)
{
	ssh_subtransport *transport = (ssh_subtransport *)subtransport;
	return transport->context ? ssh_callbacks.close(transport->context) : 0;
}

static void ssh_free(git_smart_subtransport *subtransport)
{
	ssh_subtransport *transport = (ssh_subtransport *)subtransport;
	if (transport->context)
		ssh_callbacks.free(transport->context);
	free(transport);
}

static int ssh_subtransport_new(git_smart_subtransport **out, git_transport *owner, void *param)
{
	ssh_subtransport *transport = calloc(1, sizeof(ssh_subtransport));
	(void)param;
	if (!transport) {
		git_error_set_oom();
		return -1;
	}
	transport->parent.action = ssh_action;
	transport->parent.close = ssh_close;
	transport->parent.free = ssh_free;
	transport->owner = owner;
	*out = &transport->parent;
	return 0;
}

static git_smart_subtransport_definition ssh_definition = { ssh_subtransport_new, 0, NULL };

/*
 * libgit2 sends any URL with a colon and no transport of its own to the one
 * registered for ssh://, so a local path with a colon in it would arrive
 * here too. git reads `host:path` as SSH only when no slash comes before
 * the colon; anything else is a path on disk, for the local transport.
 */
static int is_local_path(const char *url)
{
	const char *colon, *slash;
	if (!url || strstr(url, "://"))
		return 0;
	colon = strchr(url, ':');
	slash = strchr(url, '/');
	return !colon || (slash && slash < colon) || colon - url < 2;
}

static int ssh_transport_new(git_transport **out, git_remote *owner, void *param)
{
	(void)param;
	/* The transport is not told the URL; the remote's are what it is for.
	 * Without a remote there is nothing to decide by, and SSH it is. */
	if (owner && is_local_path(git_remote_url(owner)) &&
	    (!git_remote_pushurl(owner) || is_local_path(git_remote_pushurl(owner))))
		return git_transport_local(out, owner, NULL);
	return git_transport_smart(out, owner, &ssh_definition);
}

int clibgit2_register_ssh_transport(const clibgit2_ssh_callbacks *callbacks)
{
	static const char *schemes[] = { "ssh", "ssh+git", "git+ssh" };
	size_t i;
	int error;

	ssh_callbacks = *callbacks;
	for (i = 0; i < sizeof(schemes) / sizeof(schemes[0]); i++) {
		if ((error = git_transport_register(schemes[i], ssh_transport_new, NULL)) < 0)
			return error;
	}
	return 0;
}
