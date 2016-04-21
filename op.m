/*
 * Copyright (C) 2010, 2011, 2012, 2013, 2014 Mail.RU
 * Copyright (C) 2010, 2011, 2012, 2013, 2014 Yuriy Vostrikov
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
#import <iproto.h>
#import <log_io.h>
#import <net_io.h>
#import <pickle.h>
#import <salloc.h>
#import <say.h>
#import <stat.h>
#import <octopus.h>
#import <tbuf.h>
#import <objc.h>
#import <index.h>
#import <paxos.h>
#import <shard.h>

#import <mod/box/box.h>
#import <mod/box/src-lua/moonbox.h>

#include <stdint.h>


static int stat_base;
char * const box_ops[] = ENUM_STR_INITIALIZER(MESSAGES);

void __attribute__((noreturn))
bad_object_type()
{
	raise_fmt("bad object type");
}

void *
next_field(void *f)
{
	u32 size = LOAD_VARINT32(f);
	return (u8 *)f + size;
}

void *
tuple_field(struct tnt_object *obj, size_t i)
{
	void *field = tuple_data(obj);

	if (i >= tuple_cardinality(obj))
		return NULL;

	while (i-- > 0)
		field = next_field(field);

	return field;
}

static struct tnt_object *
tuple_alloc(unsigned cardinality, unsigned size)
{
	struct tnt_object *obj;
	if (cardinality < 256 && size < 256) {
		obj = object_alloc(BOX_SMALL_TUPLE, 0, sizeof(struct box_small_tuple) + size);
		struct box_small_tuple *tuple = box_small_tuple(obj);
		tuple->bsize = size;
		tuple->cardinality = cardinality;
	} else {
		obj = object_alloc(BOX_TUPLE, 1, sizeof(struct box_tuple) + size);
		object_incr_ref(obj);
		struct box_tuple *tuple = box_tuple(obj);
		tuple->bsize = size;
		tuple->cardinality = cardinality;
	}

	say_debug3("tuple_alloc(%u, %u) = %p", cardinality, size, obj + 1);
	return obj;
}

void
tuple_free(struct tnt_object *obj)
{
	switch (obj->type) {
	case BOX_TUPLE:
		object_decr_ref(obj);
		break;
	case BOX_SMALL_TUPLE:
		say_debug("object_free(%p)", obj);
		sfree(obj);
		break;
	default:
		assert(false);
	}
}

ssize_t
fields_bsize(u32 cardinality, const void *data, u32 max_len)
{
	struct tbuf tmp = TBUF(data, max_len, NULL);
	for (int i = 0; i < cardinality; i++)
		read_field(&tmp);

	return tmp.ptr - data;
}

int
tuple_valid(struct tnt_object *obj)
{
	return fields_bsize(tuple_cardinality(obj), tuple_data(obj), tuple_bsize(obj)) ==
		tuple_bsize(obj);
}

void
net_tuple_add(struct netmsg_head *h, struct tnt_object *obj)
{
	switch (obj->type) {
	case BOX_TUPLE: {
		struct box_tuple *tuple = box_tuple(obj);
		size_t size = tuple->bsize + 8;
		net_add_obj_iov(h, obj, &tuple->bsize, size);
		break;
	}
	case BOX_SMALL_TUPLE: {
		struct box_small_tuple *tuple = box_small_tuple(obj);
		struct box_tuple *reply = palloc(h->pool, sizeof(*reply) + tuple->bsize);
		reply->bsize = tuple->bsize;
		reply->cardinality = tuple->cardinality;
		memcpy(reply->data, tuple->data, tuple->bsize);
		net_add_iov(h, (void *)reply, sizeof(*reply) + tuple->bsize);
		break;
	}
	default:
		bad_object_type();
	}
}

static void
box_replace(struct box_txn *txn)
{
	if (!txn->obj)
		return;

	foreach_index(index, txn->object_space) {
		if (index->conf.n == 0 && !txn->pk_affected) {
			if (txn->old_obj == NULL)
				[index replace:txn->obj];
			else {
				[index valid_object:txn->obj];
				txn->index_eqmask |= 1 << index->conf.n;
			}
			continue;
		}
		if (index->conf.unique) {
			struct tnt_object *obj = [index find_obj:txn->obj];
			if (obj == NULL) {
				[index replace:txn->obj];
			} else if (obj == txn->old_obj) {
				[index valid_object:txn->obj];
				txn->index_eqmask |= 1 << index->conf.n;
			} else {
				iproto_raise_fmt(ERR_CODE_INDEX_VIOLATION,
						 "duplicate key value violates unique index %i:%s",
						 index->conf.n, [[index class] name]);
			}
		} else {
			[index replace:txn->obj];
		}
	}
}

enum obj_age {OLD, YOUNG};
static struct tnt_object *
txn_acquire(struct box_txn *txn, struct tnt_object *obj, enum obj_age age)
{
	say_debug2("%s: obj:%p age:%s", __func__, obj, age == YOUNG ? "young" : "old");

	if (obj == NULL)
		return NULL;

	object_lock(obj); /* throws exception on lock failure */
	if (age == YOUNG) {
		txn->obj = obj;
		obj->flags |= GHOST;
	} else {
		txn->old_obj = obj;
	}
	return obj;
}

