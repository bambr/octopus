/*
 * Copyright (C) 2010, 2011, 2012 Mail.RU
 * Copyright (C) 2010, 2011, 2012 Yuriy Vostrikov
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

#import <util.h>
#import <fiber.h>
#import <say.h>
#import <pickle.h>
#import <assoc.h>
#import <net_io.h>
#import <index.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>

#include <third_party/luajit/src/lua.h>
#include <third_party/luajit/src/lualib.h>
#include <third_party/luajit/src/lauxlib.h>

#import <mod/box/box.h>
#import <mod/box/moonbox.h>


static int
tuple_len_(struct lua_State *L)
{
	struct tnt_object *obj = *(void **)luaL_checkudata(L, 1, objectlib_name);
	struct box_tuple *tuple = box_tuple(obj);
	lua_pushnumber(L, tuple->cardinality);
	return 1;
}

static int
tuple_index_(struct lua_State *L)
{
	struct tnt_object *obj = *(void **)luaL_checkudata(L, 1, objectlib_name);
	struct box_tuple *tuple = box_tuple(obj);

	int i = luaL_checkint(L, 2);
	if (i >= tuple->cardinality) {
		lua_pushliteral(L, "index too small");
		lua_error(L);
	}

	void *field = tuple_field(tuple, i);
	u32 len = LOAD_VARINT32(field);
	lua_pushlstring(L, field, len);
	return 1;
}

static const struct luaL_reg object_mt [] = {
	{"__len", tuple_len_},
	{"__index", tuple_index_},
	{NULL, NULL}
};

#if 0
struct box_tuple *
luaT_toboxtuple(struct lua_State *L, int table)
{
	luaL_checktype(L, table, LUA_TTABLE);

	u32 bsize = 0, cardinality = lua_objlen(L, table);

	for (int i = 0; i < cardinality; i++) {
		lua_rawgeti(L, table, i + 1);
		u32 len = lua_objlen(L, -1);
		lua_pop(L, 1);
		bsize += varint32_sizeof(len) + len;
	}

	struct box_tuple *tuple = tuple_alloc(bsize);
	tuple->cardinality = cardinality;

	u8 *p = tuple->data;
	for (int i = 0; i < cardinality; i++) {
		lua_rawgeti(L, table, i + 1);
		size_t len;
		const char *str = lua_tolstring(L, -1, &len);
		lua_pop(L, 1);

		p = save_varint32(p, len);
		memcpy(p, str, len);
		p += len;
	}

	return tuple;
}
#endif



const char *netmsg_metaname = "Tarantool.netmsg";
const char *netmsgpromise_metaname = "Tarantool.netmsg.promise";

static int
luaT_pushnetmsg(struct lua_State *L)
{
	struct netmsg_head *h = lua_newuserdata(L, sizeof(struct netmsg_head));
	luaL_getmetatable(L, netmsg_metaname);
	lua_setmetatable(L, -2);

	TAILQ_INIT(&h->q);
	h->pool = NULL;
	h->bytes = 0;
	return 1;
}

static struct netmsg_head *
luaT_checknetmsg(struct lua_State *L, int i)
{
	return luaL_checkudata(L, i, netmsg_metaname);
}

static int
netmsg_gc(struct lua_State *L)
{
	struct netmsg_head *h = luaT_checknetmsg(L, 1);
	struct netmsg *m, *tmp;

	TAILQ_FOREACH_SAFE(m, &h->q, link, tmp)
		netmsg_release(m);
	return 0;
}

static int
netmsg_add_iov(struct lua_State *L)
{
	struct netmsg_head *h = luaT_checknetmsg(L, 1);
	struct netmsg *m = netmsg_tail(h);

	switch (lua_type (L, 2)) {
	case LUA_TNIL:
		lua_createtable(L, 2, 0);
		luaL_getmetatable(L, netmsgpromise_metaname);
		lua_setmetatable(L, -2);

		struct iovec *v = net_reserve_iov(&m);
		lua_pushlightuserdata(L, v);
		lua_rawseti(L, -2, 1);

		lua_pushvalue(L, 1);
		lua_rawseti(L, -2, 2);
		return 1;

	case LUA_TSTRING:
		net_add_lua_iov(&m, L, 2);
		return 0;

	case LUA_TUSERDATA: {
		struct tnt_object *obj = *(void **)luaL_checkudata(L, 2, objectlib_name);
		struct box_tuple *tuple = box_tuple(obj);
		net_add_ref_iov(&m, obj, &tuple->bsize,
				tuple->bsize + sizeof(tuple->bsize) +
				sizeof(tuple->cardinality));
		return 0;
	}
	default:
		return luaL_argerror(L, 2, "expected nil, string or tuple");
	}
}


static int
netmsg_fixup_promise(struct lua_State *L)
{
	lua_rawgeti(L, 1, 1);
	struct iovec *v = lua_touserdata(L, -1);
	v->iov_base = (char *) luaL_checklstring(L, 2, &v->iov_len);
	lua_pop(L, 1);
	lua_rawgeti(L, 1, 2);
	struct netmsg_head *h = luaT_checknetmsg(L, -1);
	h->bytes += v->iov_len;
	return 0;
}

static const struct luaL_reg netmsg_lib [] = {
	{"alloc", luaT_pushnetmsg},
	{"add_iov", netmsg_add_iov},
	{"fixup_promise", netmsg_fixup_promise},
	{NULL, NULL}
};

static const struct luaL_reg netmsg_mt [] = {
	{"__gc", netmsg_gc},
	{NULL, NULL}
};



static int
luaT_box_dispatch(struct lua_State *L)
{
	u16 op = luaL_checkinteger(L, 1);
	size_t len;
	const char *req = luaL_checklstring(L, 2, &len);
	struct BoxTxn *txn = [BoxTxn palloc];

	@try {
		[txn prepare:op data:req len:len];
		if ([recovery submit:txn] != 1)
			iproto_raise(ERR_CODE_UNKNOWN_ERROR, "unable write row");
		[txn commit];

		if (txn->obj != NULL) {
			luaT_pushobject(L, txn->obj);
			return 1;
		}
	}
	@catch (Error *e) {
		[txn rollback];
		lua_pushstring(L, e->reason);
		lua_error(L);
	}
	return 0;
}

static int
luaT_box_index(struct lua_State *L)
{
	int n = luaL_checkinteger(L, 1);
	int i = luaL_checkinteger(L, 2);
	if (n < 0 || n >= object_space_count) {
		lua_pushliteral(L, "bad object_space num");
		lua_error(L);
	}
	if (i < 0 || i >= MAX_IDX) {
		lua_pushliteral(L, "bad index num");
		lua_error(L);
	}

	Index *index = object_space_registry[n].index[i];
	if (!index)
		return 0;
	luaT_pushindex(L, index);
	return 1;
}

static const struct luaL_reg boxlib [] = {
	{"index", luaT_box_index},
	{"dispatch", luaT_box_dispatch},
	{NULL, NULL}
};



static int
luaT_pushfield(struct lua_State *L)
{
	size_t len, flen;
	const char *str = luaL_checklstring(L, 1, &len);
	flen = len + varint32_sizeof(len);
	u8 *dst;
	/* FIXME: this will crash, given str is large enougth */
	if (flen > 128)
		dst = xmalloc(flen);
	else
		dst = alloca(flen);
	u8 *tail = save_varint32(dst, len);
	memcpy(tail, str, len);
	lua_pushlstring(L, (char *)dst, flen);
	if (flen > 128)
		free(dst);
	return 1;
}

