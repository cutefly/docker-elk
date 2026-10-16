#!/usr/bin/env bash
# Elastic Agent 사전 점검 + 설치 스크립트 (웹서버 호스트에서 root로 실행)
#
# 사용법:
#   sudo ./install-agent.sh --npm-data <NPM /data 호스트 경로> --npm-container <컨테이너명> \
#        [--token <enrollment token>] [--version 9.5.5] [--check-only]
#
#   --check-only : 점검만 수행하고 설치하지 않음
#   --token 없이 실행하면 점검만 수행
set -uo pipefail

ELK_HOST="192.168.219.126"
FLEET_URL="http://${ELK_HOST}:8220"
ES_URL="http://${ELK_HOST}:9200"
VER="9.5.5"            # docker-elk .env 의 ELASTIC_VERSION 과 일치시킬 것
NPM_DATA=""
NPM_CT=""
TOKEN=""
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --npm-data)      NPM_DATA="$2"; shift 2 ;;
    --npm-container) NPM_CT="$2"; shift 2 ;;
    --token)         TOKEN="$2"; shift 2 ;;
    --version)       VER="$2"; shift 2 ;;
    --check-only)    CHECK_ONLY=1; shift ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "root 권한으로 실행하세요 (sudo)."; exit 1; }
[[ -n "$NPM_DATA" && -n "$NPM_CT" ]] || { echo "--npm-data 와 --npm-container 는 필수입니다."; exit 2; }

FAIL=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
ng()   { echo "  [FAIL] $*"; FAIL=1; }

echo "== 1. ELK 연결 =="
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ES_URL") || code=000
[[ "$code" == "401" || "$code" == "200" ]] && ok "Elasticsearch $ES_URL 응답 ($code)" || ng "Elasticsearch $ES_URL 응답 없음 ($code)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$FLEET_URL/api/status") || code=000
[[ "$code" == "200" ]] && ok "Fleet Server $FLEET_URL 응답 ($code)" || ng "Fleet Server $FLEET_URL 응답 없음 ($code) — ELK에서 fleet-compose.yml 기동 여부 확인"

echo "== 2. NPM 로그 =="
if [[ -f "$NPM_DATA/logs/ecs_access.log" ]]; then
  ok "ecs_access.log 존재"
  last=$(tail -n1 "$NPM_DATA/logs/ecs_access.log")
  if [[ -n "$last" ]]; then
    echo "         최근 라인: $last"
    [[ "$last" =~ ^[^[:space:]]+\ [^[:space:]]+\ -\ .*\[.*\]\ \" ]] && ok "ecs_combined 포맷으로 보임" || warn "포맷 확인 필요"
  else
    warn "ecs_access.log 가 비어 있음 — proxy host에 요청을 보낸 뒤 다시 확인"
  fi
else
  ng "$NPM_DATA/logs/ecs_access.log 없음 — custom/server_proxy.conf 적용 여부 확인"
fi
ls "$NPM_DATA"/logs/*_error.log >/dev/null 2>&1 && ok "error log 존재: $(ls "$NPM_DATA"/logs/*_error.log | wc -l)개" || warn "*_error.log 없음"

echo "== 3. stub_status =="
body=$(curl -s --max-time 5 http://127.0.0.1:80/nginx_status)
if grep -q 'Active connections' <<<"$body"; then
  ok "http://127.0.0.1/nginx_status 정상"
else
  ng "nginx_status 응답 이상 — 403이면 custom/http.conf 의 allow 대역을 아래 게이트웨이로 조정"
  docker inspect "$NPM_CT" --format '{{range .NetworkSettings.Networks}}         gateway: {{.Gateway}}{{"\n"}}{{end}}' 2>/dev/null
fi

echo "== 4. 타임존 =="
host_tz=$(date +%z); ct_tz=$(docker exec "$NPM_CT" date +%z 2>/dev/null || echo "?")
echo "         host=$host_tz container=$ct_tz"
[[ "$host_tz" == "$ct_tz" ]] && ok "타임존 일치" || warn "타임존 불일치 — error log 시간이 어긋남 (설계 문서 이슈 ⑤)"

echo "== 5. 아키텍처 =="
case "$(uname -m)" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="arm64" ;;
  *) ng "지원하지 않는 아키텍처: $(uname -m)"; ARCH="" ;;
esac
[[ -n "$ARCH" ]] && ok "linux-$ARCH"
systemctl is-active --quiet elastic-agent 2>/dev/null && warn "elastic-agent 가 이미 설치되어 실행 중"

echo
if [[ $FAIL -ne 0 ]]; then echo "점검 실패 항목을 해결한 뒤 다시 실행하세요."; exit 1; fi
if [[ $CHECK_ONLY -eq 1 || -z "$TOKEN" ]]; then echo "점검 완료 (설치는 --token 지정 시 수행)."; exit 0; fi

echo "== 6. Elastic Agent ${VER} 설치 =="
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
elastic-agent status || true
echo "설치 완료. Kibana > Fleet > Agents 에서 Healthy 상태를 확인하세요."