void
prepare_replace(struct box_txn *txn, size_t cardinality, const void *data, u32 data_len)
{
	if (cardinality == 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "cardinality can't be equal to 0");
	if (data_len == 0 || fields_bsize(cardinality, data, data_len) != data_len)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "tuple encoding error");

	txn_acquire(txn, tuple_alloc(cardinality, data_len), YOUNG);
	memcpy(tuple_data(txn->obj), data, data_len);

	struct tnt_object *obj;
	ev_tstamp wait_st = ev_now();
	int wait_cnt = 0;
	while ((obj = [txn->index find_obj:txn->obj]) && obj->flags & WAL_WAIT) {
		object_yield(obj);
		wait_cnt++;
	}
	if (ev_now() > wait_st+1) {
		say_warn("%s: object_yield cycle %4.3fsec %d times", __func__,
				ev_now() - wait_st, wait_cnt);
	}

	txn_acquire(txn, obj, OLD);
	txn->obj_affected = txn->old_obj != NULL ? 2 : 1;

	if (txn->flags & BOX_ADD && txn->old_obj != NULL)
		iproto_raise(ERR_CODE_NODE_FOUND, "tuple found");
	if (txn->flags & BOX_REPLACE && txn->old_obj == NULL)
		iproto_raise(ERR_CODE_NODE_NOT_FOUND, "tuple not found");

	say_debug("%s: old_obj:%p obj:%p", __func__, txn->old_obj, txn->obj);
	box_replace(txn);
}

static void
do_field_arith(u8 op, struct tbuf *field, const void *arg, u32 arg_size)
{
	if (tbuf_len(field) != arg_size)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "num op arg size not equal to field size");

	switch (arg_size) {
	case 2:
		switch (op) {
		case 1: *(u16 *)field->ptr += *(u16 *)arg; break;
		case 2: *(u16 *)field->ptr &= *(u16 *)arg; break;
		case 3: *(u16 *)field->ptr ^= *(u16 *)arg; break;
		case 4: *(u16 *)field->ptr |= *(u16 *)arg; break;
		default: iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unknown num op");
		}
		break;
	case 4:
		switch (op) {
		case 1: *(u32 *)field->ptr += *(u32 *)arg; break;
		case 2: *(u32 *)field->ptr &= *(u32 *)arg; break;
		case 3: *(u32 *)field->ptr ^= *(u32 *)arg; break;
		case 4: *(u32 *)field->ptr |= *(u32 *)arg; break;
		default: iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unknown num op");
		}
		break;
	case 8:
		switch (op) {
		case 1: *(u64 *)field->ptr += *(u64 *)arg; break;
		case 2: *(u64 *)field->ptr &= *(u64 *)arg; break;
		case 3: *(u64 *)field->ptr ^= *(u64 *)arg; break;
		case 4: *(u64 *)field->ptr |= *(u64 *)arg; break;
		default: iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unknown num op");
		}
		break;
	default: iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "bad num op size");
	}
}

