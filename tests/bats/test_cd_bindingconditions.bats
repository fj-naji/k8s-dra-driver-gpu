# shellcheck disable=SC2148
# shellcheck disable=SC2329

setup_file() {
  load 'helpers.sh'
  _common_setup

  # Namespace
  export DRIVER_NAMESPACE="${NAMESPACE:-nvidia-dra-driver-gpu}"

  # Namespace where ComputeDomain + workload objects are created
  export WORKLOAD_NAMESPACE="${TEST_WORKLOAD_NAMESPACE:-default}"

  if [[ "${RUN_HELM_UPGRADE:-false}" == "true" ]]; then
    local _iargs=("--set" "logVerbosity=6")
    iupgrade_wait "${TEST_CHART_REPO}" "${TEST_CHART_VERSION}" _iargs
  else
    echo "INFO: Skipping helm upgrade/install (RUN_HELM_UPGRADE!=true)"
  fi

  # Hard gate: refuse to run if driver pods are unhealthy
  if kubectl -n "${DRIVER_NAMESPACE}" get pods | grep -E "ImagePullBackOff|ErrImagePull|Init:ImagePullBackOff|CrashLoopBackOff" >/dev/null 2>&1; then
    echo "ERROR: driver pods unhealthy in ${DRIVER_NAMESPACE}"
    kubectl -n "${DRIVER_NAMESPACE}" get pods -o wide || true
    return 1
  fi

  retry 60 1 kubectl -n "${DRIVER_NAMESPACE}" get pods -l nvidia-dra-driver-gpu-component=controller --no-headers
  kubectl -n "${DRIVER_NAMESPACE}" wait --for=condition=Ready pod -l nvidia-dra-driver-gpu-component=controller --timeout=120s

  retry 60 1 kubectl -n "${DRIVER_NAMESPACE}" get pods -l nvidia-dra-driver-gpu-component=kubelet-plugin --no-headers
  kubectl -n "${DRIVER_NAMESPACE}" wait --for=condition=Ready pod -l nvidia-dra-driver-gpu-component=kubelet-plugin --timeout=180s
}

setup() {
  load 'helpers.sh'
  _common_setup

  export DRIVER_NAMESPACE="${NAMESPACE:-nvidia-dra-driver-gpu}"
  export WORKLOAD_NAMESPACE="${TEST_WORKLOAD_NAMESPACE:-default}"

  # Always start from a clean slate
  cleanup_imex_demo || true
}

bats::on_failure() {
  echo -e "\n\n===== FAILURE HOOK START ====="
  log_objects
  show_kubelet_plugin_error_logs
  show_kubelet_plugin_log_tails

  echo
  echo "--- controller logs (compute-domain tail)"
  kubectl -n "${DRIVER_NAMESPACE}" logs \
    -l nvidia-dra-driver-gpu-component=controller \
    -c compute-domain \
    --tail=400 2>/dev/null || true

  echo -e "===== FAILURE HOOK END =====\n\n"
}

# Teardown runs after EACH test
teardown() {
  cleanup_imex_demo || true
}

# -------------------------
# tests
# -------------------------

