#!/bin/bash
#
#  SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
#  SPDX-License-Identifier: Apache-2.0
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# Use a name that upon cluster inspection reveals that this
# Helm chart release was installed/managed by this test suite.
export TEST_HELM_RELEASE_NAME="nvidia-dra-driver-gpu-batssuite"


# Extend PATH, for example for the `nvmm` utility.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export PATH="${SELF_DIR}/lib:${PATH}"


_common_setup() {
  load '/bats-libraries/bats-support/load.bash'
  load '/bats-libraries/bats-assert/load.bash'
  load '/bats-libraries/bats-file/load.bash'
}


# A helper arg for `iupgrade_wait` w/o additional install args.
export NOARGS=()

# Install or upgrade, and wait for pods to be READY.
# 1st arg: helm chart repo
# 2nd arg: helm chart version
# 3rd arg: array with additional args (provide `NOARGS` if none)
iupgrade_wait() {
  # E.g. `nvidia/nvidia-dra-driver-gpu` or
  # `oci://ghcr.io/nvidia/k8s-dra-driver-gpu`
  local REPO="$1"

  # E.g. `25.3.1` or `25.8.0-dev-f2eaddd6-chart`
  local VERSION="$2"

  # Expect array as third argument.
  local -n ADDITIONAL_INSTALL_ARGS=$3

  timeout -v 120 helm upgrade --install "${TEST_HELM_RELEASE_NAME}" \
    "${REPO}" \
    --version="${VERSION}" \
    --wait \
    --timeout=1m5s \
    --create-namespace \
    --namespace nvidia-dra-driver-gpu \
    --set gpuResourcesEnabledOverride=true \
    --set nvidiaDriverRoot="${TEST_NVIDIA_DRIVER_ROOT}" "${ADDITIONAL_INSTALL_ARGS[@]}"

  # Valueable output to have in the logs in case things went pearshaped.
  kubectl get pods -n nvidia-dra-driver-gpu

  # Some part of this waiting work is done by helm as of `--wait` with
  # `--timeout`. Note that the below in itself would not be sufficient: in case
  # of an upgrade we need to isolate the _new_ pods and not accidentally observe
  # the currently disappearing pods. Also note that despite the `--wait` above,
  # the kubelet plugins may still be in `PodInitializing` or `Init:0/1` after
  # the Helm command returned. My conclusion is that helm waits for the
  # controller to be READY, but not for the plugin pods to be READY. An old
  # plugin pod may also still be present in `Completed` state. The label
  # selector below may (rarely) pick it up, and of course that one will never
  # transition to READY. Fix that by only waiting for pods that are not in
  # Terminating/Completed state (that do not have a deletionTimestamp). That's
  # not natively supported by `kubectl wait`, hence this must be something of
  # the shape
  # `kubectl get pods ... | xargs -I{} kubectl wait --for=condition=Ready pod/{} `
  sleep 1
  kubectl wait --for=condition=READY pods -A -l nvidia-dra-driver-gpu-component=kubelet-plugin --timeout=15s

  # Again, log current state.
  kubectl get pods -n nvidia-dra-driver-gpu

  # That one should be obvious now, but make that guarantee explicit for
  # consuming tests.
  kubectl wait --for=condition=READY pods -A -l nvidia-dra-driver-gpu-component=controller --timeout=10s
  # maybe: check version on labels (to confirm that we set labels correctly)
  log "iupgrade_wait: done"
}


log_objects() {
  # Never fail, but show output in case a test fails, to facilitate debugging.
  # Could this be part of setup()? If setup succeeds and when a test fails:
  # does this show the output of setup? Then we could do this.
  kubectl get resourceclaims || true
  kubectl get computedomain || true
  kubectl get pods -o wide || true
  kubectl get pods -o wide -n nvidia-dra-driver-gpu || true
}


# Events accumulate over time, so for certainty it's best to use a unique pod
# name. Right now, this inspects an entire line which includes REASON, MESSAGE,
# and OBJECT, so choose the needle (grepped for) precisely enough.
# Example: wait_for_pod_event pod/testpod-ls09x FailedPrepareDynamicResources 60
wait_for_pod_event() {
  # Expect this to have the pod/ prefix
  local POD_NAME="$1"
  local REASON="$2"
  local TIMEOUT="$3"

  local START=$SECONDS
  while true; do
    if kubectl events --for "${POD_NAME}" | grep -q "${REASON}"; then
      echo "Event detected: ${REASON} (for ${POD_NAME})"
      return 0
    fi
    if (( SECONDS - START > TIMEOUT )); then
      echo "Timeout (${TIMEOUT} s) waiting for '${REASON}' in events for ${POD_NAME}"
      return 1
    fi
    sleep 2
  done
}