static int
luaT_pushvarint32(struct lua_State *L)
{
	u32 i = luaL_checkinteger(L, 1);
	u8 buf[5], *end;
	end = save_varint32(buf, i);
	lua_pushlstring(L, (char *)buf, end - buf);
	return 1;
}

static int
luaT_pushu32(struct lua_State *L)
{
	u32 i = luaL_checkinteger(L, 1);
	u8 *dst = alloca(sizeof(i));
	memcpy(dst, &i, sizeof(i));
	lua_pushlstring(L, (char *)dst, sizeof(i));
	return 1;
}

static int
luaT_pushu16(struct lua_State *L)
{
	u16 i = luaL_checkinteger(L, 1);
	u8 *dst = alloca(sizeof(i));
	memcpy(dst, &i, sizeof(i));
	lua_pushlstring(L, (char *)dst, sizeof(i));
	return 1;
}

static int
luaT_pushu8(struct lua_State *L)
{
	u8 i = luaL_checkinteger(L, 1);
	u8 *dst = alloca(sizeof(i));
	memcpy(dst, &i, sizeof(i));
	lua_pushlstring(L, (char *)dst, sizeof(i));
	return 1;
}

void
luaT_openbox(struct lua_State *L)
{
        lua_getglobal(L, "package");
        lua_getfield(L, -1, "path");
        lua_pushliteral(L, ";mod/box/src-lua/?.lua");
        lua_concat(L, 2);
        lua_setfield(L, -2, "path");
        lua_pop(L, 1);

	luaL_newmetatable(L, netmsgpromise_metaname);
	luaL_newmetatable(L, netmsg_metaname);
	luaL_register(L, NULL, netmsg_mt);
	luaL_register(L, "netmsg", netmsg_lib);
	lua_pop(L, 3);

	lua_getglobal(L, "string");
	lua_pushcfunction(L, luaT_pushfield);
	lua_setfield(L, -2, "tofield");
	lua_pushcfunction(L, luaT_pushvarint32);
	lua_setfield(L, -2, "tovarint32");
	lua_pushcfunction(L, luaT_pushu32);
	lua_setfield(L, -2, "tou32");
	lua_pushcfunction(L, luaT_pushu16);
	lua_setfield(L, -2, "tou16");
	lua_pushcfunction(L, luaT_pushu8);
	lua_setfield(L, -2, "tou8");
	lua_pop(L, 1);

	luaL_newmetatable(L, objectlib_name);
	luaL_register(L, NULL, object_mt);
	lua_pop(L, 1);

	luaL_findtable(L, LUA_GLOBALSINDEX, "box", 0);
	luaL_register(L, NULL, boxlib);

	lua_createtable(L, 0, 0); /* namespace_registry */
	for (uint32_t n = 0; n < object_space_count; ++n) {
		if (!object_space_registry[n].enabled)
			continue;

		lua_createtable(L, 0, 0); /* namespace */

		lua_pushliteral(L, "cardinality");
		lua_pushinteger(L, object_space_registry[n].cardinality);
		lua_rawset(L, -3); /* namespace.cardinality = cardinality */

		lua_pushliteral(L, "n");
		lua_pushinteger(L, n);
		lua_rawset(L, -3); /* namespace.n = n */

		lua_rawseti(L, -2, n); /* namespace_registry[n] = namespace */
	}
	lua_setfield(L, -2, "object_space");
	lua_pop(L, 1);

	lua_getglobal(L, "require");
        lua_pushliteral(L, "box_prelude");
	if (lua_pcall(L, 1, 0, 0) != 0)
		panic("moonbox: %s", lua_tostring(L, -1));
}