# 1) ResourceSlice publishes BindingConditions + BindingFailureConditions for channel devices
@test "compute-domain: ResourceSlice publishes BindingConditions + BindingFailureConditions for channel device" {
  local driver="compute-domain.nvidia.com"
  local bc="ComputeDomainReady"
  local bfc="ComputeDomainNotReady"

  # Find a single ResourceSlice for this driver and assert it contains the BC/BFC names.
  local driver="compute-domain.nvidia.com"
  local rs_name
  rs_name="$(
    kubectl get resourceslice --no-headers \
      | awk -v d="${driver}" '$3==d {print $1; exit}'
  )"

  [[ -n "${rs_name}" ]] || fail "no ResourceSlice found for driver=${driver}"

  # Get the ResourceSlice object
  run kubectl get resourceslice "${rs_name}" -o json
  assert_success

  # Check if BC & BFC are present in the ResourceSlice spec. for the target driver.
  printf '%s' "${output}" | jq -e --arg d "${driver}" --arg bc "${bc}" --arg bfc "${bfc}" '
    .spec.driver == $d
    and any(.spec.devices[]?; (.bindingConditions // []) | index($bc))
    and any(.spec.devices[]?; (.bindingFailureConditions // []) | index($bfc))
  ' >/dev/null || fail "ResourceSlice ${rs_name} missing expected BC/BFC"
}

# 2) Basic flow: ComputeDomain -> RCT -> Pod -> RC allocated -> node labeled -> DS Ready -> BC handled -> Pod scheduled/Ready
@test "compute-domain: basic flow (channel claim) -> node labeled -> DaemonSet Ready -> workload unblocked" {
  # TEST: End-to-end flow for ComputeDomain with channel ResourceClaims

  local imex_demo_spec="demo/specs/imex/channel-injection.yaml"
  local imex_demo_cd_name="imex-channel-injection"
  local imex_demo_pod_name="imex-channel-injection"
  local imex_demo_rct_name="imex-channel-0"

  # 1) Apply demo (creates ComputeDomain + Pod; controller creates RCT + DS)
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${imex_demo_spec}"

  # 2) Wait ComputeDomain exists and grab UID (domainID)
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${imex_demo_cd_name}" >/dev/null
  local domain_id
  domain_id="$(kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${imex_demo_cd_name}" -o jsonpath='{.metadata.uid}')"
  [[ -n "${domain_id}" ]] || fail "ComputeDomain UID(domain_id) is empty"

  # 3) Wait RCT exists (created by controller)
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaimtemplate "${imex_demo_rct_name}" >/dev/null

  # 4) Wait the Pod exists
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get pod "${imex_demo_pod_name}" >/dev/null

  # 5) Find ResourceClaim owned by pod and wait it becomes allocated+reserved
  local claim
  claim="$(wait_claim_for_pod "${WORKLOAD_NAMESPACE}" "${imex_demo_pod_name}")"
  [[ -n "${claim}" ]] || fail "Could not find ResourceClaim owned by pod ${imex_demo_pod_name}"
  wait_claim_allocated_reserved "${WORKLOAD_NAMESPACE}" "${claim}" \
    || fail "claim did not become allocated+reserved"

  # 6) Read allocationTimestamp to ensure claim status was processed (and we can read the node name from the claim)
  local node
  node="$(kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaim "${claim}" -o jsonpath='{.status.allocation.nodeSelector.nodeSelectorTerms[0].matchFields[0].values[0]}' 2>/dev/null || true)"
  [[ -n "${node}" ]] || fail "allocated node empty"

  # 7) Controller should label the allocated node with ComputeDomain UID
  assert_node_label_behavior present "${node}" "resource.nvidia.com/computeDomain" "${domain_id}" 60 2 \
    || fail "node label did not become resource.nvidia.com/computeDomain=${domain_id}"

  # 8) Label must cause DS pod to appear and become Ready
  wait_ds_pod_running_for_cd "${domain_id}" \
    || fail "DaemonSet pod did not become Ready for domain_id=${domain_id}"

  # 9) Pod should be blocked on BindingConditions at some point
  wait_for_pod_event "pod/${imex_demo_pod_name}" "BindingConditionsPending" 120 \
    || fail "did not observe BindingConditionsPending event for workload pod"

  # 10) Claim should eventually be marked done by controller
  wait_claim_bc_status_or_fail "${WORKLOAD_NAMESPACE}" "${claim}" "ComputeDomainReady" "True" \
    || fail "ResourceClaim did not get ComputeDomainReady=True"

  # 11) Scheduler should proceed to bind the pod (spec.nodeName set)
  wait_pod_scheduled_or_fail "${WORKLOAD_NAMESPACE}" "${imex_demo_pod_name}" \
    || fail "pod never got scheduled"
}

# 3) Controller filters out ResourceClaim with wrong driver
@test "compute-domain: controller filter - wrong-driver ResourceClaim does NOT label the node" {
  # TEST: Ensure the controller doesn't accidentally label nodes for 
  # ResourceClaims belonging to other drivers (e.g., 'wrong.driver.example.com').

  local claim_name="cd-bindingconditions-rc-test"
  local rc_spec="tests/bats/specs/cd-bc-rc-only.yaml"
  local patch_tmpl="tests/bats/specs/patches/rc-status-allocated-channel.json.tmpl"
  local cd_name="cd-bindingconditions-test"
  local cd_spec="tests/bats/specs/cd-bc-only.yaml"

  # 1) Create ComputeDomain
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${cd_spec}"
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${cd_name}" >/dev/null

  local domain_id
  domain_id="$(kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${cd_name}" -o jsonpath='{.metadata.uid}')"
  [[ -n "${domain_id}" ]] || fail "ComputeDomain UID(domain_id) is empty"

  # 2) Pick a node (used in patched allocation)
  local node
  node="$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')"
  [[ -n "${node}" ]] || fail "no nodes found"

  # 3) Create the ResourceClaim (must match claim_name!)
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${rc_spec}" >/dev/null
  retry 10 1 kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaim "${claim_name}" >/dev/null \
    || fail "ResourceClaim ${WORKLOAD_NAMESPACE}/${claim_name} not found (spec name mismatch?)"

  local fake_pod="test-fake-pod-${claim_name}"
  local fake_uid="00000000-0000-0000-0000-000000000000"

  # 4) Patch claim status to emulate allocation+reserved but with WRONG driver
  patch_resourceclaim_status_from_template "${WORKLOAD_NAMESPACE}" "${claim_name}" "${patch_tmpl}" \
    NODE_NAME="${node}" \
    DOMAIN_ID="${domain_id}" \
    POD_NAME="${fake_pod}" \
    POD_UID="${fake_uid}" \
    ALLOCATION_TIMESTAMP="2026-01-29T00:00:00Z" \
    OPAQUE_DRIVER="wrong.driver.example.com" \
    RESULT_DRIVER="wrong.driver.example.com" \
    KIND="ComputeDomainChannelConfig" \
    POOL="dummy-pool" \
    DEVICE="dummy"

  # 5) Assert controller ignores it => node label set stays unchanged
  assert_node_label_behavior unchanged "" "resource.nvidia.com/computeDomain" "" 15 1
}

# 4) Controller filters out ResourceClaim with wrong kind in status
@test "compute-domain: controller filter - wrong-kind ResourceClaim does NOT label the node" {
  # TEST: Ensure the controller doesn't label nodes for
  # ResourceClaims with wrong 'kind'

  local claim_name="cd-bindingconditions-rc-test"
  local rc_spec="tests/bats/specs/cd-bc-rc-only.yaml"
  local patch_tmpl="tests/bats/specs/patches/rc-status-allocated-channel.json.tmpl"
  local cd_name="cd-bindingconditions-test"
  local cd_spec="tests/bats/specs/cd-bc-only.yaml"


  # 1) Create IMEX demo ONLY to get a real ComputeDomain UID (domain_id)
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${cd_spec}"

  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${cd_name}" >/dev/null
  local domain_id
  domain_id="$(kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${cd_name}" -o jsonpath='{.metadata.uid}')"
  [[ -n "${domain_id}" ]] || fail "ComputeDomain UID(domain_id) is empty"

  # 2) Create the ResourceClaim (static name) and patch its status to emulate "allocated+reserved"
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${rc_spec}" >/dev/null

  local fake_pod="test-fake-pod-${claim_name}"
  local fake_uid="00000000-0000-0000-0000-000000000000"

  local node
  node="$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')"
  [[ -n "${node}" ]] || fail "no nodes found"

  # 3) Path claim - WRONG KIND: ComputeDomainDaemonConfig instead of ComputeDomainChannelConfig
  patch_resourceclaim_status_from_template "${WORKLOAD_NAMESPACE}" "${claim_name}" "${patch_tmpl}" \
    NODE_NAME="${node}" \
    DOMAIN_ID="${domain_id}" \
    POD_NAME="${fake_pod}" \
    POD_UID="${fake_uid}" \
    ALLOCATION_TIMESTAMP="2026-01-29T00:00:00Z" \
    OPAQUE_DRIVER="compute-domain.nvidia.com" \
    RESULT_DRIVER="compute-domain.nvidia.com" \
    KIND="ComputeDomainDaemonConfig" \
    POOL="dummy-pool" \
    DEVICE="dummy"

  # 4) Assert controller ignores it => label stays empty on *that* node (stays unlabeled for ~15s)
  assert_node_label_behavior unchanged "" "resource.nvidia.com/computeDomain" "" 15 1
}

