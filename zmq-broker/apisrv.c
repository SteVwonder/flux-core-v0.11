/* apisrv.c - bridge unix domain API socket and zmq message bus */

/* FIXME: consider adding SO_PEERCRED info for connected clients? */

/* FIXME: writes to fds can block and we have no buffering  */

#define _GNU_SOURCE
#include <stdio.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <getopt.h>
#include <libgen.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/param.h>
#include <stdbool.h>
#include <sys/un.h>
#include <sys/socket.h>
#include <ctype.h>
#include <fcntl.h>
#include <zmq.h>
#include <uuid/uuid.h>
#include <json/json.h>

#include "zmq.h"
#include "cmb.h"
#include "cmbd.h"
#include "apisrv.h"
#include "util.h"

#define LISTEN_BACKLOG      5

typedef struct _cfd_struct {
    int fd;
    struct _cfd_struct *next;
    struct _cfd_struct *prev;
    char *name; /* api.<uuid>.fd.<cfd_id> */
    char *wname; /* user-provided, indicates API will read */
    char buf[CMB_API_FD_BUFSIZE];
} cfd_t;

typedef struct _client_struct {
    int fd;
    struct _client_struct *next;
    struct _client_struct *prev;
    char *subscription;
    char uuid[64]; /* "api.<uuid>" */
    cfd_t *cfds;
    int cfd_id;
} client_t;

typedef struct ctx_struct *ctx_t;

struct ctx_struct {
    char sockname[MAXPATHLEN];
    void *zs_in;
    void *zs_out;
    pthread_t t;
    int listen_fd;
    client_t *clients;
    char buf[CMB_API_BUFSIZE];
};

static ctx_t ctx = NULL;

static int _fd_setmode (int fd, int mode)
{
    int flags;

    flags = fcntl (fd, F_GETFL, 0);
    if (flags < 0)
        return -1;
    flags &= ~O_ACCMODE;
    flags |= mode;
    return fcntl (fd, F_SETFL, flags);
}

