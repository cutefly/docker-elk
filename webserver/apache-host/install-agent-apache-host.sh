#!/usr/bin/env bash
# Ubuntu 호스트 apache2용 Elastic Agent 사전 점검 + 설치 스크립트 (apache 서버에서 root로 실행)
#
# 사용법:
#   sudo ./install-agent-apache-host.sh --check-only
#   sudo ./install-agent-apache-host.sh --token <Apache Host Policy enrollment token>
#
#   --token 없이 실행하면 점검만 수행
set -uo pipefail

ELK_HOST="192.168.219.126"
FLEET_URL="http://${ELK_HOST}:8220"
ES_URL="http://${ELK_HOST}:9200"
VER="9.5.5"                  # docker-elk .env 의 ELASTIC_VERSION 과 일치시킬 것
LOG_DIR="/var/log/apache2"
ECS_LOG="${LOG_DIR}/ecs_access.log"
STATUS_URL="http://127.0.0.1:8080/server-status"
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

echo "== 2. apache2 =="
if command -v apache2ctl >/dev/null 2>&1; then
  av=$(apache2 -v 2>/dev/null | sed -n 's#^Server version: Apache/\([0-9.]*\).*#\1#p')
  ok "Apache ${av:-unknown}"
  if [[ -n "$av" && "$(printf '%s\n' 2.4.19 "$av" | sort -V | head -n1)" == "2.4.19" ]]; then
    ok "GlobalLog 지원 (2.4.19+)"
  else
    warn "GlobalLog 미지원 버전 — ecs-logging.conf 의 GlobalLog 대신 vhost마다 CustomLog 를 넣어야 함"
  fi
  mods=$(apache2ctl -M 2>/dev/null)
  for m in status_module remoteip_module logio_module setenvif_module; do
    grep -q "$m" <<<"$mods" && ok "$m 로드됨" || ng "$m 없음 — sudo a2enmod ${m%_module}"
  done
  apache2ctl configtest >/dev/null 2>&1 && ok "configtest 통과" || ng "configtest 실패 — 'sudo apache2ctl configtest'로 오류 확인"
  for c in ecs-logging ecs-real-ip ecs-server-status; do
    [[ -e /etc/apache2/conf-enabled/$c.conf ]] && ok "$c.conf 활성화됨" || warn "$c.conf 비활성 — sudo a2enconf $c"
  done
  if grep -q '<NPM_SERVER_IP>' /etc/apache2/conf-available/ecs-real-ip.conf 2>/dev/null; then
    ng "ecs-real-ip.conf 의 <NPM_SERVER_IP> 가 그대로임 — NPM 서버 LAN IP로 바꾸세요"
  fi
  grep -qE 'RemoteIP(Internal|Trusted)Proxy[[:space:]]+(0\.0\.0\.0/0|::/0)' /etc/apache2/conf-available/ecs-real-ip.conf 2>/dev/null \
    && ng "RemoteIP 신뢰 대상이 전체 대역 — IP 위조 가능"
  # 8080 포트 점유 프로세스 확인 (apache 이외의 프로세스가 쓰고 있으면 충돌)
  p8080=$(ss -ltnpH 'sport = :8080' 2>/dev/null)
  if [[ -n "$p8080" ]] && ! grep -q apache2 <<<"$p8080"; then
    warn "8080을 apache가 아닌 프로세스가 사용 중: $p8080 — ecs-server-status.conf 포트 변경"
  fi
else
  ng "apache2ctl 없음 (apt install apache2 여부 확인)"
fi

echo "== 3. 로그 파일 =="
if [[ -f "$ECS_LOG" ]]; then
  sz=$(stat -c %s "$ECS_LOG")
  ok "ecs_access.log 존재 (${sz} bytes)"
  (( sz < 1024 )) && warn "1KB 미만 — filestream이 파일을 식별하지 못할 수 있음. 요청을 더 보낸 뒤 확인"
  last=$(tail -n1 "$ECS_LOG")
  [[ -n "$last" ]] && echo "         최근 라인: $last"
  grep -q '/server-status' <(tail -n 200 "$ECS_LOG") && warn "server-status 요청이 기록됨 — ecs_nolog 제외 설정 확인"
else
  warn "ecs_access.log 없음 — a2enconf ecs-logging 후 reload, 요청을 보낸 뒤 확인"
fi
[[ -f "$LOG_DIR/error.log" ]] && ok "error.log 존재" || warn "error.log 없음"

echo "== 4. server-status =="
body=$(curl -s --max-time 5 "${STATUS_URL}?auto")
if grep -q 'BusyWorkers' <<<"$body"; then
  ok "$STATUS_URL 정상"
  grep -q 'Total Accesses' <<<"$body" || warn "Total Accesses 없음 — ExtendedStatus On 확인"
else
  ng "$STATUS_URL 응답 이상 — a2enmod status, a2enconf ecs-server-status, 포트 확인 (curl -i ${STATUS_URL}?auto)"
fi

echo "== 5. 아키텍처 / 기존 설치 =="
case "$(uname -m)" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="arm64" ;;
  *) ng "지원하지 않는 아키텍처: $(uname -m)"; ARCH="" ;;
esac
[[ -n "$ARCH" ]] && ok "linux-$ARCH"
timedatectl 2>/dev/null | grep -q 'Time zone' && ok "$(timedatectl | grep 'Time zone' | xargs)"
systemctl is-active --quiet elastic-agent 2>/dev/null && warn "elastic-agent가 이미 설치되어 실행 중 — 재설치하지 말고 Fleet에서 정책을 재할당"

echo
if [[ $FAIL -ne 0 ]]; then echo "점검 실패 항목을 해결한 뒤 다시 실행하세요."; exit 1; fi
if [[ $CHECK_ONLY -eq 1 || -z "$TOKEN" ]]; then echo "점검 완료 (설치는 --token 지정 시 수행)."; exit 0; fi

echo "== 6. Elastic Agent ${VER} 설치 =="
echo "  ※ 토큰이 'Apache Host Policy'의 것인지 Fleet → Enrollment tokens 의 Policy 열에서 확인했는지 다시 확인하세요."
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
elastic-agent status --output=full | grep -iA3 apache || echo "apache 컴포넌트가 아직 보이지 않음 — 1~2분 뒤 재확인. 계속 없으면 Agent에 할당된 정책을 확인하세요."
