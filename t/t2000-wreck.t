#!/bin/sh
#

test_description='Test basic wreck functionality

Test basic functionality of wreckrun facility.
'

. `dirname $0`/sharness.sh
SIZE=${FLUX_TEST_SIZE:-4}
test_under_flux ${SIZE} wreck

#  Return the previous jobid
last_job_id() {
	flux wreck last-jobid
}
#  Return previous job path in kvs
last_job_path() {
	flux wreck last-jobid -p
}

test_expect_success 'wreckrun: works' '
	hostname=$(hostname) &&
	run_timeout 5 flux wreckrun -n${SIZE} hostname  >output &&
	for i in $(seq 1 ${SIZE}); do echo $hostname; done >expected &&
	test_cmp expected output
'
test_expect_success 'wreckrun: -T, --walltime works' '
	test_expect_code 142 flux wreckrun --walltime=1s -n${SIZE} sleep 15
'
test_expect_success 'wreckrun: -T, --walltime allows override of default signal' '
        flux kvs put --json lwj.walltime-signal=SIGTERM &&
        test_when_finished flux kvs put --json lwj.walltime-signal= &&
	test_expect_code 143 flux wreckrun -T 1s -n${SIZE} sleep 5
'
test_expect_success 'wreckrun: -T, --walltime allows per-job override of default signal' '
	test_expect_code 130 flux wreckrun -P "lwj[\"walltime-signal\"]=\"SIGINT\"" -T 1s -n${SIZE} sleep 15
'
test_expect_success 'wreckrun: propagates current working directory' '
	mkdir -p testdir &&
	mypwd=$(pwd)/testdir &&
	( cd testdir &&
	run_timeout 5 flux wreckrun -N1 -n1 pwd ) | grep "^$mypwd$"
'
test_expect_success 'wreckrun: propagates current environment' '
	( export MY_UNLIKELY_ENV=0xdeadbeef &&
	  run_timeout 5 flux wreckrun -N1 -n1 env ) | \
           grep "MY_UNLIKELY_ENV=0xdeadbeef"
'
test_expect_success 'wreckrun: does not propagate FLUX_URI' '
	run_timeout 5 flux wreckrun -n${SIZE} printenv FLUX_URI >uri_output &&
	test `sort uri_output | uniq | wc -l` -eq ${SIZE}
'
test_expect_success 'wreckrun: does not drop output' '
	for i in `seq 0 100`; do 
		base64 /dev/urandom | head -c77
	done >expected &&
	run_timeout 5 flux wreckrun -N1 -n1 cat expected >output &&
	test_cmp expected output
'
test_expect_success 'wreckrun: handles stdin' '
	cat >expected.stdin <<-EOF &&
	This is a test.

	EOF
	cat expected.stdin | flux wreckrun -T5s cat > output.stdin &&
        test_cmp expected.stdin output.stdin
'
test_expect_success 'wreckrun: handles empty stdin' '
	flux wreckrun -T5s cat > output.devnull </dev/null &&
        test_must_fail test -s output.devnull
'
test_expect_success 'wreckrun: bcast stdin to all tasks by default' '
        flux wreckrun -n${SIZE} echo hello > expected.bcast &&
        echo hello | flux wreckrun -n${SIZE} cat > output.bcast &&
        test_cmp expected.bcast output.bcast
'
test_expect_success 'wreckrun: --input=0 works' '
        echo hello | flux wreckrun --input=0 -l -n${SIZE} cat > output.0 &&
        cat >expected.0 <<-EOF &&
	0: hello
	EOF
        test_cmp expected.0 output.0
'
test_expect_success 'wreckrun: --input=1 works' '
        echo hello | flux wreckrun --input=1 -l -n${SIZE} cat > output.1 &&
        cat >expected.1 <<-EOF &&
	1: hello
	EOF
        test_cmp expected.1 output.1