get_all_cd_daemon_logs_for_cd_name() {
  CD_NAME="$1"
  CD_UID=$(kubectl describe computedomains.resource.nvidia.com "${CD_NAME}" | grep UID | awk '{print $2}')
  CD_LABEL_KV="resource.nvidia.com/computeDomain=${CD_UID}"
  echo "CD daemon logs for CD: $CD_UID"
  kubectl logs \
    -n nvidia-dra-driver-gpu \
    -l "${CD_LABEL_KV}" \
    --tail=-1 \
    --prefix \
    --all-containers
}


show_kubelet_plugin_error_logs() {
  echo -e "\nKUBELET PLUGIN ERROR LOGS START"
  (
    kubectl logs \
    -l nvidia-dra-driver-gpu-component=kubelet-plugin \
    -n nvidia-dra-driver-gpu \
    --all-containers \
    --prefix --tail=-1 | grep -E -e "^(E|W)[0-9]{4}" -e "error"
  ) || true
  echo -e "KUBELET PLUGIN ERROR LOGS END\n\n"
}


show_kubelet_plugin_log_tails() {
  echo -e "\nKUBELET PLUGIN LOG TAILS START"
  (
    kubectl logs \
    -l nvidia-dra-driver-gpu-component=kubelet-plugin \
    -n nvidia-dra-driver-gpu \
    --all-containers \
    --prefix --tail=400
  ) || true
  echo -e "KUBELET PLUGIN LOG TAILS END\n\n"
}


show_gpu_plugin_log_tails() {
  echo -e "\nKUBELET GPU PLUGIN LOGS TAILS(400) START"
  (
    kubectl logs \
    -l nvidia-dra-driver-gpu-component=kubelet-plugin \
    -n nvidia-dra-driver-gpu \
    --container gpus \
    --prefix --tail=400
  ) || true
  echo -e "KUBELET GPU PLUGIN LOG TAILS(400) END\n\n"
}


# Intended use case: one pod in Running or ContainerCreating state; then this
# function returns the specific name of that pod. Specifically, ignore pods that
# were just deleted or are terminating (this is important during the small time
# window of restarting the controller, say in response to a deployment podspec
# template mutation).
get_current_controller_pod_name() {
  kubectl get pod \
    -l nvidia-dra-driver-gpu-component=controller \
    -n nvidia-dra-driver-gpu \
      | grep -iv "NAME" \
      | grep -iv 'completed' \
      | grep -iv 'terminating' \
      | awk '{print $1}'
}


get_one_kubelet_plugin_pod_name() {
  kubectl get pod \
    -l nvidia-dra-driver-gpu-component=kubelet-plugin \
    -n nvidia-dra-driver-gpu \
      | grep -iv "NAME" \
      | grep -i 'running' \
      | head -n1 \
      | awk '{print $1}'
}


apply_check_delete_workload_imex_chan_inject() {
  kubectl apply -f demo/specs/imex/channel-injection.yaml
  kubectl wait --for=condition=READY pods imex-channel-injection --timeout=100s
  run kubectl logs imex-channel-injection
  assert_output --partial "channel0"

  # Wait for deletion to complete; this is critical before moving on to the next
  # test (as long as we don't wipe state entirely between tests).
  kubectl delete -f demo/specs/imex/channel-injection.yaml
  kubectl wait --for=delete pods imex-channel-injection --timeout=10s
}


mig_confirm_disabled_on_all_nodes() {
  # Confirm that MIG mode is disabled for all GPUs; in all nodes.
  run nvmm all sh -c 'nvidia-smi --query-gpu=index,mig.mode.current --format=csv'
  refute_output --partial "Enabled"
}


# Enable MIG mode on the selected node on GPU 0, and create a MIG device. Pick
# the first listed 1g profile (available on all MIG-capable GPUs).
mig_create_1g0_on_node() {
  local nodename="$1"
  local mprofile=$(nvmm "$nodename" nvidia-smi mig -lgip -i 0 | grep -m 1 -oE '1g\.[1-9]+gb')
  echo "selected MIG profile: $mprofile"
  nvmm "$nodename" nvidia-smi -i 0 -mig 1
  nvmm "$nodename" nvidia-smi mig -cgi "$mprofile" -C
  log "created mig dev"
}