static int _sendfd (int fd, int fd_xfer, char *name)
{
    struct msghdr msg;
    struct iovec iov;
    struct cmsghdr *cmsg;
    char buf[ CMSG_SPACE (sizeof (fd_xfer)) ];
    int *fdptr;

    memset (&msg, 0, sizeof (msg));

    iov.iov_base = name;
    iov.iov_len = strlen (name);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = buf;
    msg.msg_controllen = sizeof (buf);

    cmsg = CMSG_FIRSTHDR (&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN (sizeof (int));
    fdptr = (int *) CMSG_DATA (cmsg);
    memcpy (fdptr, &fd_xfer, sizeof (int));
    msg.msg_controllen = cmsg->cmsg_len;

    return sendmsg (fd, &msg, 0);
}

static cfd_t *_cfd_create (client_t *c, char *wname)
{
    cfd_t *cfd;
    int sv[2];

    cfd = xzmalloc (sizeof (cfd_t));
    cfd->fd = -1;
    if (socketpair (AF_LOCAL, SOCK_SEQPACKET, 0, sv) < 0) {
        fprintf (stderr, "socketpair: %s\n", strerror (errno));
        exit (1);
    }
    if (_fd_setmode (sv[1], wname ? O_RDONLY : O_WRONLY) < 0) {
        fprintf (stderr, "fcntl: %s\n", strerror (errno));
        exit (1);
    }
    if (_fd_setmode (sv[0], wname ? O_WRONLY : (O_RDONLY | O_NONBLOCK)) < 0) {
        fprintf (stderr, "fcntl: %s\n", strerror (errno));
        exit (1);
    }
    cfd->fd = sv[0];
    if (asprintf (&cfd->name, "%s.fd.%d", c->uuid, c->cfd_id++) < 0)
        oom ();
    if (wname)
        cfd->wname = xstrdup (wname);
    if (_sendfd (c->fd, sv[1], cfd->name) < 0) {
        fprintf (stderr, "sendfd: %s\n", strerror (errno));
        exit (1);
    }
    if (close (sv[1]) < 0) {
        fprintf (stderr, "close: %s\n", strerror (errno));
        exit (1);
    }
    cmb_msg_send (ctx->zs_out, NULL, NULL, 0, "event.%s.open", cfd->name);

    cfd->prev = NULL;
    cfd->next = c->cfds;
    if (cfd->next)
        cfd->next->prev = cfd;
    c->cfds = cfd;

    return cfd;
}

static void _cfd_destroy (client_t *c, cfd_t *cfd)
{
    if (cfd->fd != -1)
        close (cfd->fd);

    if (cfd->prev)
        cfd->prev->next = cfd->next;
    else
        c->cfds = cfd->next;
    if (cfd->next)
        cfd->next->prev = cfd->prev;

    cmb_msg_send (ctx->zs_out, NULL, NULL, 0, "event.%s.close", cfd->name);
    free (cfd->name);
    free (cfd);
}

static int _cfd_count (void)
{
    client_t *c;
    cfd_t *cfd;
    int count = 0;

    for (c = ctx->clients; c != NULL; c = c->next)
        for (cfd = c->cfds; cfd != NULL; cfd = cfd->next)
            count++;
    return count;
}

/* read from cfd->fd, send message to cfd->wname */
static int _cfd_read (cfd_t *cfd)
{
    int n;
    json_object *o, *no;

    assert (cfd->wname != NULL);
    n = read (cfd->fd, cfd->buf, sizeof (cfd->buf));
    if (n <= 0) {
        if (errno != ECONNRESET && errno != EWOULDBLOCK && n != 0)
            fprintf (stderr, "apisrv: cfd read: %s\n", strerror (errno));
        return -1;
    }
    if (!(o = json_object_new_object ()))
        oom ();
    if (!(no = json_object_new_string (cfd->name)))
        oom ();
    json_object_object_add (o, "sender", no);
    cmb_msg_send (ctx->zs_out, o, cfd->buf, n, "%s", cfd->wname);
    json_object_put (o);
    return -1;
}

/* message received for cfd->name, write to cfd->fd */
static int _cfd_write (cfd_t *cfd, zmq_mpart_t *msg)
{
    int len, n;

    if (cfd->wname != NULL) {
        fprintf (stderr, "_cfd_write: discarding message for O_WRONLY fd\n");
        return 0;
    }
    len = cmb_msg_datacpy (msg, cfd->buf, sizeof (cfd->buf));
    n = write (cfd->fd, cfd->buf, len);
    if (n < 0)
        return -1;
    if (n < len) {
        fprintf (stderr, "_cfd_write: short write\n");
        return 0;
    }
    return 0;
}

static void _client_create (int fd)
{
    client_t *c;

    c = xzmalloc (sizeof (client_t));
    c->fd = fd;
    c->cfds = NULL;
    c->prev = NULL;
    c->next = ctx->clients;
    if (c->next)
        c->next->prev = c;
    ctx->clients = c;
}

static void _client_destroy (client_t *c)
{
    while ((c->cfds) != NULL)
        _cfd_destroy (c, c->cfds);

    close (c->fd);

    if (c->prev)
        c->prev->next = c->next;
    else
        ctx->clients = c->next;
    if (c->next)
        c->next->prev = c->prev;
    if (strlen (c->uuid) > 0)
        cmb_msg_send (ctx->zs_out, NULL, NULL, 0,
                      "event.%s.disconnect",c->uuid);
    free (c);
}

static int _client_count (void)
{
    client_t *c;
    int count = 0;

    for (c = ctx->clients; c != NULL; c = c->next)
        count++;
    return count;
}

static void _accept ()
{
    int fd;

    fd = accept (ctx->listen_fd, NULL, NULL); 
    if (fd < 0) {
        fprintf (stderr, "apisrv: accept: %s\n", strerror (errno));
        exit (1);
    }
     _client_create (fd);
}

static int _client_read (client_t *c)
{
    const char *api_subscribe = "api.subscribe.";
    const char *api_setuuid = "api.setuuid.";
    const char *api_fdopen_write = "api.fdopen.write.";
    int taglen, totlen;

    totlen = recv (c->fd, ctx->buf, sizeof (ctx->buf), MSG_DONTWAIT);
    if (totlen <= 0) {
        if (errno != ECONNRESET && errno != EWOULDBLOCK && totlen != 0)
            fprintf (stderr, "apisrv: API read: %s\n", strerror (errno));
        return -1;
    }
    taglen = strnlen (ctx->buf, totlen);
    if (taglen == totlen) {
        fprintf (stderr, "apisrv: received corrupted API buffer\n");
	    return -1;
    }

    /* internal: api.unsubscribe */
    if (!strcmp (ctx->buf, "api.unsubscribe")) {
        if (c->subscription) {
            free (c->subscription);
            c->subscription = NULL;
        }

    /* internal: api.subscribe */
    } else if (!strncmp (ctx->buf, api_subscribe, strlen (api_subscribe))) {
        char *p = ctx->buf + strlen (api_subscribe);
        if (c->subscription)
            free (c->subscription);
        c->subscription = xstrdup (p);

    /* internal: api.setuuid */
    } else if (!strncmp (ctx->buf, api_setuuid, strlen (api_setuuid))) {
        char *p = ctx->buf + strlen (api_setuuid);
        snprintf (c->uuid, sizeof (c->uuid), "%s", p);
        cmb_msg_send (ctx->zs_out, NULL, NULL, 0, "event.%s.connect", c->uuid);

    /* internal: api.fdopen.read */
    } else if (!strcmp (ctx->buf, "api.fdopen.read")) {
        _cfd_create (c, NULL);

    /* internal: api.fdopen.write */
    } else if (!strncmp (ctx->buf, api_fdopen_write,
                                                strlen (api_fdopen_write))) {
        char *p = ctx->buf + strlen (api_fdopen_write);
        _cfd_create (c, p);
            
    /* route other */
    } else {
        zmq_mpart_t msg;
        _zmq_mpart_init (&msg);
        cmb_msg_frombuf (&msg, ctx->buf, totlen);
        _zmq_mpart_send (ctx->zs_out, &msg, 0);
    }

    return 0;
}

static void _readmsg (bool *shutdownp)
{
    zmq_mpart_t msg;
    client_t *c;
    cfd_t *cfd;
    int len;

    _zmq_mpart_init (&msg);
    _zmq_mpart_recv (ctx->zs_in, &msg, 0);

    if (cmb_msg_match (&msg, "event.cmb.shutdown")) {
        *shutdownp = true;
        goto done;
    }

    len = cmb_msg_tobuf (&msg, ctx->buf, sizeof (ctx->buf));
    if (len < 0) {
        fprintf (stderr, "_readmsg: dropping bogus message\n");
        goto done;
    }

    /* send it to all API clients whose subscription matches */
    for (c = ctx->clients; c != NULL; ) {
        client_t *deleteme = NULL;
        int n;

        if (c->subscription && cmb_msg_match (&msg, c->subscription)) {
            n = send (c->fd, ctx->buf, len, 0);
            if (n < len)
                deleteme = c; 
        }
        c = c->next;
        if (deleteme)
            _client_destroy (deleteme);
    }
    /* also look for matches on any open client fds */
    for (c = ctx->clients; c != NULL; c = c->next) {
        for (cfd = c->cfds; cfd != NULL; ) {
            cfd_t *deleteme = NULL;
            if (cmb_msg_match (&msg, cfd->name)) {
                if (_cfd_write (cfd, &msg) < 0)
                    deleteme = cfd;
            }
            cfd = cfd->next;
            if (deleteme)
                _cfd_destroy (c, deleteme);
        }
    }
done:
    _zmq_mpart_close (&msg);
}

static bool _poll (void)
{
    client_t *c;
    cfd_t *cfd;
    bool shutdown = false;
    int zpa_len = _client_count () + _cfd_count () + 2;
    zmq_pollitem_t *zpa = xzmalloc (sizeof (zmq_pollitem_t) * zpa_len);
    int i;

    /* zmq sockets */
    zpa[0].socket = ctx->zs_in;
    zpa[0].events = ZMQ_POLLIN;
    zpa[0].fd = -1;
    zpa[1].events = ZMQ_POLLIN | ZMQ_POLLERR;
    zpa[1].fd = ctx->listen_fd;
    /* client fds */ 
    for (i = 2, c = ctx->clients; c != NULL; c = c->next) {
        for (cfd = c->cfds; cfd != NULL; cfd = cfd->next, i++) {
            zpa[i].events = ZMQ_POLLERR;
            zpa[i].fd = cfd->fd;
            if (cfd->wname)
                zpa[i].events |= ZMQ_POLLIN;
        }
    }
    /* clients */
    for (c = ctx->clients; c != NULL; c = c->next, i++) {
        zpa[i].events = ZMQ_POLLIN | ZMQ_POLLERR;
        zpa[i].fd = c->fd;
    }
    assert (i == zpa_len);

    if (zmq_poll (zpa, zpa_len, -1) < 0) {
        fprintf (stderr, "apisrv: zmq_poll: %s\n", strerror (errno));
        exit (1);
    }

    /* client fds */
    for (i = 2, c = ctx->clients; c != NULL; c = c->next) {
        for (cfd = c->cfds; cfd != NULL; i++) {
            cfd_t *deleteme = NULL;
            assert (cfd->fd == zpa[i].fd);
            if (zpa[i].revents & ZMQ_POLLIN) {
                while (_cfd_read (cfd) != -1)
                    ;
                if (errno != EWOULDBLOCK)
                    deleteme = cfd;
            }
            if (zpa[i].revents & ZMQ_POLLERR)
                deleteme = cfd;
            cfd = cfd->next;
            if (deleteme)
                _cfd_destroy (c, deleteme);
        }
    }
    /* clients - can modify client fds list (so do after client fds) */
    for (c = ctx->clients; c != NULL; i++) {
        client_t *deleteme = NULL;
        assert (c->fd == zpa[i].fd);
        if (zpa[i].revents & ZMQ_POLLIN) {
            while (_client_read (c) != -1)
                ;
            if (errno != EWOULDBLOCK)
                deleteme = c;
        }
        if (zpa[i].revents & ZMQ_POLLERR)
            deleteme = c;
        c = c->next;
        if (deleteme)
            _client_destroy (deleteme);
    }

    /* zmq sockets - can modify client list (so do after clients) */
    if (zpa[1].revents & ZMQ_POLLIN)
        _accept (ctx);
    if (zpa[1].revents & ZMQ_POLLERR) {
        fprintf (stderr, "apisrv: poll error on listen fd\n");
        exit (1);
    }
    if (zpa[0].revents & ZMQ_POLLIN)
        _readmsg (&shutdown);

    free (zpa);

    return ! shutdown;
}

static void _listener_init (void)
{
    struct sockaddr_un addr;
    int fd;

    fd = socket (AF_UNIX, SOCK_SEQPACKET, 0);
    if (fd < 0) {
        fprintf (stderr, "socket: %s\n", strerror (errno));
        exit (1);
    }

    if (remove (ctx->sockname) < 0 && errno != ENOENT) {
        fprintf (stderr, "remove %s: %s\n", ctx->sockname, strerror (errno));
        exit (1);
    } 

    memset (&addr, 0, sizeof (struct sockaddr_un));
    addr.sun_family = AF_UNIX;
    strncpy (addr.sun_path, ctx->sockname, sizeof (addr.sun_path) - 1);

    if (bind (fd, (struct sockaddr *)&addr, sizeof (struct sockaddr_un)) < 0) {
        fprintf (stderr, "bind: %s\n", strerror (errno));
        exit (1);
    }

    if (listen (fd, LISTEN_BACKLOG) < 0) {
        fprintf (stderr, "listen: %s\n", strerror (errno));
        exit (1);
    }

    ctx->listen_fd = fd;
}

static void _listener_fini (void)
{
    if (close (ctx->listen_fd) < 0) {
        fprintf (stderr, "listen: %s\n", strerror (errno));
        exit (1);
    }
}

static void *_thread (void *arg)
{
    _listener_init ();
    while (_poll ())
        ;
    _listener_fini ();
    return NULL;
}

void apisrv_init (conf_t *conf, void *zctx, char *sockname)
{
    int err;

    ctx = xzmalloc (sizeof (struct ctx_struct));

    ctx->zs_out = _zmq_socket (zctx, ZMQ_PUSH);
    _zmq_connect (ctx->zs_out, conf->plin_uri);

    ctx->zs_in = _zmq_socket (zctx, ZMQ_SUB);
    _zmq_connect (ctx->zs_in, conf->plout_uri);
    _zmq_subscribe_all (ctx->zs_in);

    ctx->clients = NULL;
    snprintf (ctx->sockname, sizeof (ctx->sockname), "%s", sockname);

    err = pthread_create (&ctx->t, NULL, _thread, NULL);
    if (err) {
        fprintf (stderr, "apisrv_init: pthread_create: %s\n", strerror (err));
        exit (1);
    }
}

void apisrv_fini (void)
{
    int err;

    err = pthread_join (ctx->t, NULL);
    if (err) {
        fprintf (stderr, "apisrv_fini: pthread_join: %s\n", strerror (err));
        exit (1);
    }
    _zmq_close (ctx->zs_in);
    _zmq_close (ctx->zs_out);
    while (ctx->clients != NULL)
        _client_destroy (ctx->clients);
    free (ctx);
    ctx = NULL;
}

/*
 * vi:tabstop=4 shiftwidth=4 expandtab
 */