static inline size_t __attribute__((pure))
field_len(const struct tbuf *b)
{
	return varint32_sizeof(tbuf_len(b)) + tbuf_len(b);
}

static size_t
do_field_splice(struct tbuf *field, const void *args_data, u32 args_data_size)
{
	struct tbuf args = TBUF(args_data, args_data_size, NULL);
	struct tbuf *new_field = NULL;
	const u8 *offset_field, *length_field, *list_field;
	u32 offset_size, length_size, list_size;
	i32 offset, length;
	u32 noffset, nlength;	/* normalized values */

	new_field = tbuf_alloc(fiber->pool);

	offset_field = read_field(&args);
	length_field = read_field(&args);
	list_field = read_field(&args);
	if (tbuf_len(&args)!= 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: bad args");

	offset_size = LOAD_VARINT32(offset_field);
	if (offset_size == 0)
		noffset = 0;
	else if (offset_size == sizeof(offset)) {
		offset = *(u32 *)offset_field;
		if (offset < 0) {
			if (tbuf_len(field) < -offset)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
					  "do_field_splice: noffset is negative");
			noffset = offset + tbuf_len(field);
		} else
			noffset = offset;
	} else
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: bad size of offset field");
	if (noffset > tbuf_len(field))
		noffset = tbuf_len(field);

	length_size = LOAD_VARINT32(length_field);
	if (length_size == 0)
		nlength = tbuf_len(field) - noffset;
	else if (length_size == sizeof(length)) {
		if (offset_size == 0)
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
				  "do_field_splice: offset field is empty but length is not");

		length = *(u32 *)length_field;
		if (length < 0) {
			if ((tbuf_len(field) - noffset) < -length)
				nlength = 0;
			else
				nlength = length + tbuf_len(field) - noffset;
		} else
			nlength = length;
	} else
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: bad size of length field");
	if (nlength > (tbuf_len(field) - noffset))
		nlength = tbuf_len(field) - noffset;

	list_size = LOAD_VARINT32(list_field);
	if (list_size > 0 && length_size == 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
			  "do_field_splice: length field is empty but list is not");
	if (list_size > (UINT32_MAX - (tbuf_len(field) - nlength)))
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: list_size is too long");

	say_debug("do_field_splice: noffset = %i, nlength = %i, list_size = %u",
		  noffset, nlength, list_size);

	tbuf_reset(new_field);
	tbuf_append(new_field, field->ptr, noffset);
	tbuf_append(new_field, list_field, list_size);
	tbuf_append(new_field, field->ptr + noffset + nlength, tbuf_len(field) - (noffset + nlength));

	size_t diff = field_len(new_field) - field_len(field);

	*field = *new_field;
	return diff;
}