# On all nodes, attempt ot destroy all MIG devices and disable MIG mode for all
# physical GPUs. Fail the consuming test if any GPU in any of the nodes still
# has MIG mode enabled. This can serve as 1) an explicit assertion about current
# state when entering a test, and 2) a convenient cleanup routine during test
# development, and 3) a regular cleanup when leaving a test.
mig_ensure_teardown_on_all_nodes() {
  nvmm all sh -c 'nvidia-smi mig -dci; nvidia-smi mig -dgi; nvidia-smi -mig 0'
  mig_confirm_disabled_on_all_nodes
}


restart_kubelet_on_node() {
  local NODEIP="$1"
  echo "sytemctl restart kubelet.service on ${NODEIP}"
  # Assume that current user has password-less sudo privileges
  ssh "${USER}@${NODEIP}" 'sudo systemctl restart kubelet.service'
}


restart_kubelet_all_nodes() {
  for nodeip in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'); do
    restart_kubelet_on_node "$nodeip"
  done
  #wait
  echo "restart kubelets: done"
}


kplog () {
  if [[ -z "$1" || -z "$2" ]]; then
    echo "Usage: kplog [gpus|compute-domains] <node-hint-for-grep> [args]"
    return 1
  fi
  local nodehint="$2"
  local cont="$1"
  shift
  shift # Remove first argument, leaving remaining args in $@

  local node=$(kubectl get nodes | grep "$nodehint" | awk '{print $1}')
  echo "identified node: $node"

  local pod
  pod=$(kubectl get pod -n nvidia-dra-driver-gpu -l nvidia-dra-driver-gpu-component=kubelet-plugin \
    --field-selector spec.nodeName="$node" \
    --no-headers -o custom-columns=":metadata.name")

  if [ -z "$pod" ]; then
    echo " get pod -n nvidia-dra-driver-gpu -l nvidia-dra-driver-gpu-component=kubelet-plugin: no pod found on node $node"
    return 1
  fi

  echo "Executing on pod $pod (node: $node)..."
  kubectl logs -n nvidia-dra-driver-gpu "$pod" -c "$cont" "$@"
}


_log_ts_no_newline() {
    echo -n "$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ ')"
}


# For measuring duration with sub-second precision.
export _T0=$(awk '{print $1}' /proc/uptime)
log() {
  _TNOW=$(awk '{print $1}' /proc/uptime)
  _DUR=$(echo "$_TNOW - $_T0" | bc)
  _log_ts_no_newline
  printf "[%6.1fs] $1\n" "$_DUR"
}

# Simple retry loop
retry() {
  # Args : arg1: retries, arg2: wait time in seconds
  local retries="$1"; local sleep_s="$2"; shift 2
  local i
  for i in $(seq 1 "${retries}"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep "${sleep_s}"
  done
  return 1
}

assert_node_label_behavior() {
  # Usage:
  #   assert_node_label_behavior <mode> <node_or_empty> <label_key> <value_or_empty> <duration_s> [interval_s]
  #
  # Modes:
  #   - "unchanged": set of node=value lines must not change
  #   - "present":   must appear (for specific node or any node)
  #
  # Examples:
  #   assert_node_label_behavior unchanged "" "resource.nvidia.com/computeDomain" "" 15 1
  #   assert_node_label_behavior present   "" "resource.nvidia.com/computeDomain" "" 60 2
  #   assert_node_label_behavior present   "localhost" "resource.nvidia.com/computeDomain" "${domain_id}" 60 2

  # Internal helper to extract node-label pairs.
  # Returns a sorted list of "node=value" strings.
  # If $node is empty, it checks all nodes. 
  # If $expected is empty, it checks for the existence of the key.

  local mode="$1"
  local node="${2:-}"
  local label_key="$3"
  local expected="${4:-}"
  local duration_s="${5:-15}"
  local interval_s="${6:-1}"

  local max_iter i baseline current

  _dump_nodes_label_kv() {
    kubectl get nodes -o json \
      | jq -r --arg k "${label_key}" --arg v "${expected}" --arg n "${node}" '
          [
            .items[]
            | select(($n|length)==0 or .metadata.name==$n)
            | select(.metadata.labels[$k]? != null)
            | select(($v|length)==0 or .metadata.labels[$k]==$v)
            | "\(.metadata.name)=\(.metadata.labels[$k])"
          ] | sort | .[]
        ' 2>/dev/null || true
  }

  max_iter=$((duration_s / interval_s))
  [[ "${max_iter}" -ge 1 ]] || max_iter=1

  case "${mode}" in
    unchanged)
      # Validates that no labels are added/removed/changed during the duration.
      baseline="$(_dump_nodes_label_kv)"
      for i in $(seq 1 "${max_iter}"); do
        current="$(_dump_nodes_label_kv)"
        if [[ "${current}" != "${baseline}" ]]; then
          echo "Baseline (${label_key}${expected:+=${expected}}${node:+ on node=${node}}):"
          echo "${baseline}" || true
          echo "Current (${label_key}${expected:+=${expected}}${node:+ on node=${node}}):"
          echo "${current}" || true
          fail "node label set changed: ${label_key}${expected:+=${expected}}${node:+ on ${node}}"
        fi
        sleep "${interval_s}"
      done
      ;;
    present)
      # Polls until at least one node matches the criteria.
      # Returns 0 immediately on success to save test time.
      for i in $(seq 1 "${max_iter}"); do
        current="$(_dump_nodes_label_kv)"
        if [[ -n "${current}" ]]; then
          echo "${current}" | head -n1
          return 0
        fi
        sleep "${interval_s}"
      done

      echo "ERROR: timed out waiting for ${label_key}${expected:+=${expected}}${node:+ on node=${node}}"
      if [[ -n "${node}" ]]; then
        kubectl get node "${node}" -o json \
          | jq -r --arg k "${label_key}" '"\(.metadata.name) \(.metadata.labels[$k] // "")"' 2>/dev/null || true
      else
        kubectl get nodes -o json \
          | jq -r --arg k "${label_key}" '.items[] | "\(.metadata.name) \(.metadata.labels[$k] // "")"' 2>/dev/null || true
      fi
      return 1
      ;;
    *)
      fail "assert_node_label_behavior: invalid mode '${mode}'"
      ;;
  esac
}