'
test_expect_success 'wreckrun: --input=0-2 works' '
        echo hello | flux wreckrun --input=0-2 -l -n${SIZE} cat |
		sort -n > output.0-2 &&
        cat >expected.0-2 <<-EOF &&
	0: hello
	1: hello
	2: hello
	EOF
        test_cmp expected.0-2 output.0-2
'

test_expect_success 'wreckrun: --input different for each task works' '
        for i in `seq 0 3`; do echo "hi $i" > i.$i; done &&
        flux wreckrun --input="i.0:0;i.1:1;i.2:2;i.3:3" -l -n4 cat |
		sort -n > output.multi &&
        cat >expected.multi <<-EOF &&
	0: hi 0
	1: hi 1
	2: hi 2
	3: hi 3
	EOF
        test_cmp expected.multi output.multi
'
test_expect_success 'wreckrun: --input=/dev/null:* works' '
        echo hello | flux wreckrun --input=/dev/null:* -l -n${SIZE} cat > output.devnull2 &&
	test_must_fail test -s output.devnull2
'
test_expect_success 'wreckrun: bad input file causes failure' '
	test_must_fail \
	    flux wreckrun --input=/foo/badfile:* -l -n${SIZE} cat \
	        >output.badinput 2>error.badinput &&
	test_must_fail test -s output.badinput &&
	grep "Error: input: /foo/badfile" error.badinput
'

test_expect_success 'wreck: job state events emitted' '
	run_timeout 5 \
	  $SHARNESS_TEST_SRCDIR/scripts/event-trace.lua \
	   wreck.state wreck.state.complete \
	   flux wreckrun -n${SIZE} /bin/true > output &&
        tail -5 output > output_states && # only care about last 4
	cat >expected_states <<-EOF &&
	wreck.state.reserved
	wreck.state.starting
	wreck.state.running
	wreck.state.completing
	wreck.state.complete
	EOF
	test_cmp expected_states output_states
'
test_expect_success NO_CHAIN_LINT 'wreck: signaling wreckrun works' '
        flux wreckrun -n${SIZE} sleep 15 </dev/null &
	q=$! &&
	$SHARNESS_TEST_SRCDIR/scripts/event-trace.lua \
           wreck.state wreck.state.running /bin/true &&
        sleep 0.5 &&
	kill -INT $q &&
	test_expect_code 137 wait $q
'
test_expect_success 'wreckrun: oversubscription of tasks' '
	run_timeout 15 flux wreckrun -v -n$(($(nproc)*${SIZE}+1)) /bin/true
'
test_expect_success 'wreckrun: uneven distribution with -n, -N' '
	run_timeout 10 flux wreckrun -N${SIZE} -n$((${SIZE}+1)) /bin/true
'
test_expect_success 'wreckrun: too many nodes requested fails' '
	test_expect_code 1 run_timeout 10 flux wreckrun -N$((${SIZE}+1)) hostname
'
test_expect_success 'wreckrun: no nnodes or ntasks args runs one task on rank 0' '
	test "$(flux wreckrun -l hostname)" = "0: $hostname"
'
test_expect_success 'wreckrun: -n1 runs one task on rank 0' '
	test "$(flux wreckrun -l hostname)" = "0: $hostname"
'
test_expect_success 'wreckrun: -n divides tasks among ranks' '
	flux wreckrun -l -n$((${SIZE}*2)) printenv FLUX_NODE_ID | sort >output_nx2 &&
        i=0 &&
	for n in $(seq 0 $((${SIZE}-1))); do
		echo "$i: $n"; echo "$((i+1)): $n";
		i=$((i+2));
	done >expected_nx2 &&
	test_cmp expected_nx2 output_nx2
'
test_expect_success 'wreckrun: -N without -n works' '
	flux wreckrun -l -N${SIZE} printenv FLUX_NODE_ID | sort >output_N &&
	for n in $(seq 0 $((${SIZE}-1))); do
		echo "$n: $n";
		i=$((i+2));
	done >expected_N &&
	test_cmp expected_N output_N