static void __attribute__((noinline))
prepare_update_fields(struct box_txn *txn, struct tbuf *data)
{
	struct tbuf *fields;
	const u8 *field;
	int i;
	u32 op_cnt;

	u32 key_cardinality = read_u32(data);
	if (key_cardinality != txn->object_space->index[0]->conf.cardinality)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "key fields count doesn't match");

	struct tnt_object *obj;
	void *ptr = data->ptr;
	ev_tstamp wait_st = ev_now();
	int wait_cnt = 0;
	while ((obj = [txn->index find_key:data cardinalty:key_cardinality]) && obj->flags & WAL_WAIT) {
		data->ptr = ptr;
		object_yield(obj);
		wait_cnt++;
	}
	if (ev_now() > wait_st+1) {
		say_warn("%s: object_yield cycle %4.3fsec %d times", __func__,
				ev_now() - wait_st, wait_cnt);
	}

	txn_acquire(txn, obj, OLD);

	op_cnt = read_u32(data);
	if (op_cnt > 128)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "too many ops");
	if (op_cnt == 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "no ops");

	if (txn->old_obj == NULL) {
		/* pretend we parsed all data */
		tbuf_ltrim(data, tbuf_len(data));
		return;
	}
	txn->obj_affected = 1;

	size_t bsize = tuple_bsize(txn->old_obj);
	int cardinality = tuple_cardinality(txn->old_obj);
	void *tdata = tuple_data(txn->old_obj);
	int field_count = cardinality * 1.2;
	fields = palloc(fiber->pool, field_count * sizeof(struct tbuf));

	for (i = 0, field = tdata; i < cardinality; i++) {
		const void *src = field;
		int len = LOAD_VARINT32(field);
		/* .ptr  - start of varint
		   .end  - start of data
		   .free - len(data) */
		fields[i] = (struct tbuf){ .ptr = (void *)src, .end = (void *)field,
					   .free = len, .pool = NULL };
		field += len;
	}

	while (op_cnt-- > 0) {
		u8 op;
		u32 field_no, arg_size;
		const u8 *arg;
		struct tbuf *field = NULL;

		field_no = read_u32(data);
		op = read_u8(data);
		arg = read_field(data);
		arg_size = LOAD_VARINT32(arg);

		for (int i = 0; i < txn->index->conf.cardinality; i++) {
			if (txn->index->conf.field[i].index == field_no) {
				txn->pk_affected = 1;
				break;
			}
		}

		for (int i = txn->index->conf.cardinality - 1; i >= 0 ; i--) {
			if (txn->index->conf.field[i].index == field_no) {
				txn->pk_affected = 1;
				break;
			}
		}

		for (int i = txn->index->conf.cardinality; i != 0 ; i--) {
			if (txn->index->conf.field[i - 1].index == field_no) {
				txn->pk_affected = 1;
				break;
			}
		}

		if (op <= 6) {
			if (field_no >= cardinality)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
					     "update of field beyond tuple cardinality");
			field = &fields[field_no];
		}
		if (op < 6) {
			if (field->pool == NULL) {
				void *field_data = field->end;
				int field_len = field->free;
				int expected_size = MAX(arg_size, field_len);
				field->ptr = palloc(fiber->pool, expected_size ? : 8);
				memcpy(field->ptr, field_data, field_len);
				field->end = field->ptr + field_len;
				field->free = expected_size - field_len;
				field->pool = fiber->pool;
			}
		}

		switch (op) {
		case 0:
			bsize -= field_len(field);
			bsize += varint32_sizeof(arg_size) + arg_size;
			tbuf_reset(field);
			tbuf_append(field, arg, arg_size);
			break;
		case 1 ... 4:
			do_field_arith(op, field, arg, arg_size);
			break;
		case 5:
			bsize += do_field_splice(field, arg, arg_size);
			break;
		case 6:
			if (arg_size != 0)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "delete must have empty arg");
			if (field_no == 0)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unabled to delete PK");

			if (field->pool == NULL) {
				bsize -= tbuf_len(field) + tbuf_free(field);
			} else {
				bsize -= field_len(field);
			}
			for (int i = field_no; i < cardinality - 1; i++)
				fields[i] = fields[i + 1];
			cardinality--;
			break;
		case 7:
			if (field_no == 0)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unabled to insert PK");
			if (field_no > cardinality)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
					     "update of field beyond tuple cardinality");
			if (unlikely(field_count == cardinality)) {
				struct tbuf *tmp = fields;
				fields = p0alloc(fiber->pool,
						 (cardinality + 128) * sizeof(struct tbuf));
				memcpy(fields, tmp, field_count * sizeof(struct tbuf));
			}
			for (int i = cardinality - 1; i >= field_no; i--)
				fields[i + 1] = fields[i];
			void *ptr = palloc(fiber->pool, arg_size);
			fields[field_no] = TBUF(ptr, arg_size, fiber->pool);
			memcpy(fields[field_no].ptr, arg, arg_size);
			bsize += varint32_sizeof(arg_size) + arg_size;
			cardinality++;
			break;
		default:
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "invalid op");
		}
	}

	if (tbuf_len(data) != 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "can't unpack request");

	txn_acquire(txn, tuple_alloc(cardinality, bsize), YOUNG);

	u8 *p = tuple_data(txn->obj);
	i = 0;
	do {
		if (fields[i].pool == NULL) {
			void *ptr = fields[i].ptr;
			void *end = fields[i].end + fields[i].free;
			for (i++; i < cardinality; i++) {
				if (end != fields[i].ptr)
					break;
				else
					end = fields[i].end + fields[i].free;
			}
			memcpy(p, ptr, end - ptr);
			p += end - ptr;
		} else {
			int len = tbuf_len(&fields[i]);
			p = save_varint32(p, len);
			memcpy(p, fields[i].ptr, len);
			p += len;
			i++;
		}
	} while (i < cardinality);

	Index<BasicIndex> *pk = txn->object_space->index[0];
	if (![pk eq:txn->old_obj :txn->obj])
		txn->obj_affected++;

	box_replace(txn);
}