# 5) Controller filters out ResourceClaim without allocation/reserved
@test "compute-domain: controller filter - ResourceClaim without allocation/reserved does NOT label the node" {
  # TEST: Ensure the controller doesn't label nodes for
  # ResourceClaims that are not allocated+reserved.

  # 1) Create the ResourceClaim (static name)
  local rc_spec="tests/bats/specs/cd-bc-rc-only.yaml"
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${rc_spec}" >/dev/null

  # 2) Assert controller ignores it => node label stays empty (for ~15s)
  assert_node_label_behavior unchanged "" "resource.nvidia.com/computeDomain" "" 15 1
}

# 6) Controller filters out ResourceClaim in different namespace than ComputeDomain
@test "compute-domain: namespace mismatch (ComputeDomain != ResourceClaim ns) does NOT label node" {
  # SECURITY/ISOLATION TEST: The controller must ignore ResourceClaims 
  # if the referenced ComputeDomain is in a different namespace.

  local other_ns="test-cd-other-ns"
  local cd_name="cd-bindingconditions-test"
  local cd_spec="tests/bats/specs/cd-bc-only.yaml"
  local claim_name="cd-bindingconditions-rc-test"
  local rc_spec="tests/bats/specs/cd-bc-rc-only.yaml"
  local patch_tmpl="tests/bats/specs/patches/rc-status-allocated-channel.json.tmpl"

  # Ensure OTHER namespace exists
  kubectl get namespace "${other_ns}" >/dev/null 2>&1 \
    || kubectl create namespace "${other_ns}" >/dev/null 2>&1


  # 1) Create ONLY a ComputeDomain in WORKLOAD_NAMESPACE to get a real UID
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${cd_spec}" >/dev/null
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${cd_name}" >/dev/null

  local domain_id
  domain_id="$(kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${cd_name}" -o jsonpath='{.metadata.uid}')"
  [[ -n "${domain_id}" ]] || fail "ComputeDomain UID(domain_id) is empty"

  # 2) Create ResourceClaim in OTHER namespace
  kubectl -n "${other_ns}" delete resourceclaim "${claim_name}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${other_ns}" apply -f "${rc_spec}" >/dev/null
  retry 30 1 kubectl -n "${other_ns}" get resourceclaim "${claim_name}" >/dev/null


  local fake_pod="test-fake-pod-${claim_name}"
  local fake_uid="00000000-0000-0000-0000-000000000000"

  local node
  node="$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')"
  [[ -n "${node}" ]] || fail "no nodes found"
  
  # 3) Patch RC status (allocated+reserved)
  patch_resourceclaim_status_from_template "${other_ns}" "${claim_name}" "${patch_tmpl}" \
    NODE_NAME="${node}" \
    DOMAIN_ID="${domain_id}" \
    POD_NAME="${fake_pod}" \
    POD_UID="${fake_uid}" \
    ALLOCATION_TIMESTAMP="2026-01-29T00:00:00Z" \
    OPAQUE_DRIVER="compute-domain.nvidia.com" \
    RESULT_DRIVER="compute-domain.nvidia.com" \
    KIND="ComputeDomainChannelConfig" \
    POOL="dummy-pool" \
    DEVICE="dummy"

  # 4) Assert controller ignores it => label stays empty
  assert_node_label_behavior unchanged "" "resource.nvidia.com/computeDomain" "" 15 1
}

