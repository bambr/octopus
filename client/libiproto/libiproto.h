/*
 * Copyright (C) 2012 Mail.RU
 * Copyright (C) 2012 Teodor Sigaev
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#ifndef LIBIPROTO_H
#define LIBIPROTO_H

#include <sys/types.h>

/**********************************************************************************
 *                               BLOCKNIG USAGE                                   *
 **********************************************************************************
 *
 * struct iproto_connection_t* conn = li_conn_init(realloc, ...);
 *
 * if ((err = li_connect(conn, "127.0.0.1", 98876, LIBIPROTO_OPT_HAS_4BYTE_ERRCODE)) != ERR_CODE_OK)
 * 		exit(1);
 *
 * struct iproto_request_t *request = li_req_init(conn, MSGCODE, data, len);
 * if ((err = li_write(conn)) != ERR_CODE_NOTHING_TO_DO)
 *		exit(1);
 * if ((err = li_read(conn)) != ERR_CODE_NOTHING_TO_DO) {
 * 		exit(1);
 *
 * ...
 **********************************************************************************
 *                               NONBLOCKNIG USAGE                                *
 **********************************************************************************
 * int fd = li_get_fd(conn);
 *
 * while(42) {
 * 	state = poll(fd);
 *
 *	if (state & POLLIN) {
 *		iproto_request_t	*request;
 *		errcode = li_read(conn);
 *
 *		while((request = li_get_ready_reqs(conn)) != NULL) {
 *			...
 *			li_req_free(request);
 *		}
 *	}
 *
 *	if (state & POLLOUT) {
 *		while(some .. ) {
 *			iproto_request_t	*request = li_req_init(...);
 *		}
 *		errcode = li_write(conn);
 *	}
 * }
 **********************************************************************************/


/*
 * memory allocation callback.
 * void* memalloc(void* ptr, size_t *size);
 * it should follow following rules:
 *  - memalloc(NULL, size > 0)  malloc equivalent
 *  - memalloc(ptr, size > 0)   realloc
 *  - memalloc(ptr, 0)          free
 */

#ifndef MEMALLOC_TYPE_DEFINED
#define MEMALLOC_TYPE_DEFINED
typedef void* (*memalloc)(void*, size_t);
#endif

struct memory_arena_pool_t;

struct memory_arena_pool_t* 	map_alloc(memalloc sp_alloc, u_int32_t maxArenas, size_t memoryArenaSize);
void   				map_free(struct memory_arena_pool_t *rap);


/* errcode demistification */

#define TEMPORARY_ERR_CODE_FLAG		(0x01)
#define FATAL_ERR_CODE_FLAG		(0x02)
#define LIBIPROTO_ERR_CODE_FLAG		(0x04)

#define	ERR_CODE_IS_TEMPORARY(x)	((x) & TEMPORARY_ERR_CODE_FLAG)
#define	ERR_CODE_IS_FATAL(x)		((x) & FATAL_ERR_CODE_FLAG)
#define ERR_CODE_IS_CLIENT(x)		((x) & LIBIPROTO_ERR_CODE_FLAG)


/* client's error codes */

#define LIBIPROTO_ERROR_CODES(_)                                           					\
    _(ERR_CODE_HOST_UNKNOWN,		((0x01) << 16) | (LIBIPROTO_ERR_CODE_FLAG | FATAL_ERR_CODE_FLAG), 	\
      					"host unknown")								\
    _(ERR_CODE_CONNECT_ERR,		((0x02) << 16) | (LIBIPROTO_ERR_CODE_FLAG | FATAL_ERR_CODE_FLAG), 	\
      					"connection error")    							\
    _(ERR_CODE_PROTO_ERR,		((0x03) << 16) | (LIBIPROTO_ERR_CODE_FLAG | FATAL_ERR_CODE_FLAG), 	\
      					"protocol error")    							\
    _(ERR_CODE_NOTHING_TO_DO,		((0x04) << 16) | LIBIPROTO_ERR_CODE_FLAG, 				\
      					"nothing to do")    							\
    _(ERR_CODE_ALREADY_CONNECTED,	((0x05) << 16) | LIBIPROTO_ERR_CODE_FLAG, 				\
      					"already connected")    						\
    _(ERR_CODE_CONNECT_IN_PROGRESS,	((0x06) << 16) | LIBIPROTO_ERR_CODE_FLAG, 				\
      					"connect is in progress")    						\
    _(ERR_CODE_REQUEST_IN_PROGRESS,	((0x07) << 16) | LIBIPROTO_ERR_CODE_FLAG, 				\
      					"request is in progress")    						\
    _(ERR_CODE_REQUEST_IN_SEND,		((0x08) << 16) | LIBIPROTO_ERR_CODE_FLAG, 				\
      					"request is in sending")    						\
    _(ERR_CODE_REQUEST_IN_RECV,		((0x09) << 16) | LIBIPROTO_ERR_CODE_FLAG, 				\
      					"request is on recieving")    						\
    _(ERR_CODE_REQUEST_READY,		((0x0a) << 16) | LIBIPROTO_ERR_CODE_FLAG, 				\
      					"request is ready")							\
    _(ERR_CODE_CONNECT_NON_BLOCK,	((0x0b) << 16) | LIBIPROTO_ERR_CODE_FLAG,				\
    					"connect is non blocking")						\
    _(ERR_CODE_OPERATION_TIMEOUT,	((0x0c) << 16) | LIBIPROTO_ERR_CODE_FLAG,				\
    					"operation timeout")