'
test_expect_success 'wreckrun: -N without -n sets ntasks in kvs' '
	flux wreckrun -l -N${SIZE} /bin/true &&
	LWJ=$(last_job_path) &&
	n=$(flux kvs get --json ${LWJ}.ntasks) &&
	test "$n" = "${SIZE}"
'
test_expect_success 'wreckrun: -n without -N sets nnnodes in kvs' '
	flux wreckrun -l -n${SIZE} /bin/true &&
	LWJ=$(last_job_path) &&
	n=$(flux kvs get --json ${LWJ}.nnodes) &&
	test "$n" = "${SIZE}"
'
test_expect_success 'wreckrun: -t1 -N${SIZE} sets ntasks in kvs' '
	flux wreckrun -l -t1 -N${SIZE} /bin/true &&
	LWJ=$(last_job_path) &&
	n=$(flux kvs get --json ${LWJ}.ntasks) &&
	test "$n" = "${SIZE}"
'
test_expect_success 'wreckrun: -t1 -n${SIZE} sets nnodes in kvs' '
	flux wreckrun -l -t1 -n${SIZE} /bin/true &&
	LWJ=$(last_job_path) &&
	n=$(flux kvs get --json ${LWJ}.nnodes) &&
	test "$n" = "${SIZE}"
'
test_expect_success 'wreckrun: -t2 -N${SIZE} sets correct ntasks in kvs' '
	flux wreckrun -l -t2 -N${SIZE} /bin/true &&
	LWJ=$(last_job_path) &&
	n=$(flux kvs get --json ${LWJ}.ntasks) &&
	test "$n" = $((${SIZE}*2))
'

test_expect_success 'wreckrun: ngpus is 0 by default' '
    flux wreckrun -n 2 /bin/true &&
    LWJ=$(last_job_path) &&
    n=$(flux kvs get --json ${LWJ}.ngpus) &&
    test "$n" = "0"
'

test_expect_success 'wreckrun: -g, --ngpus sets ngpus in kvs' '
    flux wreckrun -n 2 -g 4 /bin/true &&
    LWJ=$(last_job_path) &&
    n=$(flux kvs get --json ${LWJ}.ngpus) &&
    test "$n" = "8"
'
test_expect_success 'wreckrun: job with more nodes than tasks fails' '
	test_must_fail flux wreckrun -n2 \
	    -P "t={}; for i=1,3 do t[i]={rank=i-1,children={core=\"0\"}} end; lwj.R_lite = t" \
	    hostname &&
	LWJ=$(last_job_path) &&
	test "$(flux kvs get --json ${LWJ}.state)" = "failed"
'
cpus_allowed=${SHARNESS_TEST_SRCDIR}/scripts/cpus-allowed.lua
if test $($cpus_allowed count) -gt 1; then
    test_set_prereq MULTICORE
    # Note: Normalize format of cpu0 thread siblings using cpus-allowed script
    #  so that comparison of output works in MULTICORE tests below
    cpu0_thread_siblings=$(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list)
    cpu0_thread_siblings=$($cpus_allowed intersect ${cpu0_thread_siblings})
fi
test_expect_success MULTICORE 'wreckrun: cpu-affinity job option works' '
	flux wreckrun -o cpu-affinity -n1 $cpus_allowed > cpu-affinity.out &&
	cat <<-EOF >cpu-affinity.expected &&
	${cpu0_thread_siblings}
	EOF
	test_cmp cpu-affinity.expected cpu-affinity.out
'
test_expect_success MULTICORE 'wreckrun: cpu-affinity=per-task job option works' '
	flux wreckrun -o cpu-affinity=per-task -N1 -n2 $cpus_allowed | \
		sort -k1,1n > cpu-affinity-task.out &&
	test_debug "cat cpu-affinity-task.out" &&
	test $(head -1 cpu-affinity-task.out) != $(tail -1 cpu-affinity-task.out)
