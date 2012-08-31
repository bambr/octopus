/*
 * Copyright (C) 2010, 2011 Mail.RU
 * Copyright (C) 2010, 2011 Yuriy Vostrikov
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
#import <tbuf.h>

#include <stddef.h>
#include <stdbool.h>

#include <third_party/queue.h>

TAILQ_HEAD(slab_tailq_head, slab);
struct arena;
struct slab_cache {
	size_t item_size;
	struct slab_tailq_head slabs, partial_populated_slabs;
	struct arena *arena;
	const char *name;
	SLIST_ENTRY(slab_cache) link;
};

enum arena_type {
	SLAB_FIXED,
	SLAB_GROW
};

void salloc_init(size_t size, size_t minimal, double factor);
void salloc_destroy(void);
void slab_cache_init(struct slab_cache *cache, size_t item_size, enum arena_type type, const char *name);
void *slab_cache_alloc(struct slab_cache *cache);
void slab_cache_free(struct slab_cache *cache, void *ptr);
void *salloc(size_t size);
void sfree(void *ptr);
void slab_validate();
void slab_stat(struct tbuf *buf);
void slab_stat2(u64 *bytes_used, u64 *items);
