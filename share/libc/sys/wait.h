/**************************************************************************/
/*                                                                        */
/*  This file is part of TrustInSoft Kernel.                              */
/*                                                                        */
/*  TrustInSoft Kernel is a fork of Frama-C. All the differences are:     */
/*    Copyright (C) 2016-2017 TrustInSoft                                 */
/*                                                                        */
/*  TrustInSoft Kernel is released under GPLv2                            */
/*                                                                        */
/**************************************************************************/

/**************************************************************************/
/*                                                                        */
/*  This file is part of Frama-C.                                         */
/*                                                                        */
/*  Copyright (C) 2007-2015                                               */
/*    CEA (Commissariat à l'énergie atomique et aux énergies              */
/*         alternatives)                                                  */
/*                                                                        */
/*  you can redistribute it and/or modify it under the terms of the GNU   */
/*  Lesser General Public License as published by the Free Software       */
/*  Foundation, version 2.1.                                              */
/*                                                                        */
/*  It is distributed in the hope that it will be useful,                 */
/*  but WITHOUT ANY WARRANTY; without even the implied warranty of        */
/*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         */
/*  GNU Lesser General Public License for more details.                   */
/*                                                                        */
/*  See the GNU Lesser General Public License version 2.1                 */
/*  for more details (enclosed in the file licenses/LGPLv2.1).            */
/*                                                                        */
/**************************************************************************/

#ifndef __FC_WAIT_H__
#define __FC_WAIT_H__

#define WNOHANG 0
#define WUNTRACED 1
#define WEXITED 2
#define WSTOPPED 3
#define WCONTINUED 4
#define WNOWAIT 5

#include "../features.h"
#include "../__fc_define_pid_t.h"
#include "../__fc_define_uid_and_gid.h"
#include "../signal.h"
#include "resource.h"

__BEGIN_DECLS

typedef enum __FC_IDTYPE_T { P_ALL, P_PID, P_PGID } idtype_t;

pid_t wait(int *stat_loc);
pid_t  wait3(int *, int, struct rusage *);
int waitid(idtype_t idt, id_t id, siginfo_t * sig, int options);
pid_t waitpid(pid_t pid, int *stat_loc, int options);

#ifdef _POSIX_SOURCE
#define	_W_INT(i)	(i)
#else
#define	_W_INT(w)	(*(int *)&(w))	/* convert union wait to int */
#define	WCOREFLAG	0200
#endif
#define	_WSTATUS(x)	(_W_INT(x) & 0177)
#define	_WSTOPPED	0177
#define WIFSTOPPED(x)	(_WSTATUS(x) == _WSTOPPED)
#define WSTOPSIG(x)	(_W_INT(x) >> 8)
#define WIFSIGNALED(x)	(_WSTATUS(x) != _WSTOPPED && _WSTATUS(x) != 0)
#define WTERMSIG(x)	(_WSTATUS(x))
#define WIFEXITED(x)	(_WSTATUS(x) == 0)
#define WEXITSTATUS(x)	(_W_INT(x) >> 8)
#ifndef _POSIX_SOURCE
#define WCOREDUMP(x)	(_W_INT(x) & WCOREFLAG)
#define	W_EXITCODE(ret, sig)	((ret) << 8 | (sig))
#define	W_STOPCODE(sig)		((sig) << 8 | _WSTOPPED)
#endif

__END_DECLS

#endif