static void __attribute__((noinline))
process_select(struct netmsg_head *h, Index<BasicIndex> *index,
	       u32 limit, u32 offset, struct tbuf *data)
{
	struct tnt_object *obj;
	uint32_t *found;
	u32 count = read_u32(data);
	index_cmp cmp = NULL;

	say_debug("SELECT");
	found = palloc(h->pool, sizeof(*found));
	net_add_iov(h, found, sizeof(*found));
	*found = 0;

	for (u32 i = 0; i < count; i++) {
		u32 c = read_u32(data);
		if (index->conf.unique && index->conf.cardinality == c) {
			obj = [index find_key:data cardinalty:c];

			if (obj == NULL)
				continue;
			if (unlikely(object_ghost(obj)))
				continue;
			if (unlikely(limit == 0))
				continue;
			if (unlikely(offset > 0)) {
				offset--;
				continue;
			}

			(*found)++;
			net_tuple_add(h, obj);
			limit--;
		} else if (index->conf.type == HASH || index->conf.type == NUMHASH) {
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "cardinality mismatch");
		} else {
			Tree *tree = (Tree *)index;
			cmp = cmp ?: [tree compare];
			[tree iterator_init_with_key:data cardinalty:c];
			if (unlikely(limit == 0))
				continue;

			while ((obj = [tree iterator_next_check:cmp]) != NULL) {
				if (unlikely(object_ghost(obj)))
					continue;
				if (unlikely(offset > 0)) {
					offset--;
					continue;
				}

				(*found)++;
				net_tuple_add(h, obj);

				if (--limit == 0)
					break;
			}
		}
	}

	if (tbuf_len(data) != 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "can't unpack request");

	stat_collect(stat_base, SELECT_KEYS, count);
}

static void __attribute__((noinline))
prepare_delete(struct box_txn *txn, struct tbuf *key_data)
{
	u32 c = read_u32(key_data);

	struct tnt_object *obj;
	void *ptr = key_data->ptr;
	ev_tstamp wait_st = ev_now();
	int wait_cnt = 0;
	while ((obj = [txn->index find_key:key_data cardinalty:c]) && obj->flags & WAL_WAIT) {
		key_data->ptr = ptr;
		object_yield(obj);
		wait_cnt++;
	}
	if (ev_now() > wait_st+1) {
		say_warn("%s: object_yield cycle %4.3fsec %d times", __func__,
				ev_now() - wait_st, wait_cnt);
	}

	txn_acquire(txn, obj, OLD);
	txn->obj_affected = txn->old_obj != NULL;
}