'
test_expect_success MULTICORE 'wreckrun: global cpu-affinity job option works' '
	flux wreck setopt cpu-affinity &&
	test_when_finished "flux wreck setopt cpu-affinity=false" &&
	flux wreckrun -n1 $cpus_allowed > global-affinity.out &&
	cat <<-EOF >global-affinity.expected &&
	${cpu0_thread_siblings}
	EOF
	test_cmp global-affinity.expected global-affinity.out
'
test_expect_success MULTICORE 'wreckrun: local cpu-affinity option overrides global' '
	flux wreck setopt cpu-affinity &&
	test_when_finished "flux wreck setopt cpu-affinity=false" &&
	flux wreckrun -n1 -o cpu-affinity=0 $cpus_allowed > no-affinity.out &&
	cat <<-EOF >no-affinity.expected &&
	$($cpus_allowed)
	EOF
	test_cmp no-affinity.expected no-affinity.out
'

test_expect_success 'wreckrun: CUDA_VISIBLE_DEVICES is set for gpus' '
	output=$(flux wreckrun -n1 -g 1 printenv CUDA_VISIBLE_DEVICES) &&
	test_debug "echo CUDA_VISIBLE_DEVICES = $output" &&
	test "$output" = "0" &&
	output=$(flux wreckrun -n1 -g 2 printenv CUDA_VISIBLE_DEVICES) &&
	test_debug "echo CUDA_VISIBLE_DEVICES = $output" &&
	test "$output" = "0,1"
'
test_expect_success 'wreckrun: CUDA_VISIBLE_DEVICES not set with gpubind=off' '
	output=$(flux wreckrun -n1 -g1 -o gpubind=off printenv CUDA_VISIBLE_DEVICES ||:) &&
	test_debug "echo CUDA_VISIBLE_DEVICES=$output" &&
	test "$output" = ""
'
test_expect_success 'wreckrun: -o gpubind=per-task works' '
	flux wreckrun -l -n2 -N1 -g2 printenv CUDA_VISIBLE_DEVICES |sort >cuda_visible.out1 &&
	cat <<-EOF >cuda_visible.expected1 &&
	0: 0,1,2,3
	1: 0,1,2,3
	EOF
	test_cmp cuda_visible.expected1 cuda_visible.out1 &&
	flux wreckrun -l -n2 -N1 -g2 -o gpubind=per-task \
		printenv CUDA_VISIBLE_DEVICES |sort >cuda_visible.out2 &&
	cat <<-EOF >cuda_visible.expected2 &&
	0: 0,1
	1: 2,3
	EOF
	test_cmp cuda_visible.expected2 cuda_visible.out2
'
test_expect_success 'wreckrun: top level environment' '
	flux kvs put --json lwj.environ="{ \"TEST_ENV_VAR\": \"foo\" }" &&
	run_timeout 5 flux wreckrun -n2 printenv TEST_ENV_VAR > output_top_env &&
	cat <<-EOF >expected_top_env &&
	foo
	foo
	EOF
	test_cmp expected_top_env output_top_env &&
	TEST_ENV_VAR=bar \
	  flux wreckrun -n2 printenv TEST_ENV_VAR > output_top_env2 &&
	cat <<-EOF >expected_top_env2 &&
	bar
	bar
	EOF
	test_cmp expected_top_env2 output_top_env2
'
test_expect_success 'wreck plugins can use wreck:log_msg()' '
	saved_pattern=$(flux getattr wrexec.lua_pattern) &&
	if test $? = 0; then
	  test_when_finished \
	    "flux setattr wrexec.lua_pattern \"$saved_pattern\""
	else
	  test_when_finished \
	     "flux setattr --expunge wrexec.lua_pattern"
	fi &&
	cat <<-EOF >test.lua &&
	function rexecd_init ()
	    local rc, err = wreck:log_msg ("lwj.%d: plugin test successful", wreck.id)
	    --if not rc then error (err) end
	end
	EOF
	flux setattr wrexec.lua_pattern "$(pwd)/*.lua" &&
	flux wreckrun /bin/true &&
	(flux dmesg | grep "plugin test successful" || (flux dmesg | grep lwj\.$(last_job_id) && false))
