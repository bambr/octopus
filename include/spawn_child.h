/*
 * Copyright (C) 2015 Mail.RU
 * Copyright (C) 2015 Yuriy Vostrikov
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
#ifndef __SPAWN_CHILD_H
#define __SPAWN_CHILD_H

struct child
{
	pid_t pid;

	int fd;
};

/**
 * @brief Передать файловый дескриптор @a _fd другому процессу для обработки
 *
 * @a _io если задан, то он используется для контроля валидности файлового
 * дескриптора перед передачей другому процессу, поскольку в процессе ожидания
 * захвата лока он может быть закрыт и в этом случае передавать будет нечего.
 */
struct child spawn_child (const char* _name, int (*_h) (int, int, void*, int), struct netmsg_io* _io, int _fd, void* _state, int _len);

ssize_t sendfd (int sock, int fd_to_send, struct iovec* iov, int iovlen);
ssize_t recvfd (int sock, int* fd, struct iovec* iov, int iovlen);

#endif /* __SPAWN_CHILD_H */
