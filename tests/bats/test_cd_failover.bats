# shellcheck disable=SC2148
# shellcheck disable=SC2329


setup_file() {
  load 'helpers.sh'
  _common_setup

  local _iargs=("--set" "logVerbosity=6")
  iupgrade_wait "${TEST_CHART_REPO}" "${TEST_CHART_VERSION}" _iargs

  # `test_cd_nvb_failover.sh` has defaults for these parameters. Do not rely on
  # those, explicitly encode parameters chosen for this test suite.
  export NVB_GPUS_PER_NODE="4"
  export NVB_NUM_NODES="2"
  export NVB_NUM_RANKS="8"
  export NVB_REPS_PER_BENCHMARK="10"
  export NVB_BUFSIZE_PER_BENCHMARK_REP="512"

  export SPECPATH="nvb_rendered_for_bats.yaml"
  envsubst < tests/bats/specs/nvb.tmpl.yaml > "$SPECPATH"
}


teardown_file() {
  kubectl delete -f "$SPECPATH" --ignore-not-found
  kubectl wait --for=delete job/test-failover-job-launcher --timeout=20s || true
}


# bats test_tags=fastfeedback
@test "CDs: failover nvb: force-delete worker pod 0" {
  bash tests/bats/lib/test_cd_nvb_failover.sh "$SPECPATH" 1
}


@test "CDs: failover nvb: force-delete all IMEX daemons" {
  bash tests/bats/lib/test_cd_nvb_failover.sh "$SPECPATH" 2
}


@test "CDs: failover nvb: regular-delete worker pod 1" {
  bash tests/bats/lib/test_cd_nvb_failover.sh "$SPECPATH" 3
}


# bats test_tags=fastfeedback
@test "CD nvb many-iteration wrapper" {
  # Propose and test-cover a snippet that is meant to be used for manual,
  # long-running, many-iteration testing. Parameters used below: fault injection
  # type `4`: no failure; nvbandwidth parameters optimized for fast completion.
  export REPETITIONS="2"
  export NVB_GPUS_PER_NODE="2"
  export NVB_NUM_NODES="2"
  export NVB_NUM_RANKS="4"
  export NVB_REPS_PER_BENCHMARK="1"
  export NVB_BUFSIZE_PER_BENCHMARK_REP="64"
  for X in $(seq -w 001 "$REPETITIONS"); do
      export RUNID="$X"
      bash tests/bats/lib/test_cd_nvb_failover.sh tests/bats/specs/nvb.tmpl.yaml 4
      if [ "$?" == "0" ]; then echo "Run $RUNID: passed"; else echo "Run $RUNID: failed"; break; fi
  done
}