void
box_prepare(struct box_txn *txn, struct tbuf *data)
{
	say_debug("%s op:%i", __func__, txn->op);

	i32 n = read_u32(data);
	txn->object_space = object_space(txn->box, n);
	if (txn->object_space->ignored) {
		/* txn->object_space == NULL means this txn will be ignored */
		txn->object_space = NULL;
		return;
	}
	txn->index = txn->object_space->index[0];

	switch (txn->op) {
	case INSERT:
		txn->flags = read_u32(data);
		u32 cardinality = read_u32(data);
		u32 data_len = tbuf_len(data);
		void *tuple_bytes = read_bytes(data, data_len);
		prepare_replace(txn, cardinality, tuple_bytes, data_len);
		break;

	case DELETE:
		txn->flags = read_u32(data); /* RETURN_TUPLE */
	case DELETE_1_3:
		prepare_delete(txn, data);
		break;

	case UPDATE_FIELDS:
		txn->flags = read_u32(data);
		prepare_update_fields(txn, data);
		break;

	case NOP:
		break;

	default:
		iproto_raise_fmt(ERR_CODE_ILLEGAL_PARAMS, "unknown opcode:%"PRIi32, txn->op);
	}

	if (txn->obj) {
		if (txn->object_space->cardinality > 0 &&
		    txn->object_space->cardinality != tuple_cardinality(txn->obj))
		{
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
				     "tuple cardinality must match object_space cardinality");
		}

		if (!tuple_valid(txn->obj))
			iproto_raise(ERR_CODE_UNKNOWN_ERROR, "internal error");
	}
	if (tbuf_len(data) != 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "can't unpack request");
}

void
box_cleanup(struct box_txn *txn)
{
	say_debug3("%s: old_obj:%p obj:%p", __func__, txn->old_obj, txn->obj);
	switch (txn->state) {
	case COMMIT:
		if (txn->old_obj)
			tuple_free(txn->old_obj);
		break;
	case ROLLBACK:
		if (txn->obj)
			tuple_free(txn->obj);
		break;
	default:
		if (!txn->object_space)
			return;
		assert(false);
	}
}

void
box_commit(struct box_txn *txn)
{
	if (!txn->object_space)
		return;

	say_debug2("%s: old_obj:%p obj:%p", __func__, txn->old_obj, txn->obj);

#define small_tuple_overhead (sizeof(struct tnt_object) + sizeof(struct box_small_tuple))
#define tuple_overhead (sizeof(struct gc_oct_object) + sizeof(struct box_tuple))

	txn->state = COMMIT;
	if (txn->obj) {
		foreach_index(index, txn->object_space) {
			if (index->conf.unique &&
			    txn->index_eqmask & 1 << index->conf.n)
				[index replace:txn->obj];
		}
		switch (txn->obj->type) {
		case BOX_TUPLE:
			txn->object_space->obj_bytes += tuple_bsize(txn->obj) + tuple_overhead;
			break;
		case BOX_SMALL_TUPLE:
			txn->object_space->obj_bytes += tuple_bsize(txn->obj) + small_tuple_overhead;
			break;
		default:
			assert(false);
		}
		txn->object_space->slab_bytes += salloc_usable_size(txn->obj);
		object_unlock(txn->obj);
		txn->obj->flags &= ~GHOST;
	}

	if (txn->old_obj) {
		foreach_index(index, txn->object_space) {
			if (!index->conf.unique ||
			    (txn->index_eqmask & 1 << index->conf.n) == 0)
				[index remove:txn->old_obj];
		}
		switch (txn->old_obj->type) {
		case BOX_TUPLE:
			txn->object_space->obj_bytes -= tuple_bsize(txn->old_obj) + tuple_overhead;
			break;
		case BOX_SMALL_TUPLE:
			txn->object_space->obj_bytes -= tuple_bsize(txn->old_obj) + small_tuple_overhead;
			break;
		default:
			assert(false);
		}

		txn->object_space->slab_bytes -= salloc_usable_size(txn->old_obj);
	}

	stat_collect(stat_base, txn->op, 1);
}

void
box_rollback(struct box_txn *txn)
{
	if (!txn->object_space)
		return;

	say_debug2("%s: old_obj:%p obj:%p", __func__, txn->old_obj, txn->obj);
	txn->state = ROLLBACK;
	if (txn->old_obj)
		object_unlock(txn->old_obj);

	if (txn->obj == NULL)
		return;

	foreach_index(index, txn->object_space) {
		if (index->conf.unique && [index find_obj:txn->obj] != txn->obj)
			continue;

		@try {
			[index remove:txn->obj];
		}
		@catch (IndexError *e) {
			/* obj with invalid shape will cause exception on txn_prepare.
			   since index traversing order is same for prepare and rollback
			   there is no references to obj in following indexes */
			[e release];
			break;
		}
	}
}