/* Macros to define enum and corresponding strings. */
#ifndef ENUM_INITIALIZER
#  define ENUM_DEF(s, v, d...) s = v,
#  define ENUM_INITIALIZER(define) { define(ENUM_DEF) }
#endif
#ifndef ENUM_STR_INITIALIZER
#  define ENUM_STR_DEF(s, v, d...) [s] = #s,
#  define ENUM_STR_INITIALIZER(define) { define(ENUM_STR_DEF) }
#endif

extern void errcode_add_desc(u_int32_t errcode, const char *desc);
extern const char* errcode_desc(u_int32_t errcode);
#ifndef ERRCODE_ADD
#  define ERRCODE_DESCRIPTION(s, v, d ...) errcode_add_desc((v), (d));
#  define ERRCODE_STRINGIFY(s, v) errcode_add_desc((v), #s);
#  define ERRCODE_ADD(how, define) do { define(how) } while(0)
#endif

#define LIBIPROTO_OPT_NONE		0x00
#define LIBIPROTO_OPT_NONBLOCK		0x01
#define LIBIPROTO_OPT_HAS_4BYTE_ERRCODE	0x02
#define LIBIPROTO_OPT_TCP_NODELAY	0x04
#define LIBIPROTO_OPT_HELLO		0x08

struct iproto_connection_t;
struct iproto_request_t;

struct iproto_connection_t*	li_conn_init(memalloc sp_alloc, struct memory_arena_pool_t *rap,
					     struct memory_arena_pool_t *reqap /* optional, request arena */ );
u_int32_t			li_connect(struct iproto_connection_t *c, const char *server, int port, u_int32_t opt);
u_int32_t			li_uconnect(struct iproto_connection_t *c, const char *path, u_int32_t opt);
// connect with timeout (msec)
u_int32_t			li_connect_timeout(struct iproto_connection_t *c, const char *server, int port, u_int32_t opt, u_int32_t timeout);
u_int32_t			li_uconnect_timeout(struct iproto_connection_t *c, const char *path, u_int32_t opt, u_int32_t timeout);
int				li_get_fd(struct iproto_connection_t *c);
const char*			li_get_addr(struct iproto_connection_t *c);
void				li_close(struct iproto_connection_t *c);
void				li_free(struct iproto_connection_t *c);

u_int32_t			li_n_requests(struct iproto_connection_t *c);
u_int32_t			li_n_requests_in_progress(struct iproto_connection_t *c);

typedef enum LiConnectionState {
	LI_NOT_CONNECTED 	= 0x00,
	LI_CONNECTED 		= 0x01,
	LI_CONNECT_IN_PROGRESS	= 0x02,
	LI_CONNECT_ERROR	= 0x03,
	/* LI_WANT_* are OR'ed with previous states */
	LI_WANT_READ		= 0x04,
	LI_WANT_WRITE		= 0x08
} LiConnectionState;
LiConnectionState		li_io_state(struct iproto_connection_t *c);


u_int32_t			li_write(struct iproto_connection_t *c);
u_int32_t			li_read(struct iproto_connection_t *c);
// read and write with timeout (msec)
u_int32_t			li_write_timeout(struct iproto_connection_t *c, u_int32_t timeout);
u_int32_t			li_read_timeout(struct iproto_connection_t *c, u_int32_t timeout);

struct iproto_request_t*	li_get_ready_reqs(struct iproto_connection_t *c);

struct iproto_request_t*	li_req_ushard_init(struct iproto_connection_t* c,
					    u_int16_t msg_code, u_int16_t ushard_id, void *data, size_t size);
struct iproto_request_t*	li_req_ushard_init_copy(struct iproto_connection_t* c,
					    u_int16_t msg_code, u_int16_t ushard_id, void *data, size_t size);
struct iproto_request_t*	li_req_init(struct iproto_connection_t* c,
					    u_int32_t msg_code, void *data, size_t size);
struct iproto_request_t*	li_req_init_copy(struct iproto_connection_t* c,
					    u_int32_t msg_code, void *data, size_t size);
void 				li_req_set_assoc_data(struct iproto_request_t *r, void *data);
void* 				li_req_get_assoc_data(struct iproto_request_t *r);
u_int32_t			li_req_state(struct iproto_request_t* r);
void*				li_req_response_data(struct iproto_request_t* r, size_t *size);
void*               		li_req_request_data(struct iproto_request_t* r, size_t *size);
void				li_req_free(struct iproto_request_t* r);
uint32_t                        li_req_sync(struct iproto_request_t* r);

#endif
