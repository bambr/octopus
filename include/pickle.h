/*
 * Copyright (C) 2010, 2011, 2012, 2013 Mail.RU
 * Copyright (C) 2010, 2011, 2012, 2013 Yuriy Vostrikov
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

#ifndef PICKLE_H
#define PICKLE_H

#include <util.h>
#include <string.h>
#include <tbuf.h>

struct tbuf;

__attribute__((noreturn)) void tbuf_too_short();
static __attribute__((always_inline)) inline void
_read_must_have(struct tbuf *b, i32 n)
{
	if (unlikely(tbuf_len(b) < n)) {
		tbuf_too_short();
	}
}

void read_must_have(struct tbuf *b, i32 len);
void read_must_end(struct tbuf *b, const char *err);

#define read_u(bits)							\
	static inline u##bits read_u##bits(struct tbuf *b)		\
	{								\
		_read_must_have(b, bits/8);				\
		u##bits r = *(u##bits *)b->ptr;				\
		b->ptr += bits/8;					\
		return r;						\
	}

#define read_i(bits)							\
	static inline i##bits read_i##bits(struct tbuf *b)		\
	{								\
		_read_must_have(b, bits/8);				\
		i##bits r = *(i##bits *)b->ptr;				\
		b->ptr += bits/8;					\
		return r;						\
	}

read_u(8)
read_u(16)
read_u(32)
read_u(64)
read_i(8)
read_i(16)
read_i(32)
read_i(64)

u32 read_varint32(struct tbuf *buf);
void *read_field(struct tbuf *buf);
void *read_bytes(struct tbuf *buf, u32 data_len);
void *read_ptr(struct tbuf *buf);
void read_to(struct tbuf *buf, void *p, u32 len);
static inline void _read_to(struct tbuf *buf, void *p, u32 len) {
	memcpy(p, read_bytes(buf, len), len);
}
#define read_into(buf, struct) _read_to((buf), (struct), sizeof(*(struct)))

u8 read_field_u8(struct tbuf *b);
u16 read_field_u16(struct tbuf *b);
u32 read_field_u32(struct tbuf *b);
u64 read_field_u64(struct tbuf *b);
i8 read_field_i8(struct tbuf *b);
i16 read_field_i16(struct tbuf *b);
i32 read_field_i32(struct tbuf *b);
i64 read_field_i64(struct tbuf *b);
struct tbuf* read_field_s(struct tbuf *b);

void write_i8(struct tbuf *b, i8 i);
void write_i16(struct tbuf *b, i16 i);
void write_i32(struct tbuf *b, i32 i);
void write_i64(struct tbuf *b, i64 i);

void write_varint32(struct tbuf *b, u32 value);
void write_field_i8(struct tbuf *b, i8 i);
void write_field_i16(struct tbuf *b, i16 i);
void write_field_i32(struct tbuf *b, i32 i);
void write_field_i64(struct tbuf *b, i64 i);
void write_field_s(struct tbuf *b, const u8* s, u32 l);

u32 pick_u32(void *data, void **rest);

size_t varint32_sizeof(u32);
u8 *save_varint32(u8 *target, u32 value);
u32 _load_varint32(void **data);
static inline u32 load_varint32(void **data)
{
	const u8* p = (const u8*)*data;
	if ((*p & 0x80) == 0) {
		(*data)++;
		return *p;
	} else {
		return _load_varint32(data);
	}
}

/**
 * @brief Декодирование целого числа не большего чем 2048383
 *
 * Для того, чтобы исключить конфликт по именам переменных все внутренние
 * переменные этого макроопределения дополнены префиксом LOAD_VARINT32_
 */
#define LOAD_VARINT32(_p) ({                                                        \
	const unsigned char* LOAD_VARINT32_p = (_p);                                    \
	int LOAD_VARINT32_v = *LOAD_VARINT32_p & 0x7f;                                  \
	if (*LOAD_VARINT32_p & 0x80)                                                    \
	{                                                                               \
		LOAD_VARINT32_v = (LOAD_VARINT32_v << 7) | (*++LOAD_VARINT32_p & 0x7f);     \
		if (*LOAD_VARINT32_p & 0x80)                                                \
			LOAD_VARINT32_v = (LOAD_VARINT32_v << 7) | (*++LOAD_VARINT32_p & 0x7f); \
	}                                                                               \
	_p = (__typeof__(_p))(LOAD_VARINT32_p + 1);                                     \
	LOAD_VARINT32_v;                                                                \
})

/**
 * @brief Tag/Len/Value структура для описания произвольных данных, упакованных в единый блок
 */
struct tlv
{
	/**
	 * @brief Тэг, определяющий тип упакованных данных
	 */
	u16 tag;

	/**
	 * @brief Размер блока данных
	 */
	u32 len;

	/**
	 * @brief Начало блока данных
	 */
	u8 val[0];
} __attribute((packed));

/**
 * @brief Добавить в буфер заголовок tlv-структуры с заданным тэгом
 *
 * Возвращается смещение в байтах в буфере, с которого начинается данный
 * заголовок. Возвращаем смещение а не указатель, так как в процессе
 * добавления данных в буфер память может перераспределяться и указатель
 * может стать невалидным
 */
static inline int
tlv_add (struct tbuf* _buf, u16 _tag)
{
	//
	// Заголовок tlv-структуры с заданным тэгом
	//
	struct tlv header = {.tag = _tag};

	//
	// Вычисляем смещение по текущему заполнению буфера
	//
	int off = (u8*)_buf->end - (u8*)_buf->ptr;

	//
	// Добавляем в буфер заголовок
	//
	tbuf_append (_buf, &header, sizeof (header));

	//
	// Возвращаем смещение
	//
	return off;
}

/**
 * @brief Зафиксировать tlv-структуру в буфере
 *
 * В данной функции вычисляется реальный размер данных tlv-структуры и
 * эта длина запоминается в соответствующем заголовке (идентифицируемом
 * по его смещению в буфере)
 */
static inline void
tlv_end (struct tbuf* _buf, int _off)
{
	//
	// Указатель на заголовок
	//
	struct tlv* header = (struct tlv*)((u8*)_buf->ptr + _off);

	//
	// Размер данных tlv-структуры равен текущему размеру буфера минус
	// смещение заголовка tlv-структуры и минус размер этого заголовка
	//
	header->len = (u8*)_buf->end - (u8*)_buf->ptr - _off - sizeof (*header);
}

#endif