# 7) BindingTimeout path: CD Ready, DS pod not running, then Ready -> pod eventually scheduled
@test "compute-domain: BindingTimeout -> Success (cd ready, ds blocked -> pod pending -> ds unblocked -> pod scheduled)" {
  # TEST: Simulate a BindingTimeout scenario:
  # 1. ComputeDomain created -> DS starts.
  # 2. We sabotage the DS with a "test-blocker" initContainer.
  # 3. Workload pod requests resource -> Scheduler allocates but can't bind.
  # 4. We simulate a Scheduler timeout by injecting a fake 'BindingTimeout' event.
  # 5. We then fix the DS and ensure the Controller/Scheduler recover.
  # 6. Observe pending Pod.
  # 7: Manual Event Injection
  # Since we can't easily wait for the real 10 minute scheduler timeout,
  # we inject a 'FailedScheduling' event to trick the controller into its retry logic.
  # ...

  local cd_spec="tests/bats/specs/cd-bc-only.yaml"
  local pod_spec="tests/bats/specs/cd-bc-pod-only.yaml"
  
  local cd_name="cd-bindingconditions-test"
  local pod_name="cd-bindingconditions-pod"
  local rct_name="cd-channel-0"

  # 1) Create ComputeDomain (controller should create RCT + DaemonSet)
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${cd_spec}" >/dev/null
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${cd_name}" >/dev/null

  local domain_id
  domain_id="$(kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${cd_name}" -o jsonpath='{.metadata.uid}')"
  [[ -n "${domain_id}" ]] || fail "ComputeDomain UID(domain_id) is empty"

  # 2) Wait RCT exists (created by controller)
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaimtemplate "${rct_name}" >/dev/null \
    || fail "ResourceClaimTemplate ${WORKLOAD_NAMESPACE}/${rct_name} did not appear"

  # 3) Find DaemonSet name for this ComputeDomain and block it (simulate not-ready)
  # Wait for DaemonSet name labeled with resource.nvidia.com/computeDomain=${domain_id}
  local ds_name=""
  for i in $(seq 1 60); do
    ds_name="$(kubectl -n "${DRIVER_NAMESPACE}" get ds \
      -l "resource.nvidia.com/computeDomain=${domain_id}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${ds_name}" ]]; then
      break
    fi
    sleep 1
  done
  [[ -n "${ds_name}" ]] || {
    echo "ERROR: could not find DaemonSet with label resource.nvidia.com/computeDomain=${domain_id} in ns=${DRIVER_NAMESPACE}"
    kubectl -n "${DRIVER_NAMESPACE}" get ds -o wide || true
    kubectl -n "${DRIVER_NAMESPACE}" get ds -l "resource.nvidia.com/computeDomain=${domain_id}" -o yaml || true
    fail "daemonset not found"
  }

  kubectl -n "${DRIVER_NAMESPACE}" patch ds "${ds_name}" \
  --type=strategic -p '{
    "spec": {
      "template": {
        "spec": {
          "initContainers": [{
            "name": "test-blocker",
            "image": "busybox:1.36",
            "command": ["sh","-c","sleep 36000"]
          }]
        }
      }
    }
  }' >/dev/null
  sleep 2

  # 4) Create workload pod (it references the RCT)
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${pod_spec}" >/dev/null
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get pod "${pod_name}" >/dev/null

  # 5) Find ResourceClaim owned by pod and wait it becomes allocated+reserved
  local claim
  claim="$(wait_claim_for_pod "${WORKLOAD_NAMESPACE}" "${pod_name}")"
  [[ -n "${claim}" ]] || fail "Could not find ResourceClaim owned by pod ${pod_name}"

  wait_claim_allocated_reserved "${WORKLOAD_NAMESPACE}" "${claim}" \
    || fail "claim did not become allocated+reserved"

  # Read allocationTimestamp to ensure claim status was processed
  local ts0
  ts0="$(kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaim "${claim}" -o jsonpath='{.status.allocation.allocationTimestamp}')"
  [[ -n "${ts0}" ]] || fail "allocationTimestamp is empty for claim=${claim}"

  # NOW we can read the node chosen by scheduler
  local node
  node="$(kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaim "${claim}" -o jsonpath='{.status.allocation.nodeSelector.nodeSelectorTerms[0].matchFields[0].values[0]}' 2>/dev/null || true)"
  [[ -n "${node}" ]] || fail "allocated node empty"

  # Controller should label that node with ComputeDomain UID
  assert_node_label_behavior present "${node}" "resource.nvidia.com/computeDomain" "${domain_id}" 60 2 \
    || fail "node label did not become resource.nvidia.com/computeDomain=${domain_id}"
  
  # 6) We expect pod to be blocked on BindingConditions while DS init is blocking
  wait_for_pod_event "pod/${pod_name}" "BindingConditionsPending" 120 \
    || fail "did not observe BindingConditionsPending event for workload pod"

  # 7) Inject BindingTimeout event to drive the timeout path (artificially)
  local pod_uid
  pod_uid="$(kubectl -n "${WORKLOAD_NAMESPACE}" get pod "${pod_name}" -o jsonpath='{.metadata.uid}')"
  [[ -n "${pod_uid}" ]] || fail "pod UID is empty"

  # Inject Scheduling Failed event with BindingTimeout message
  kubectl -n "${WORKLOAD_NAMESPACE}" create -f - >/dev/null <<EOF
