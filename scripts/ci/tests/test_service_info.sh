#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRIPTS}/ci/read-service-info.sh"
mkdir -p "${WORK}/e"

echo "== read-service-info.sh"
cat > "${WORK}/e/terraform.tfvars" <<'TFVARS'
project_name = "acme"
service_name = "auth"   # a comment
service_type = "web"
tier         = "internal"
service_port = 1234 # trailing comment
TFVARS
out="$(bash "$R" "${WORK}/e" 2>/dev/null)"
check "reads the five values"                     bash -c "grep -qx 'PROJECT_NAME=acme' <<< \"$out\" && grep -qx 'SERVICE_NAME=auth' <<< \"$out\" && grep -qx 'SERVICE_TYPE=web' <<< \"$out\" && grep -qx 'SERVICE_TIER=internal' <<< \"$out\" && grep -qx 'SERVICE_PORT=1234' <<< \"$out\""
check "output is safe to append to GITHUB_ENV"    bash -c "! grep -vE '^[A-Z_]+=' <<< \"$out\""
# The blueprint's unset values, as a fixture: the real folder is configured in
# every service that clones this repository, so it cannot stand in for them.
mkdir -p "${WORK}/blueprint"
cat > "${WORK}/blueprint/terraform.tfvars" <<'TFVARS'
project_name = "CHANGE_ME"
aws_region   = "CHANGE_ME"
service_name = "CHANGE_ME"
service_type = "web"
tier         = "private"
service_port = 0 # CHANGE_ME
TFVARS
check "the shipped blueprint (unset) is refused"  bash -c "! bash '$R' '${WORK}/blueprint' >/dev/null 2>&1"
sed -i 's/service_port.*/service_port = 80/' "${WORK}/e/terraform.tfvars"
check "a privileged port is refused"              bash -c "! bash '$R' '${WORK}/e' >/dev/null 2>&1"
sed -i 's/service_port.*/service_port = 1234/; s/tier .*/tier = "edge"/' "${WORK}/e/terraform.tfvars"
check "an unknown tier is refused"                bash -c "! bash '$R' '${WORK}/e' >/dev/null 2>&1"
sed -i 's/project_name.*/project_name = "Bad Name"/' "${WORK}/e/terraform.tfvars"
check "an invalid project name is refused"        bash -c "! bash '$R' '${WORK}/e' >/dev/null 2>&1"
sed -i 's/project_name.*/project_name = "acme"/; /service_type/d; s/tier .*/tier = "private"/' "${WORK}/e/terraform.tfvars"
check "a missing key is refused"                  bash -c "! bash '$R' '${WORK}/e' >/dev/null 2>&1"
check "a missing file is refused"                 bash -c "! bash '$R' /nonexistent >/dev/null 2>&1"
finish
