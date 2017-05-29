#!/bin/sh

#
# Copyright (c) 2014 EMC Corp.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# $FreeBSD$
#

# contigmalloc(9) / contigfree(9) test scenario.
# malloc() a random number of buffers with random size and then free them.

# A malloc pattern might look like this:
# contigmalloc(186 pages)
# contigmalloc(56 pages)
# contigmalloc(9 pages)
# contigmalloc(202 pages)
# contigmalloc(49 pages)
# contigmalloc(5 pages)

# "panic: vm_reserv_alloc_contig: reserv 0xff... isn't free" seen.
# http://people.freebsd.org/~pho/stress/log/contigmalloc.txt
# Fixed by r271351.

[ `id -u ` -ne 0 ] && echo "Must be root!" && exit 1
[ -d /usr/src/sys ] || exit 0

. ../default.cfg

odir=`pwd`
dir=/tmp/contigmalloc
rm -rf $dir; mkdir -p $dir
cat > $dir/ctest.c <<EOF
#include <sys/param.h>
#include <sys/syscall.h>

#include <err.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define min(a,b) (((a)<(b))?(a):(b))
#define CAP (64 * 1024 * 1024)		/* Total allocation */
#define MAXBUF (32 * 1024 * 1024)	/* Max buffer size */
#define N 512				/* Max allocations */
#define RUNTIME 120
#define TALLOC 1
#define TFREE  2

void *p[N];
long size[N];
int n;

void
test(int argc, char *argv[])
{
	long mw, s;
	int i, no, ps, res;

	if (argc == 3) {
		no = atoi(argv[1]);
		mw = atol(argv[2]);
	}
	if (argc != 3 || no == 0 || mw == 0)
		errx(1, "Usage: %s <syscall number> <max wired>", argv[0]);

	ps = getpagesize();
	s = 0;
	n = arc4random() % N + 1;
	mw = mw / 100 * 10 * ps;	/* Use 10% of vm.max_wired */
	mw = min(mw, CAP);
	for (i = 0; i < n; i++) {
		size[i] = round_page((arc4random() % MAXBUF) + 1);
		if (s + size[i] > mw)
			continue;
		res = syscall(no, TALLOC, &p[i], &size[i]);
		if (res == -1) {
			warn("contigmalloc(%lu pages) failed at loop %d",
			    size[i] / ps, i);
		} else {
#if defined(TEST)
			fprintf(stderr, "contigmalloc(%lu pages)\n",
			    size[i] / ps);
#endif
			s += size[i];
		}
	}

	setproctitle("%ld Mb", s / 1024 / 1024);

	for (i = 0; i < n; i++) {
		if (p[i] != NULL) {
			res = syscall(no, TFREE, &p[i], &size[i]);
#if defined(TEST)
			fprintf(stderr, "contigfree(%lu pages)\n",
			    size[i] / ps);
#endif
			p[i] = NULL;
		}
	}
}

int
main(int argc, char *argv[])
{
	time_t start;

	start = time(NULL);
	while (time(NULL) - start < RUNTIME)
		test(argc, argv);

	return (0);
}

EOF
mycc -o /tmp/ctest -Wall -Wextra -O0 -g $dir/ctest.c || exit 1
rm $dir/ctest.c

cd $dir
cat > Makefile <<EOF
KMOD= cmalloc
SRCS= cmalloc.c

.include <bsd.kmod.mk>
EOF

sed '1,/^EOF2/d' < $odir/$0 > cmalloc.c
make || exit 1
kldload $dir/cmalloc.ko || exit 1

cd $odir
mw=`sysctl -n vm.max_wired` || exit 1
/tmp/ctest `sysctl -n debug.cmalloc_offset` $mw 2>&1 | tail -5
kldunload $dir/cmalloc.ko
rm -rf $dir /tmp/ctest
exit 0

EOF2
#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/module.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/sysent.h>
#include <sys/sysproto.h>
#include <sys/systm.h>

#define TALLOC 1
#define TFREE  2

/*
 * Hook up a syscall for contigmalloc testing.
 */

struct cmalloc_args {
        int a_op;
	void *a_ptr;
	void *a_size;
};

static int
cmalloc(struct thread *td, struct cmalloc_args *uap)
{
	void *p;
	unsigned long size;
	int error;

	error = copyin(uap->a_size, &size, sizeof(size));
	if (error != 0) {
		return (error);
	}
	switch (uap->a_op) {
	case TFREE:
		error = copyin(uap->a_ptr, &p, sizeof(p));
		if (error == 0) {
			if (p != NULL)
				contigfree(p, size, M_TEMP);
		}
		return (error);

	case TALLOC:
		p = contigmalloc(size, M_TEMP, M_NOWAIT, 0ul, ~0ul, 4096, 0);
		if (p != NULL) {
			error = copyout(&p, uap->a_ptr, sizeof(p));
			return (error);
		}
		return (ENOMEM);
	}
        return (EINVAL);
}

/*
 * The sysent for the new syscall
 */
static struct sysent cmalloc_sysent = {
        3,                      /* sy_narg */
        (sy_call_t *) cmalloc	/* sy_call */
};

/*
 * The offset in sysent where the syscall is allocated.
 */
static int cmalloc_offset = NO_SYSCALL;

SYSCTL_INT(_debug, OID_AUTO, cmalloc_offset, CTLFLAG_RD, &cmalloc_offset, 0,
    "cmalloc syscall number");

/*
 * The function called at load/unload.
 */

static int
cmalloc_load(struct module *module, int cmd, void *arg)
{
        int error = 0;

        switch (cmd) {
        case MOD_LOAD :
                break;
        case MOD_UNLOAD :
                break;
        default :
                error = EOPNOTSUPP;
                break;
        }
        return (error);
}

SYSCALL_MODULE(cmalloc_syscall, &cmalloc_offset, &cmalloc_sysent,
    cmalloc_load, NULL);
