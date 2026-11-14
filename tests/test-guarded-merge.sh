#!/usr/bin/env bash
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/guarded-merge.sh"
DIR="$(mktemp -d)"
trap 'rm -rf -- "$DIR"' EXIT
cat > "$DIR/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case_name=${TEST_CASE:-happy_nabor}
str="$*"
base=$(printf 'a%.0s' {1..40})
head=$(printf 'b%.0s' {1..40})
if [[ "$str" == *'/branches/main'* ]]; then echo "$base"; exit 0; fi
if [[ "$str" == *'/pulls/'* && "$str" != *'/files?'* && "$str" != *'/merge'* ]]; then
  draft=false; [[ "$case_name" == draft ]] && draft=true
  printf '{"state":"open","draft":%s,"mergeable":true,"mergeable_state":"clean","head":{"sha":"%s"},"base":{"ref":"main","sha":"%s"}}\n' "$draft" "$head" "$base"
  exit 0
fi
if [[ "$str" == *'/files?'* ]]; then
  if [[ "$case_name" == *os_no_sonar* ]]; then echo 'README.md'; else echo 'apps/platform/pom.xml'; fi
  exit 0
fi
if [[ "$str" == *'/check-runs?'* ]]; then
  python3 - <<'PY'
import os,json
case=os.getenv('TEST_CASE','happy_nabor')
base=['Format, lint, typecheck, test, build and OSV','scan','SonarCloud Code Analysis'] if 'nabor' in case or case=='draft' else ['platform-build','web-build','marketing-build','mobile-typecheck','semgrep (the code itself)','osv (known vulnerable dependencies)','gitleaks (credentials in the history)']
if 'os' in case and not case.endswith('no_sonar'):
    base+=['scan','SonarCloud Code Analysis']
if case == 'missing_nabor': base.remove('SonarCloud Code Analysis')
if case == 'missing_os_sonar': base.remove('SonarCloud Code Analysis')
checks=[{'head_sha':'b'*40,'name':x,'status':'completed','conclusion':'success'} for x in base]
if case=='pending_nabor':
    checks[1]['status']='in_progress';checks[1]['conclusion']=None
print(json.dumps({'total_count':len(checks),'check_runs':checks}))
PY
  exit 0
fi
if [[ "$str" == *'/status'* ]]; then echo '{"statuses":[],"state":"pending"}'; exit 0; fi
if [[ "$str" == *'/merge'* ]]; then echo '{"merged":true,"sha":"fedcba9876543210fedcba9876543210fedcba98"}'; exit 0; fi
echo "Unexpected mocked API: $str" >&2; exit 7
MOCK
chmod +x "$DIR/gh"
export PATH="$DIR:$PATH"
run_case() {
  local case=$1 expected=$2 repo=$3
  set +e
  TEST_CASE="$case" bash "$SCRIPT" --repo "samkomane008/$repo" --pr 234 --dry-run > "$DIR/out" 2>&1
  code=$?
  set -e
  if [[ "$expected" == pass && "$code" -ne 0 ]] || [[ "$expected" == fail && "$code" -eq 0 ]]; then
    echo "FAIL: $case expected=$expected result=$code"; cat "$DIR/out"; exit 1
  fi
  echo "PASS: $case ($expected)"
}
run_case happy_nabor pass nabor
run_case missing_nabor fail nabor
run_case pending_nabor fail nabor
run_case draft fail nabor
run_case happy_os pass samloryx-os
run_case happy_os_no_sonar pass samloryx-os
run_case missing_os_sonar fail samloryx-os
set +e
TEST_CASE=happy_nabor bash "$SCRIPT" --repo samkomane008/nabor --pr 234 --apply > "$DIR/apply" 2>&1
code=$?
set -e
[[ "$code" -eq 0 ]] && grep -q 'MERGED:' "$DIR/apply" && echo 'PASS: guarded apply exact-head merge' || { cat "$DIR/apply"; exit 1; }