static Box *
RT_EXECUTOR(struct iproto *msg)
{
	return (shard_rt + msg->shard_id)->shard->executor;
}

#if CFG_lua_path
static void
box_lua_cb(struct netmsg_head *wbuf, struct iproto *request)
{
	say_debug("%s: op:0x%02x sync:%u", __func__, request->msg_code, request->sync);

	@try {
		ev_tstamp start = ev_now(), stop;

		box_dispach_lua(wbuf, request);
		stat_collect(stat_base, EXEC_LUA, 1);

		stop = ev_now();
		if (stop - start > cfg.too_long_threshold)
			say_warn("too long %s: %.3f sec", box_ops[request->msg_code], stop - start);
	}
	@catch (Error *e) {
		say_warn("aborting lua request, [%s reason:\"%s\"] at %s:%d",
			 [[e class] name], e->reason, e->file, e->line);
		if (e->backtrace)
			say_debug("backtrace:\n%s", e->backtrace);
		@throw;
	}
}
#endif


static struct rwlock lock;

void
box_meta_cb(struct netmsg_head *wbuf, struct iproto *request)
{
	Box *box = RT_EXECUTOR(request);

	say_debug2("%s: op:0x%02x sync:%u", __func__, request->msg_code, request->sync);
	if ([box->shard is_replica])
		iproto_raise(ERR_CODE_NONMASTER, "replica is readonly");

	if (box->shard->dummy // && cfg.object_space
		)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "metadata updates are forbidden because cfg.object_space is configured");

	wlock(&lock);
	if (cfg.object_space)
		say_warn("metadata updates with configured cfg.object_space");

	struct box_meta_txn txn = { .op = request->msg_code,
				    .box = box };
	@try {
		@try {
			box_prepare_meta(&txn, &TBUF(request->data, request->data_len, NULL));
			if ([box->shard submit:request->data
					   len:request->data_len
					   tag:request->msg_code<<5|TAG_WAL] != 1)
				iproto_raise(ERR_CODE_UNKNOWN_ERROR, "unable write wal row");
		}
		@catch (id e) {
			box_rollback_meta(&txn);
			@throw;
		}
		@try {
			box_commit_meta(&txn);
			iproto_reply_small(wbuf, request, ERR_CODE_OK);
		}
		@catch (Error *e) {
			panic_exc_fmt(e, "can't handle exception after WAL write: %s", e->reason);
		}
		@catch (id e) {
			panic_exc_fmt(e, "can't handle unknown exception after WAL write");
		}
	}
	@finally {
		wunlock(&lock);
	}
}

static void
box_cb(struct netmsg_head *wbuf, struct iproto *request)
{
	Box *box = RT_EXECUTOR(request);
	say_debug2("%s: c:%p op:0x%02x sync:%u", __func__, NULL, request->msg_code, request->sync);
	if ([box->shard is_replica])
		iproto_raise(ERR_CODE_NONMASTER, "replica is readonly");

	struct box_txn txn = { .op = request->msg_code & 0xffff,
			       .box = box };
	rlock(&lock);
	@try {
		ev_tstamp start = ev_now(), stop;
		@try {
			box_prepare(&txn, &TBUF(request->data, request->data_len, NULL));

			if (!txn.object_space)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "ignored object space");

			if (txn.obj_affected > 0 && txn.object_space->wal) {
				if ([box->shard submit:request->data
						   len:request->data_len
						   tag:request->msg_code<<5|TAG_WAL] != 1)
					iproto_raise(ERR_CODE_UNKNOWN_ERROR, "unable write wal row");
			}
		}
		@catch (Error *e) {
			if (e->file && strcmp(e->file, "src/paxos.m") != 0) {
				say_warn("aborting txn, [%s reason:\"%s\"] at %s:%d peer:%s",
					 [[e class] name], e->reason, e->file, e->line,
					 net_fd_name(container_of(wbuf, struct netmsg_io, wbuf)->fd));
				if (e->backtrace)
					say_debug("backtrace:\n%s", e->backtrace);
			}
			box_rollback(&txn);
			@throw;
		}
		@try {
			box_commit(&txn);
			struct iproto_retcode *reply = iproto_reply(wbuf, request, ERR_CODE_OK);
			net_add_iov_dup(wbuf, &txn.obj_affected, sizeof(u32));
			if (txn.flags & BOX_RETURN_TUPLE) {
				if (txn.obj)
					net_tuple_add(wbuf, txn.obj);
				else if (request->msg_code == DELETE && txn.old_obj)
					net_tuple_add(wbuf, txn.old_obj);
			}
			iproto_reply_fixup(wbuf, reply);

			stop = ev_now();
			if (stop - start > cfg.too_long_threshold)
				say_warn("too long %s: %.3f sec", box_ops[txn.op], stop - start);
		}
		@catch (Error *e) {
			panic_exc_fmt(e, "can't handle exception after WAL write: %s", e->reason);
		}
		@catch (id e) {
			panic_exc_fmt(e, "can't handle unknown exception after WAL write");
		}
	}
	@finally {
		runlock(&lock);
		box_cleanup(&txn);
	}
}