'
test_expect_success 'wreckrun: --detach supported' '
	flux wreckrun --detach /bin/true | grep "^[0-9]"
'
test_expect_success 'wreckrun: --wait-until supported' '
	flux wreckrun -v --wait-until=complete /bin/true >wuntil.out 2>wuntil.err &&
	tail -1 wuntil.err | grep "complete"
'

WAITFILE="$SHARNESS_TEST_SRCDIR/scripts/waitfile.lua"

test_expect_success 'wreckrun: --output supported' '
	flux wreckrun --output=test1.out echo hello &&
        $WAITFILE --timeout=1 --pattern=hello test1.out
'
test_expect_success 'wreckrun: --error supported' '
	flux wreckrun --output=test2.out --error=test2.err \
	    sh -c "echo >&2 this is stderr; echo this is stdout" &&
        $WAITFILE -v --timeout=1 -p "this is stderr" test2.err &&
        $WAITFILE -v --timeout=1 -p "this is stdout" test2.out
'
test_expect_success 'wreckrun: kvs config output for all jobs' '
	test_when_finished "flux kvs put --json lwj.output=" &&
	flux kvs put --json lwj.output.labelio=true &&
	flux kvs put --json lwj.output.files.stdout=test3.out &&
	flux wreckrun -n${SIZE} echo foo &&
	for i in $(seq 0 $((${SIZE}-1)))
		do echo "$i: foo"
	done >expected.kvsiocfg &&
        $WAITFILE --count=${SIZE} -t 1 -p ".+" test3.out &&
	sort -n test3.out >output.kvsiocfg &&
	test_cmp expected.kvsiocfg output.kvsiocfg
'
test_expect_success 'flux-wreck: exists in path' '
	flux wreck help 2>&1 | grep "^Usage: flux-wreck"
'
test_expect_success 'flux-wreck: attach' '
	flux wreckrun -n4 --output=expected.attach hostname >/dev/null &&
	flux wreck attach $(last_job_id) > output.attach &&
        test_cmp expected.attach output.attach
'
test_expect_success 'flux-wreck: attach with stdin' '
	jobid=$(flux wreckrun -n4 --detach cat) &&
	echo foo | flux wreck attach $jobid > output.attach_in &&
	cat >expected.attach_in <<-EOF &&
	foo
	foo
	foo
	foo
	EOF
	test_cmp output.attach_in expected.attach_in
'
test_expect_success 'flux-wreck: attach --label-io' '
	flux wreckrun -l -n4 --output=expected.attach-l echo bazz >/dev/null &&
	flux wreck attach --label-io $(last_job_id) |sort > output.attach-l &&
        sort expected.attach-l > x && mv x expected.attach-l &&
        test_cmp expected.attach-l output.attach-l
'
test_expect_success 'wreck: attach --no-follow works' '
	flux wreckrun -d -l -n4 sh -c "echo before; sleep 30; echo after" &&
	test_when_finished flux wreck kill $(last_job_id) &&
	cat >expected.attach-n <<-EOF &&
	before
	before
	before
	before
	EOF
	i=0 &&
	while test $i -lt 3; do
		run_timeout 5 \
		flux wreck attach --no-follow $(last_job_id) >output.attach-n
		test_cmp expected.attach-n output.attach-n
		rc=$?
		if test $rc = 0; then break; fi
                # retry
		i=$((i+1))
		sleep 0.1
	done &&
	test $rc -eq 0
'
test_expect_success 'wreck: dumplog works' '
	test_must_fail flux wreckrun --input=bad.file hostname &&
	flux wreck dumplog $(last_job_id) 2>&1 | grep "^rank0: .*bad.file"
'
test_expect_success 'flux-wreck: status' '
        flux wreckrun -n4 /bin/true &&
        id=$(last_job_id) &&
	flux wreck status $id > output.status &&
        cat >expected.status <<-EOF &&
	Job $id status: complete
	task[0-3]: exited with exit code 0
	EOF
	test_cmp expected.status output.status