apiVersion: v1
kind: Event
metadata:
  name: ${pod_name}-binding-timeout-$(date +%s)
  namespace: ${WORKLOAD_NAMESPACE}
involvedObject:
  apiVersion: v1
  kind: Pod
  name: ${pod_name}
  namespace: ${WORKLOAD_NAMESPACE}
  uid: ${pod_uid}
reason: FailedScheduling
message: "running PreBind plugin \"DynamicResources\": claim ${claim} binding timeout"
type: Warning
firstTimestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
lastTimestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
count: 1
source:
  component: test
EOF
  sleep 5

  # 8) Check allocationTimestamp change
  local ts1
  ts1="$(kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaim "${claim}" -o jsonpath='{.status.allocation.allocationTimestamp}')"
  [[ "${ts0}" == "${ts1}" ]] || fail "allocationTimestamp was not updated on claim=${claim}"

  # 9) Unblock DS init so DS can become Ready and controller can mark claim condition True
  # Remove initContainers
  kubectl -n "${DRIVER_NAMESPACE}" patch ds "${ds_name}" \
    --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/initContainers"}]' >/dev/null 2>&1 || true

  # 10) Recreate DS pods (so they come back without blocker)
  kubectl -n "${DRIVER_NAMESPACE}" delete pod \
    -l "resource.nvidia.com/computeDomain=${domain_id}" \
    --wait=false >/dev/null 2>&1 || true

  # 11) Wait for rollout
  kubectl -n "${DRIVER_NAMESPACE}" rollout status ds "${ds_name}" --timeout=180s

  # 12) Wait DS pod becomes Ready
  wait_ds_pod_running_for_cd "${domain_id}" \
    || fail "DaemonSet pod did not become Ready for domain_id=${domain_id}"

  # 13) Now the controller should mark the claim condition True
  wait_claim_bc_status_or_fail "${WORKLOAD_NAMESPACE}" "${claim}" "ComputeDomainReady" "True" "${node}" "${cd_name}" "${pod_name}" \
    || fail "ResourceClaim did not get ComputeDomainReady=True"

  # 14) Finally, pod should get scheduled
  wait_pod_scheduled_or_fail "${WORKLOAD_NAMESPACE}" "${pod_name}" "${node}" "${cd_name}" \
    || fail "pod never got scheduled after timeout->success path"

}

