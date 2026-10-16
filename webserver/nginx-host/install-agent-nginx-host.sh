#!/usr/bin/env bash
# Ubuntu 호스트 nginx용 Elastic Agent 사전 점검 + 설치 스크립트 (nginx 서버에서 root로 실행)
#
# 사용법:
#   sudo ./install-agent-nginx-host.sh --check-only
#   sudo ./install-agent-nginx-host.sh --token <Nginx Host Policy enrollment token>
#
#   --token 없이 실행하면 점검만 수행
set -uo pipefail

ELK_HOST="192.168.219.126"
FLEET_URL="http://${ELK_HOST}:8220"
ES_URL="http://${ELK_HOST}:9200"
VER="9.5.5"                  # docker-elk .env 의 ELASTIC_VERSION 과 일치시킬 것
LOG_DIR="/var/log/nginx"
ECS_LOG="${LOG_DIR}/ecs_access.log"
STATUS_URL="http://127.0.0.1:8080/nginx_status"
TOKEN=""
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)      TOKEN="$2"; shift 2 ;;
    --version)    VER="$2"; shift 2 ;;
    --status-url) STATUS_URL="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "root 권한으로 실행하세요 (sudo)."; exit 1; }

FAIL=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
ng()   { echo "  [FAIL] $*"; FAIL=1; }

echo "== 1. ELK 연결 =="
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ES_URL") || code=000
[[ "$code" == "401" || "$code" == "200" ]] && ok "Elasticsearch $ES_URL 응답 ($code)" || ng "Elasticsearch $ES_URL 응답 없음 ($code)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$FLEET_URL/api/status") || code=000
[[ "$code" == "200" ]] && ok "Fleet Server $FLEET_URL 응답 ($code)" || ng "Fleet Server $FLEET_URL 응답 없음 ($code)"

echo "== 2. nginx =="
if command -v nginx >/dev/null 2>&1; then
  ok "$(nginx -v 2>&1)"
  nginx -V 2>&1 | grep -q http_stub_status_module && ok "stub_status 모듈 포함" || ng "stub_status 모듈 없음"
  nginx -t >/dev/null 2>&1 && ok "nginx -t 통과" || ng "nginx -t 실패 — 'sudo nginx -t'로 오류 확인"
  if nginx -T 2>/dev/null | grep -q 'log_format ecs_combined'; then
    ok "ecs_combined 포맷 로드됨 (conf.d/ecs-logging.conf)"
  else
    warn "ecs_combined 포맷 없음 — 기본 combined 포맷을 쓴다면 정책 Access 경로를 access.log* 로 지정"
  fi
  # http 레벨 설정을 상속하지 않는 vhost(server 블록 안에 자체 access_log가 있는 경우) 탐지
  vh=$(grep -rln 'access_log' /etc/nginx/sites-enabled/ 2>/dev/null | xargs -r grep -L 'ecs_access.log' 2>/dev/null)
  [[ -z "$vh" ]] && ok "vhost별 access_log 상속 문제 없음" || warn "자체 access_log가 있는데 ecs_access.log가 없는 vhost: $(echo $vh)"
else
  ng "nginx 실행 파일 없음"
fi

echo "== 3. 로그 파일 =="
if [[ -f "$ECS_LOG" ]]; then
  sz=$(stat -c %s "$ECS_LOG")
  ok "ecs_access.log 존재 (${sz} bytes)"
  (( sz < 1024 )) && warn "1KB 미만 — filestream이 파일을 식별하지 못할 수 있음. 요청을 더 보낸 뒤 확인"
  last=$(tail -n1 "$ECS_LOG")
  [[ -n "$last" ]] && echo "         최근 라인: $last"
else
  warn "ecs_access.log 없음 (기본 포맷을 쓰는 경우는 정상)"
fi
[[ -f "$LOG_DIR/error.log" ]] && ok "error.log 존재" || warn "error.log 없음"

echo "== 4. stub_status =="
body=$(curl -s --max-time 5 "$STATUS_URL")
grep -q 'Active connections' <<<"$body" && ok "$STATUS_URL 정상" || ng "$STATUS_URL 응답 이상 — conf.d/nginx-status.conf 적용 여부와 포트 확인"

echo "== 5. 아키텍처 / 기존 설치 =="
case "$(uname -m)" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="arm64" ;;
  *) ng "지원하지 않는 아키텍처: $(uname -m)"; ARCH="" ;;
esac
[[ -n "$ARCH" ]] && ok "linux-$ARCH"
systemctl is-active --quiet elastic-agent 2>/dev/null && warn "elastic-agent가 이미 설치되어 실행 중 — 재설치하지 말고 Fleet에서 정책을 재할당"

echo
if [[ $FAIL -ne 0 ]]; then echo "점검 실패 항목을 해결한 뒤 다시 실행하세요."; exit 1; fi
if [[ $CHECK_ONLY -eq 1 || -z "$TOKEN" ]]; then echo "점검 완료 (설치는 --token 지정 시 수행)."; exit 0; fi

echo "== 6. Elastic Agent ${VER} 설치 =="
echo "  ※ 토큰이 'Nginx Host Policy'의 것인지 Fleet → Enrollment tokens 의 Policy 열에서 확인했는지 다시 확인하세요."
PKG="elastic-agent-${VER}-linux-${ARCH}"
WORK=$(mktemp -d)
cd "$WORK" || exit 1
curl -fL -O "https://artifacts.elastic.co/downloads/beats/elastic-agent/${PKG}.tar.gz" || { echo "다운로드 실패"; exit 1; }
curl -fsL -O "https://artifacts.elastic.co/downloads/beats/elastic-agent/${PKG}.tar.gz.sha512" \
  && sha512sum -c "${PKG}.tar.gz.sha512" || { echo "체크섬 검증 실패"; exit 1; }
tar xzf "${PKG}.tar.gz"
"./${PKG}/elastic-agent" install --non-interactive \
  --url="$FLEET_URL" --enrollment-token="$TOKEN" --insecure
echo
sleep 20
elastic-agent status --output=full | grep -iA3 nginx || echo "nginx 컴포넌트가 아직 보이지 않음 — 1~2분 뒤 재확인. 계속 없으면 Agent에 할당된 정책을 확인하세요."