'
test_expect_success 'flux-wreck: status with non-zero exit' '
	test_expect_code 1 flux wreckrun -n4 /bin/false &&
        id=$(last_job_id) &&
	test_expect_code 1 flux wreck status $id > output.status2 &&
        cat >expected.status2 <<-EOF &&
	Job $id status: complete
	task[0-3]: exited with exit code 1
	EOF
	test_cmp expected.status2 output.status2

'
test_expect_success 'flux-wreck: kill' '
	run_timeout 1 flux wreckrun --detach sleep 100 &&
	id=$(last_job_id) &&
	LWJ=$(last_job_path) &&
	${SHARNESS_TEST_SRCDIR}/scripts/kvs-watch-until.lua -vt 1 $LWJ.state "v == \"running\"" &&
	flux wreck kill -s SIGINT $id &&
	${SHARNESS_TEST_SRCDIR}/scripts/kvs-watch-until.lua -vt 1 $LWJ.state "v == \"complete\"" &&
	test_expect_code 130 flux wreck status $id >output.kill &&
	cat >expected.kill <<-EOF &&
	Job $id status: complete
	task0: exited with signal 2
	EOF
	test_cmp expected.kill output.kill
'
test_expect_success 'flux-wreck: ls works' '
	flux wreckrun -n2 -N2 hostname &&
	flux wreck ls | sort -n >ls.out &&
	tail -1 ls.out | grep "hostname$"
'
test_expect_success 'flux-wreck: --name option works' '
	flux wreckrun -n2 -N2 --name=testname hostname &&
	flux wreck ls | sort -n >ls-name.out &&
	tail -q ls-name.out | grep "testname$"
'
test_expect_success 'flux-wreck: ls -n, --max works' '
        test $(flux wreck ls --max=1 | wc -l) = 2
'
test_expect_success 'flux-wreck: ls JOBID works' '
        LASTID=$(last_job_id) &&
	flux wreck ls $LASTID > ls-jobid.out &&
        tail -1 ls-jobid.out | grep "^ *$LASTID"
'
test_expect_success 'flux-wreck: ls RANGE ignores missing jobids' '
	LASTID=$(last_job_id) &&
	LWJ=$(last_job_path) &&
	flux wreckrun hostname &&
	flux kvs move $LWJ tmp &&
	flux wreck ls $((${LASTID}-1))-$((${LASTID}+1)) > ls-range.out &&
	flux kvs move tmp $LWJ &&
	test $(cat ls-range.out | wc -l) = 3
'
test_expect_success 'flux-wreck: ls lists most recent "active" job first' '
	flux wreckrun -d sleep 100 &&
	KILL=$(last_job_id) &&
	flux wreckrun -d sleep 100 &&
	LASTID=$(last_job_id) &&
	flux wreckrun hostname && flux wreckrun hostname &&
	flux wreck ls --max=1 > ls-active.out &&
	flux wreck kill $KILL &&
	flux wreck kill $LASTID &&
	test_debug "echo expecting $LASTID" &&
	test_debug "cat ls-active.out" &&
	test $(cat ls-active.out | wc -l) = 2 &&
	tail -1 ls-active.out | grep ^\ *$LASTID
'
test_expect_success 'flux-wreck: purge works' '
	flux wreck purge &&
	flux wreck purge -t 2 -R &&
	flux wreck ls &&
	COUNT=$(flux wreck ls | grep -v NTASKS | wc -l) &&
	test "$COUNT" = 2
'
test_expect_success 'flux-wreck: purge excludes active jobs' '
	flux wreckrun -d sleep 100 &&
	flux wreck purge -v -t 0 -R &&
	flux wreck kill $(last_job_id) &&
	flux wreck ls &&
	COUNT=$(flux wreck ls | grep -v NTASKS | wc -l) &&
	test "$COUNT" = 1
'