wait_claim_for_pod() {
  # Kubernetes DRA: ResourceClaims are often linked to Pods via ownerReferences.
  # This finds the claim created for a specific Pod instance (UID-based).

  local ns="$1"
  local pod_name="$2"

  local pod_uid
  # We use UID instead of name to ensure we don't pick up a stale Claim 
  # from a previous Pod of the same name.
  pod_uid="$(kubectl -n "${ns}" get pod "${pod_name}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  [[ -n "${pod_uid}" ]] || { echo ""; return 1; }

  local i claim
  for i in $(seq 1 60); do
    claim="$(
      kubectl -n "${ns}" get resourceclaim -o json \
        | jq -r --arg uid "${pod_uid}" '
            .items[]
            | select((.metadata.ownerReferences // []) | any(.uid == $uid))
            | .metadata.name
          ' | head -n 1
    )"
    if [[ -n "${claim}" && "${claim}" != "null" ]]; then
      echo "${claim}"
      return 0
    fi
    sleep 1
  done

  echo ""
  return 1
}

wait_claim_allocated_reserved() {
  local ns="$1"
  local claim="$2"

  local i
  for i in $(seq 1 90); do
    local alloc reserved
    alloc="$(kubectl -n "${ns}" get resourceclaim "${claim}" -o jsonpath='{.status.allocation.devices.results[0].device}' 2>/dev/null || true)"
    reserved="$(kubectl -n "${ns}" get resourceclaim "${claim}" -o jsonpath='{.status.reservedFor[0].uid}' 2>/dev/null || true)"
    if [[ -n "${alloc}" && -n "${reserved}" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_claim_bc_status_or_fail() {
  # 'bc' stands for BindingCondition. 
  # This waits for a specific Driver/Controller to signal that a claim is ready 
  # or has met a specific hardware requirement (e.g., 'ComputeDomainReady=True').

  local ns="$1"
  local claim="$2"
  local bc_name="$3"
  local bc_status="$4"

  local i
  for i in $(seq 1 180); do
    if kubectl -n "${ns}" get resourceclaim "${claim}" -o json \
      | jq -e --arg name "${bc_name}" --arg st "${bc_status}" '
          any(
            (.status.devices // [])[].conditions[]?;
            .type==$name and .status==$st
          )
        ' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "ERROR: timed out waiting for ${ns}/${claim} condition ${bc_name}=${bc_status}"
  kubectl -n "${ns}" get resourceclaim "${claim}" -o yaml || true
  return 1
}

wait_pod_scheduled_or_fail() {
  local ns="$1"
  local pod="$2"

  local i n
  for i in $(seq 1 90); do
    n="$(kubectl -n "${ns}" get pod "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    if [[ -n "${n}" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "ERROR: pod never got scheduled (spec.nodeName still empty): ${ns}/${pod}"
  kubectl -n "${ns}" get pod "${pod}" -o yaml || true
  return 1
}

wait_ds_pod_running_for_cd() {
  local cd_uid="$1"

  retry 60 2 bash -c \
    "kubectl -n \"${DRIVER_NAMESPACE}\" get pod -l resource.nvidia.com/computeDomain=\"${cd_uid}\" --no-headers | grep -q ."

  kubectl -n "${DRIVER_NAMESPACE}" wait \
    --for=condition=Ready pod \
    -l resource.nvidia.com/computeDomain="${cd_uid}" \
    --timeout=180s
}

patch_resourceclaim_status_from_template() {
  # Usage:
  #   patch_resourceclaim_status_from_template <ns> <claim> <template_path> \
  #     NODE_NAME=... DOMAIN_ID=... POD_NAME=... POD_UID=... \
  #     ALLOCATION_TIMESTAMP=... OPAQUE_DRIVER=... RESULT_DRIVER=... \
  #     KIND=... POOL=... DEVICE=...
  #
  # Template placeholders are: __NODE_NAME__ __DOMAIN_ID__ __POD_NAME__ __POD_UID__
  # plus optional __ALLOCATION_TIMESTAMP__ __OPAQUE_DRIVER__ __RESULT_DRIVER__ __KIND__ __POOL__ __DEVICE__.

  local ns="$1"
  local claim="$2"
  local tmpl="$3"
  shift 3

  [[ -f "${tmpl}" ]] || { echo "ERROR: template not found: ${tmpl}"; return 1; }

  local patch
  patch="$(cat "${tmpl}")"

  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    patch="${patch//__${key}__/${val}}"
  done

  # Write to a temp file and validate the JSON before applying
  local tmp
  tmp="$(mktemp --suffix=.json)"
  printf '%s' "${patch}" > "${tmp}"

  if ! jq -e . "${tmp}" >/dev/null 2>&1; then
    echo "ERROR: rendered patch is not valid JSON:" >&2
    sed -n '1,200p' "${tmp}" >&2 || true
    rm -f "${tmp}"
    return 1
  fi

  # Patch the ResourceClaim status
  if ! kubectl -n "${ns}" patch resourceclaim "${claim}" \
    --type merge \
    --subresource=status \
    --patch-file="${tmp}" 2>&1; then
      echo "ERROR: kubectl patch failed for ${ns}/${claim}" >&2
      echo "Patch file:" >&2
      cat "${tmp}" >&2 || true
      rm -f "${tmp}"
      return 1
  fi

  # Remove temp file
  rm -f "${tmp}"
}

cleanup_imex_demo() {
  # -> RC labels:
  #         - e2e.nvidia.com/suite=cd-bindingconditions-rc
  # -> Pod labels:
  #         - e2e.nvidia.com/suite=cd-bindingconditions-pod / e2e.nvidia.com/suite: imex-channel-injection-cd
  # -> CD labels:
  #         - e2e.nvidia.com/suite=cd-bindingconditions-cd / e2e.nvidia.com/suite: imex-channel-injection-cd

  # Delete any test ResourceClaims created by the test across all NS (by label => e2e.nvidia.com/suite=cd-bindingconditions-rc)
  kubectl delete resourceclaim -A  -l e2e.nvidia.com/suite=cd-bindingconditions-rc --ignore-not-found --wait=false >/dev/null 2>&1 || true

  # Delete any test pods created by the test across all NS (by label => e2e.nvidia.com/suite=cd-bindingconditions-pod/imex-channel-injection-pod)
  kubectl delete pod -A  -l e2e.nvidia.com/suite=cd-bindingconditions-pod --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete pod -A  -l e2e.nvidia.com/suite=imex-channel-injection-pod --ignore-not-found --wait=false >/dev/null 2>&1 || true

  # Delete any test ComputeDomains created by the test across all NS (by label => e2e.nvidia.com/suite=cd-bindingconditions-cd/imex-channel-injection-cd)
  kubectl delete computedomains -A  -l e2e.nvidia.com/suite=cd-bindingconditions-cd --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete computedomains -A  -l e2e.nvidia.com/suite=imex-channel-injection-cd --ignore-not-found --wait=false >/dev/null 2>&1 || true


  # Clean nodes labels that may have been left behind
  kubectl label nodes --all resource.nvidia.com/computeDomain- >/dev/null 2>&1 || true

  # For safety, wait for specific known objects to be deleted
  kubectl wait --for=delete pod -A -l 'e2e.nvidia.com/suite=imex-channel-injection-pod' --timeout=60s
  kubectl wait --for=delete resourceclaim -A -l 'e2e.nvidia.com/suite=cd-bindingconditions-rc' --timeout=90s
  kubectl wait --for=delete computedomains -A -l 'e2e.nvidia.com/suite=cd-bindingconditions-cd' --timeout=60s
  
  return 0
}