# SPDX-License-Identifier: GPL-2.0-or-later
# busy.py sample.txt [thread-substring...]: per thread, samples in leaf frames that wait vs run.
import sys,re,collections
txt=open(sys.argv[1]).read()
sec=txt.split('Call graph:')[1].split('Total number in stack')[0]
blocks=re.split(r'\n(?=    \d+ Thread_)',sec)
waitpat=re.compile(r'mach_msg|psynch_cvwait|semwait|__ulock_wait|kevent|__select|nanosleep|__semwait_signal|__workq_kernreturn|swtch_pri|__psynch_mutexwait|thread_switch|sched_yield|__wait4|poll|read\b|__sigsuspend|pthread_yield|_dispatch_semaphore_wait|syscall_thread_switch|thread_suspend')
for b in blocks:
    lines=b.split('\n'); head=lines[0].strip()
    if len(sys.argv)>2 and not any(s in head for s in sys.argv[2:]): continue
    ents=[]
    for l in lines[1:]:
        m=re.match(r'^([ +!:|]*?)(\d+) (.*)$',l)
        if m: ents.append((len(m.group(1)),int(m.group(2)),m.group(3)))
    busy=wait=0; leaves=collections.Counter()
    for i,(d,c,n) in enumerate(ents):
        nd=ents[i+1][0] if i+1<len(ents) else -1
        if nd<=d:
            if waitpat.search(n): wait+=c
            else: busy+=c; leaves[re.sub(r'\s+\(in .*','',n)[:80]]+=c
    print(f"{busy:5d} run {wait:5d} wait  {head[:90]}")
    if len(sys.argv)>2:
        for k,v in leaves.most_common(6): print('       ',v,k)