flux module list | grep -q sched || test_set_prereq NO_SCHED
test_expect_success NO_SCHED 'flux-submit: returns ENOSYS when sched not loaded' '
	test_must_fail flux submit -n2 hostname 2>err.submit &&
	cat >expected.submit <<-EOF &&
	submit: flux.rpc: Function not implemented
	EOF
	test_cmp expected.submit err.submit
'

test_expect_success NO_SCHED 'flux-wreck cancel: fails when sched not loaded' '
	test_must_fail flux wreck cancel 1 2>err.cancel &&
	cat >expected.cancel <<-EOF &&
	flux-wreck: job cancel not supported when scheduler not loaded
	EOF
	test_cmp expected.cancel err.cancel
'
test_expect_success 'flux-wreck cancel: falls back to SIGKILL with -f' '
	run_timeout 1 flux wreckrun --detach sleep 100 &&
	id=$(last_job_id) &&
	LWJ=$(last_job_path) &&
	${SHARNESS_TEST_SRCDIR}/scripts/kvs-watch-until.lua -vt 1 $LWJ.state "v == \"running\"" &&
	flux wreck cancel -f $id &&
	${SHARNESS_TEST_SRCDIR}/scripts/kvs-watch-until.lua -vt 1 $LWJ.state "v == \"complete\"" &&
	test_expect_code 137 flux wreck status $id >output.cancel-f &&
	cat >expected.cancel-f <<-EOF &&
	Job $id status: complete
	task0: exited with signal 9
	EOF
	test_cmp expected.cancel-f output.cancel-f
'

test_expect_success NO_SCHED 'flux-wreck exclude: fails when sched not loaded' '
	test_must_fail flux wreck exclude myhost 2>err.exclude &&
	cat >expected.exclude <<-EOF &&
	flux-wreck: Node exclusion is not supported when scheduler not loaded
	EOF
	test_cmp expected.exclude err.exclude
'
test_expect_success NO_SCHED 'flux-wreck include: fails when sched not loaded' '
	test_must_fail flux wreck include myhost 2>err.include &&
	cat >expected.include <<-EOF &&
	flux-wreck: Node inclusion is not supported when scheduler not loaded
	EOF
	test_cmp expected.include err.include
'

check_complete_link() {
    for i in `seq 0 5`; do
        lastepoch=$(flux kvs dir lwj-complete | awk -F. '{print $2}' | sort -n | tail -1)
        flux kvs get --json lwj-complete.${lastepoch}.${1}.state && return 0
        sleep 0.2
    done
    return 1
}

test_expect_success 'wreck job is linked in lwj-complete after failure' '
    test_must_fail flux wreckrun --input=bad.file hostname &&
    check_complete_link $(last_job_id)
'

test_expect_success 'wreck: no KVS watchers leaked after 10 jobs' '
	flux exec -n -r 1-$(($SIZE-1)) -l \
		flux module stats --parse "namespace.primary.#watchers" kvs | sort -n >w.before &&
	for i in `seq 1 10`; do
		flux wreckrun --ntasks $SIZE /bin/true
	done &&
	flux exec -n -r 1-$(($SIZE-1)) -l \
		flux module stats --parse "namespace.primary.#watchers" kvs | sort -n >w.after &&
	test_cmp w.before w.after
'

test_expect_success 'wreck: can adjust lwj kvs hiearchy with broker attrs' '
    result=$(flux start -o,-Swreck.lwj-dir-levels=0 flux wreck kvs-path 256) &&
    test_debug "echo result is $result" &&
    test "$result" = "lwj.256" &&
    result=$(flux start -o,-Swreck.lwj-dir-levels=3,-Swreck.lwj-bits-per-dir=6 flux wreck kvs-path 256) &&
    test_debug "echo result is $result" &&
    test "$result" = "lwj.0.0.4.256" &&
    result=$(flux start -o,-Swreck.lwj-dir-levels=0 flux wreckrun echo hello) &&
    test "$result" = "hello"
'

test_debug "flux wreck ls"

test_done