# 8) Failure: NotReady -> claim gets ComputeDomainNotReady=True -> RC rescheduled
@test "compute-domain: BindingFailureCondition (cd ready -> ds image changed -> pod pending -> ComputeDomainNotReady -> RC rescheduled)" {
  local cd_spec="tests/bats/specs/cd-bc-only.yaml"
  local pod_spec="tests/bats/specs/cd-bc-pod-only.yaml"
  
  local cd_name="cd-bindingconditions-test"
  local pod_name="cd-bindingconditions-pod"
  local rct_name="cd-channel-0"

  # 1) Create ComputeDomain (controller should create RCT + DaemonSet)
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${cd_spec}" >/dev/null
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${cd_name}" >/dev/null

  local domain_id
  domain_id="$(kubectl -n "${WORKLOAD_NAMESPACE}" get computedomains "${cd_name}" -o jsonpath='{.metadata.uid}')"
  [[ -n "${domain_id}" ]] || fail "ComputeDomain UID(domain_id) is empty"

  # 2) Wait RCT exists (created by controller)
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaimtemplate "${rct_name}" >/dev/null \
    || fail "ResourceClaimTemplate ${WORKLOAD_NAMESPACE}/${rct_name} did not appear"

  # 3) Find DaemonSet name for this ComputeDomain and change image to nonexisting one.
  # Wait for DaemonSet name labeled with resource.nvidia.com/computeDomain=${domain_id}
  local ds_name=""
  for i in $(seq 1 60); do
    ds_name="$(kubectl -n "${DRIVER_NAMESPACE}" get ds \
      -l "resource.nvidia.com/computeDomain=${domain_id}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${ds_name}" ]]; then
      break
    fi
    sleep 1
  done
  [[ -n "${ds_name}" ]] || {
    echo "ERROR: could not find DaemonSet with label resource.nvidia.com/computeDomain=${domain_id} in ns=${DRIVER_NAMESPACE}"
    kubectl -n "${DRIVER_NAMESPACE}" get ds -o wide || true
    kubectl -n "${DRIVER_NAMESPACE}" get ds -l "resource.nvidia.com/computeDomain=${domain_id}" -o yaml || true
    fail "daemonset not found"
  }

  kubectl -n "${DRIVER_NAMESPACE}" patch ds "${ds_name}" \
  --type=strategic -p '{
    "spec": {
      "template": {
        "spec": {
          "containers": [{
            "name": "compute-domain-daemon",
            "image": "non_existant_image"
          }]
        }
      }
    }
  }' >/dev/null
  sleep 2

  # 4) Create workload pod (it references the RCT)
  kubectl -n "${WORKLOAD_NAMESPACE}" apply -f "${pod_spec}" >/dev/null
  retry 60 1 kubectl -n "${WORKLOAD_NAMESPACE}" get pod "${pod_name}" >/dev/null

  # 5) Find ResourceClaim owned by pod and wait it becomes allocated+reserved
  local claim
  claim="$(wait_claim_for_pod "${WORKLOAD_NAMESPACE}" "${pod_name}")"
  [[ -n "${claim}" ]] || fail "Could not find ResourceClaim owned by pod ${pod_name}"

  wait_claim_allocated_reserved "${WORKLOAD_NAMESPACE}" "${claim}" \
    || fail "claim did not become allocated+reserved"

  # Read allocationTimestamp to ensure claim status was processed
  local ts0
  ts0="$(kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaim "${claim}" -o jsonpath='{.status.allocation.allocationTimestamp}')"
  [[ -n "${ts0}" ]] || fail "allocationTimestamp is empty for claim=${claim}"

  # NOW we can read the node chosen by scheduler
  local node
  node="$(kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaim "${claim}" -o jsonpath='{.status.allocation.nodeSelector.nodeSelectorTerms[0].matchFields[0].values[0]}' 2>/dev/null || true)"
  [[ -n "${node}" ]] || fail "allocated node empty"

  # Controller should label that node with ComputeDomain UID
  assert_node_label_behavior present "${node}" "resource.nvidia.com/computeDomain" "${domain_id}" 60 2 \
    || fail "node label did not become resource.nvidia.com/computeDomain=${domain_id}"
  
  # 6) We expect pod to be blocked on BindingConditions while DS init is blocking
  wait_for_pod_event "pod/${pod_name}" "BindingConditionsPending" 120 \
    || fail "did not observe BindingConditionsPending event for workload pod"

  # 7) Now the controller should mark the claim condition True
  wait_claim_bc_status_or_fail "${WORKLOAD_NAMESPACE}" "${claim}" "ComputeDomainNotReady" "True" \
    || fail "ResourceClaim did not get ComputeDomainNotReady=True"

  # 8) Check allocationTimestamp change
  local ts1
  for i in $(seq 1 60); do
    ts1="$(kubectl -n "${WORKLOAD_NAMESPACE}" get resourceclaim "${claim}" -o jsonpath='{.status.allocation.allocationTimestamp}')"
    if [[ "${ts0}" != "${ts1}" && -n "${ts1}" ]]; then
      break
    fi
    sleep 1
  done
  [[ "${ts0}" != "${ts1}" && -n "${ts1}" ]] || fail "ResourceClaim did not rechedule"
}