static void
box_select_cb(struct netmsg_head *wbuf, struct iproto *request)
{
	Box *box = RT_EXECUTOR(request);
	struct tbuf data = TBUF(request->data, request->data_len, fiber->pool);
	struct iproto_retcode *reply = iproto_reply(wbuf, request, ERR_CODE_OK);
	struct object_space *obj_spc;

	i32 n = read_u32(&data);
	u32 i = read_u32(&data);
	u32 offset = read_u32(&data);
	u32 limit = read_u32(&data);

	obj_spc = object_space(box, n);

	if (i > MAX_IDX)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "index too big");

	if ((obj_spc->index[i]) == NULL)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "index is invalid");

	process_select(wbuf, obj_spc->index[i], limit, offset, &data);
	iproto_reply_fixup(wbuf, reply);
	stat_collect(stat_base, request->msg_code & 0xffff, 1);
}

#define foreach_op(...) for(int *op = (int[]){__VA_ARGS__, 0}; *op; op++)

void
box_service(struct iproto_service *s)
{
	foreach_op(NOP, SELECT, SELECT_LIMIT)
		service_register_iproto(s, *op, box_select_cb, IPROTO_NONBLOCK);
	foreach_op(INSERT, UPDATE_FIELDS, DELETE, DELETE_1_3)
		service_register_iproto(s, *op, box_cb, IPROTO_ON_MASTER);
	foreach_op(CREATE_OBJECT_SPACE, CREATE_INDEX, DROP_OBJECT_SPACE, DROP_INDEX, TRUNCATE)
		service_register_iproto(s, *op, box_meta_cb, IPROTO_ON_MASTER);
#if CFG_lua_path
	service_register_iproto(s, EXEC_LUA, box_lua_cb, 0);
#endif
#if CFG_ocaml_path
	service_register_iproto(s, EXEC_OCAML, box_ocaml_cb, 0);
#endif
}

static void
box_roerr(struct netmsg_head *h __attribute__((unused)),
	  struct iproto *request __attribute__((unused)))
{
	iproto_raise(ERR_CODE_NONMASTER, "updates are forbidden");
}

void
box_service_ro(struct iproto_service *s)
{
	service_register_iproto(s, SELECT, box_select_cb, IPROTO_NONBLOCK);
	service_register_iproto(s, SELECT_LIMIT, box_select_cb, IPROTO_NONBLOCK);

	foreach_op(INSERT, UPDATE_FIELDS, DELETE, DELETE_1_3, PAXOS_LEADER,
		   CREATE_OBJECT_SPACE, CREATE_INDEX, DROP_OBJECT_SPACE, DROP_INDEX, TRUNCATE)
		service_register_iproto(s, *op, box_roerr, IPROTO_NONBLOCK);

#if CFG_lua_path
	/* allow select only lua procedures
	   updates are blocked by luaT_box_dispatch() */
	service_register_iproto(s, EXEC_LUA, box_lua_cb, 0);
#endif
}

void __attribute__((constructor))
box_op_init(void)
{
	stat_base = stat_register(box_ops, nelem(box_ops));
}

register_source();