static int
luaT_find_proc(lua_State *L, char *fname, i32 len)
{
	lua_pushvalue(L, LUA_GLOBALSINDEX);
	do {
		char *e = memchr(fname, '.', len);
		if (e == NULL)
			e = fname + len;

		if (lua_isnil(L, -1))
			return 0;
		lua_pushlstring(L, fname, e - fname);
		lua_gettable(L, -2);
		lua_remove(L, -2);

		len -= e - fname + 1;
		fname = e + 1;
	} while (len > 0);
	if (lua_isnil(L, -1))
		return 0;
	return 1;
}

void
box_dispach_lua(struct conn *c, struct iproto *request)
{
	lua_State *L = fiber->L;
	struct tbuf data = TBUF(request->data, request->data_len, fiber->pool);

	u32 flags = read_u32(&data); (void)flags; /* compat, ignored */
	u32 flen = read_varint32(&data);
	void *fname = read_bytes(&data, flen);
	u32 nargs = read_u32(&data);

	luaT_pushnetmsg(L);

	if (luaT_find_proc(L, fname, flen) == 0) {
		lua_pop(L, 1);
		iproto_raise_fmt(ERR_CODE_ILLEGAL_PARAMS, "no such proc: %.*s", flen, fname);
	}
	lua_pushvalue(L, 1);
	for (int i = 0; i < nargs; i++)
		read_push_field(L, &data);

	/* FIXME: switch to native exceptions ? */
	if (lua_pcall(L, 1 + nargs, 1, 0)) {
		IProtoError *err = [IProtoError palloc];
		[err init_code:ERR_CODE_ILLEGAL_PARAMS
			  line:__LINE__
			  file:__FILE__
		     backtrace:NULL
			format:"%s", lua_tostring(L, -1)];
		lua_settop(L, 0);
		@throw err;
	}

	struct netmsg_head *h = luaT_checknetmsg(L, 1);
	struct netmsg *m = netmsg_tail(&c->out_messages);
	struct iproto_retcode *reply = iproto_reply(&m, request);
	reply->data_len += h->bytes;
	netmsg_concat(&c->out_messages, h);
	reply->ret_code = luaL_checkinteger(L, 2);
	lua_pop(L, 2);
}

register_source();

