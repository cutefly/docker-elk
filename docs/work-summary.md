# 웹서버 로그 수집 작업 정리 (nginx 1차 → apache 확장 준비)

작성일: 2026-10-16 · 대상: docker-elk (ELASTIC_VERSION=9.5.5) · ELK 서버 192.168.219.126

이 문서는 2026-10-15~16에 진행한 작업의 결과와 현재 상태를 정리한 것이다. 이후 apache에 같은 방식을 적용하기 위한 **공통 작업 패턴**도 함께 정리했다. 세부 절차는 각 단계별 문서를 참고한다(7장 산출물 목록).

---

## 1. 목표와 원칙

| 원칙 | 적용 방식 |
|---|---|
| Elastic 제공 인덱스와 대시보드 사용 | Elastic Agent + Fleet + 공식 Integration(nginx, apache). 직접 grok을 작성하거나 대시보드를 만들지 않는다. |
| ECS 표준 준수, 다른 메트릭과 연계 | Integration 수집 파이프라인이 ECS로 변환한다. system·docker 메트릭과 `host.name`, `destination.domain`, `data_stream.namespace`로 연결한다. |
| compose 파일 미수정 | ELK는 `-f extensions/fleet/fleet-compose.yml`로 덧붙여 실행한다. NPM은 `custom/` 디렉터리와 `docker-compose.override.yml`을 사용한다. |
| 버전 독립 | 패키지는 `version: latest`로 받는다. 인덱스는 data stream 패턴(`logs-nginx.*`)으로 지정한다. Fleet 정책은 변수 키 이름을 하드코딩하지 않도록 UI에서 생성한다. 수집 로직 변경은 `@custom` 확장 지점에서만 한다. |
| nginx 먼저, apache는 이후 확장 | nginx(NPM, 호스트 nginx) 작업을 마친 뒤 같은 패턴을 apache에 적용한다(8장). |

## 2. 환경 구성

```
 사용자 ──▶ [NPM 서버 (Ubuntu)] ───────────▶ [nginx 서버 (Ubuntu)] ──▶ (백엔드)
             Nginx Proxy Manager 컨테이너       apt 설치 nginx
             Elastic Agent (Webserver Policy)    Elastic Agent (Nginx Host Policy)
                    │                                   │
                    └──────── :8220 정책 / :9200 데이터 ┘
                                     ▼
                     [ELK 서버 192.168.219.126 (Docker)]
                      elasticsearch · kibana · logstash · fleet-server
```

| 구성요소 | 내용 |
|---|---|
| ELK | docker-elk, 단일 노드. Fleet Server는 `extensions/fleet`로 기동 |
| NPM 서버 | Ubuntu + Docker, `jc21/nginx-proxy-manager`. 외부 트래픽의 진입점 |
| nginx 서버 | NPM과 **다른** Ubuntu 서버, apt로 설치한 nginx. NPM 뒤의 리버스 프록시 체인 |
| 네트워크 | 모든 서버가 같은 네트워크에 있으며 웹서버에서 ELK의 8220·9200에 접속 가능 |
| apache | 다음 단계 대상 (서버 위치 미정) |

## 3. 수집 데이터 구조

| 출처 | data stream | 주요 ECS 필드 | 제공 대시보드 |
|---|---|---|---|
| nginx access | `logs-nginx.access-<ns>` | `destination.domain`, `source.ip`, `source.geo.*`, `http.request.method`, `http.response.status_code`, `url.original`, `user_agent.*` | `[Logs Nginx] Access and error logs` |
| nginx error | `logs-nginx.error-<ns>` | `log.level`, `message` | 위와 같음 |
| nginx stub_status | `metrics-nginx.stubstatus-<ns>` | `nginx.stubstatus.*` | `[Metrics Nginx] Overview` |
| 호스트 | `metrics-system.*`, `logs-system.*` | `host.*`, `system.*` | `[Metrics System] Host overview` |
| NPM 컨테이너 | `metrics-docker.*` | `container.*`, `docker.*` | `[Metrics Docker] Overview` |
| (예정) apache | `logs-apache.access/error`, `metrics-apache.status` | nginx와 같은 ECS 필드 | `[Logs Apache] ...`, `[Metrics Apache] Overview` |

데이터를 연결해 보는 기준 키는 다음과 같다.

| 키 | 용도 |
|---|---|
| `host.name` | 같은 서버의 로그와 메트릭 연결 |
| `destination.domain` | 서비스(도메인)별 분석. NPM과 nginx 양쪽에 같은 값이 기록된다. |
| `tags` | 같은 dataset 안에서 출처 구분 (`nginx-npm`, `nginx-host`) |
| `data_stream.namespace` | 환경 구분. 단일 환경이면 `default`, 확장할 계획이 있으면 `prod` 등 |

---

## 4. ELK 서버 작업 내역

`kibana/config/kibana.yml`만 수정했다(git 기준 미커밋 변경). `docker-compose.yml`은 변경하지 않았다.

| 항목 | 내용 | 이유 |
|---|---|---|
| 암호화 키 3종 | `xpack.security`, `encryptedSavedObjects`, `reporting` 키 설정 | 키가 없으면 Fleet이 동작하지 않는다. **설정 후 변경 금지** |
| Fleet Server 주소 | `http://192.168.219.126:8220` | 원격 Agent는 Docker 내부 이름(`fleet-server`)을 해석하지 못한다. |
| Fleet 기본 output | `http://192.168.219.126:9200` | 원격 Agent는 Docker 내부 이름(`elasticsearch`)을 해석하지 못한다. |
| 사전 설치 패키지 | `nginx`, `apache` 추가 (`version: latest`) | Integration 자산(템플릿, 파이프라인, 대시보드)을 미리 설치 |

기동 명령은 다음과 같다.

```bash
docker compose -f docker-compose.yml -f extensions/fleet/fleet-compose.yml up -d
```

## 5. nginx 작업 내역

### 5-1. NPM 서버

| 단계 | 내용 | 상태 |
|---|---|---|
| 로그 포맷 | `custom/http_top.conf`에 `ecs_combined` (`$host` + combined) 정의. `custom/server_proxy.conf`로 모든 proxy host에 `/data/logs/ecs_access.log` 추가 기록. NPM 자체 로그는 유지 | **완료** |
| 파싱 검증 | `simulate-access.txt`의 `_simulate` 결과 `destination.domain` 등 정상 파싱 | **완료** |
| stub_status | `custom/http.conf`: `:80`, server_name `127.0.0.1`, Docker gateway 대역 허용 | 적용 완료 |
| 타임존 | `docker-compose.override.yml` (`TZ` + `/etc/localtime` 마운트) | 절차 제공, **적용 여부 미확인** |
| Agent 설치 | `install-agent.sh`로 설치, Kibana에서 Healthy | **완료** |
| Fleet 정책 | `Webserver Policy`가 **생성되지 않은 상태에서** 다른 정책의 토큰으로 등록되어 nginx 수집이 빠짐 | 조치 방법 제공(정책 생성 → nginx·docker Integration 추가 → Agent 재할당), **결과 미확인** |
| 수집 검증 | `verify-ingest.txt` 4단계 0건. 원인은 위의 정책 누락 | **재검증 필요** |

### 5-2. nginx 서버 (NPM 뒤의 호스트 nginx)

| 단계 | 내용 | 상태 |
|---|---|---|
| 로그 포맷 | `/etc/nginx/conf.d/ecs-logging.conf`: NPM과 같은 `ecs_combined` 포맷, `/var/log/nginx/ecs_access.log` | 파일 제공 |
| 실제 사용자 IP | `conf.d/real-ip.conf`: `set_real_ip_from <NPM 서버 IP>`, `X-Forwarded-For`, `real_ip_recursive on` | 파일 제공 |
| stub_status | `conf.d/nginx-status.conf`: `127.0.0.1:8080/nginx_status` | **404 발생, 진단 중** |
| Fleet 정책 | 새 정책 `Nginx Host Policy` (system + nginx, tags `nginx-host`) | 절차 제공 |
| Agent 설치 | `install-agent-nginx-host.sh` (점검 + 설치) | 스크립트 제공 |

`/nginx_status` 404의 가능한 원인은 확인된 순서가 아니라 의심되는 순서로 다음과 같다.

1. Integration Hosts가 NPM 설정값(`:80`)으로 남아 있어 기본 사이트가 응답함
2. conf.d 파일이 적용되지 않음
3. 8080 포트 충돌
4. 경로 오타

진단 명령은 `nginx-host-procedure.md`의 문제 해결 항목에 있다.

---

## 6. 공통 작업 패턴 (apache에도 적용)

nginx 작업으로 확인한 표준 절차다. 웹서버 종류와 관계없이 이 순서를 따른다.

| # | 단계 | 확인 기준 | nginx 적용 결과 |
|---|---|---|---|
| P1 | **로그 포맷을 Integration 호환 포맷으로 맞춤.** 기존 로그는 유지하고 수집용 로그(`ecs_access.log`)를 추가한다. vhost를 구분하려면 도메인을 앞에 붙인다. | `_simulate`에서 `error.message` 없음 | `ecs_combined` 통과 |
| P2 | **vhost별 로그 지시어 상속 확인.** vhost에 자체 로그 지시어가 있으면 전역 설정을 이어받지 않는다. | 모든 vhost의 요청이 `ecs_access.log`에 기록됨 | 점검 스크립트로 탐지 |
| P3 | **프록시 뒤라면 실제 사용자 IP 복원.** 신뢰 대상은 앞단 프록시 IP 하나로만 제한한다. | 외부 접속 IP가 기록되고, 위조한 XFF 값은 무시됨 | `real-ip.conf` |
| P4 | **상태 엔드포인트를 loopback 전용으로 열기** (전용 포트, 외부 미노출) | `curl 127.0.0.1:<port>/<path>` 정상 응답 | `:8080/nginx_status` |
| P5 | **타임존 일치.** error log에는 타임존이 없다. 컨테이너라면 호스트와 맞춘다. | 미래 시각(+9h) 문서 0건 | NPM은 override 파일 사용 |
| P6 | **서버 유형별 Fleet 정책 생성 (토큰 발급보다 먼저).** 로그 경로가 다른 서버를 한 정책에 묶지 않는다. tags로 출처를 구분한다. | 정책에 Integration이 연결되어 있음 | NPM에서 정책 누락 문제 발생 |
| P7 | **Agent 설치** (점검 스크립트 → 해당 정책의 토큰으로 설치) | `elastic-agent status --output=full`에 해당 Integration이 HEALTHY | 스크립트 2종 |
| P8 | **수집 검증** (data stream, 파싱 실패 0건, ECS 필드, 시간 정합, `host.name` 일치) | `verify-ingest.txt` 1~7단계 | NPM 재검증 대기 |
| P9 | **정책 백업** (`GET kbn:/api/fleet/agent_policies/<id>/full` → `docs/`) | JSON 파일 보관 | 미실시 |

---

## 7. 산출물 목록

| 경로 | 용도 |
|---|---|
| `kibana/config/kibana.yml` | Fleet 외부 주소, 암호화 키, nginx·apache 패키지 (수정) |
| `docs/webserver-logging-plan.md` | 전체 설계 (아키텍처, NPM 이슈 ①~⑥, Phase 0~7) |
| `docs/phase3-fleet-agent.md` | Fleet 정책 생성 및 Agent 설치 가이드 (NPM) |
| `docs/npm-timezone.md` | NPM 타임존 일치 절차 |
| `docs/nginx-host-procedure.md` | 호스트 nginx 절차 (실제 IP 부록, 404 문제 해결 포함) |
| `docs/work-summary.md` | 이 문서 |
| `webserver/install-agent.sh` | NPM 서버용 점검·설치 스크립트 |
| `webserver/nginx-proxy-manager/custom/{http_top,server_proxy,http}.conf` | NPM 커스텀 설정 |
| `webserver/nginx-proxy-manager/docker-compose.override.yml` | NPM 타임존 override |
| `webserver/nginx-proxy-manager/simulate-access.txt` | 로그 포맷 파싱 테스트 (Dev Tools) |
| `webserver/nginx-proxy-manager/verify-ingest.txt` | 수집 검증 쿼리 1~7단계 (Dev Tools, 공통 사용) |
| `webserver/nginx-proxy-manager/diagnose-access.md` | access 로그 미수집 진단 절차 |
| `webserver/nginx-host/conf.d/{ecs-logging,real-ip,nginx-status}.conf` | 호스트 nginx 설정 |
| `webserver/nginx-host/install-agent-nginx-host.sh` | 호스트 nginx용 점검·설치 스크립트 |

## 8. 문제 사례와 교훈

| 사례 | 원인 | 교훈 / 재발 방지 |
|---|---|---|
| NPM 로그를 Integration이 파싱하지 못함 | NPM 자체 `proxy` 포맷 | P1: 수집용 로그를 별도로 추가하고 `_simulate`로 먼저 검증 |
| 원격 Agent가 접속하지 못할 위험 | kibana.yml 기본값이 Docker 내부 DNS 이름 | Fleet 주소와 output은 외부 IP로 설정 |
| Agent는 Healthy인데 nginx 데이터 0건 | 정책을 만들기 전에 다른 정책의 토큰으로 등록 | P6: 정책 생성 → Integration 추가 → 토큰 발급 순서. 설치 후 `status --output=full`로 Integration이 있는지 확인 |
| (주의) 새 로그 파일 미수집 가능성 | filestream이 파일 앞 1KB로 파일을 식별 (기본 동작) | 파일이 1KB를 넘었는지 확인. 필요하면 트래픽을 만들어 확인 |
| NPM 뒤 nginx의 IP가 모두 NPM IP | 리버스 프록시 체인 | P3: realip 설정, 신뢰 대상은 NPM IP 하나로 제한 |
| 같은 요청이 두 번 기록됨 | NPM과 nginx가 각각 기록 | 합산하지 말 것. 외부 트래픽은 NPM 기준, 백엔드는 nginx 기준으로 보고 `host.name`/tags로 구분 |
| Claude 작업 환경에서 ELK 직접 조회 불가 | 작업 환경 네트워크 allowlist가 192.168.219.126을 차단 (우회하지 않음) | 검증은 사용자가 Dev Tools에서 실행하고 결과를 전달하는 방식 |

---

## 9. apache 적용 계획 (공통 패턴 기준)

전제: Ubuntu에 apt로 설치한 apache2. 컨테이너라면 NPM 절차처럼 로그 볼륨 경로와 타임존(P5)을 추가로 점검한다. 아래 설정은 초안이며 **P1의 `_simulate` 검증을 통과한 뒤 적용**한다.

| 패턴 | apache 적용 내용 |
|---|---|
| P1 로그 포맷 | Ubuntu에 기본 정의된 `vhost_combined`(`%v:%p` 접두어 + combined)를 기반으로 한다. Integration 기본 경로에 `other_vhosts_access.log`가 포함되어 있어 이 포맷 계열을 지원하는 것으로 보이지만, `_simulate`로 확인한다. 프록시 뒤라면 `%h` 대신 `%a`를 쓴다(P3). |
| P2 상속 | `<VirtualHost>`에 자체 `CustomLog`가 있으면 전역 `CustomLog`를 이어받지 않는다. 해당 vhost에 직접 추가한다. |
| P3 실제 IP | `mod_remoteip`: `RemoteIPHeader X-Forwarded-For`, `RemoteIPInternalProxy <NPM 서버 IP>`. 로그 포맷은 `%a` 사용 |
| P4 상태 | Ubuntu 기본 `mods-enabled/status.conf`(`/server-status`, `Require local`)를 사용한다. 필요하면 전용 포트(`Listen 127.0.0.1:8080`)의 VirtualHost로 분리한다. |
| P5 타임존 | 호스트에 설치하면 영향 없음. error log에는 타임존이 없으므로 컨테이너라면 맞춘다. |
| P6 정책 | 다른 서버라면 `Apache Host Policy` (system + apache, tags `apache-host`) |
| P7 설치 | `install-agent-nginx-host.sh`를 apache용으로 바꾼 스크립트 사용 (점검 항목: `apache2ctl -M`, `configtest`, `/server-status`) |
| P8 검증 | `verify-ingest.txt`의 `nginx`를 `apache`로 바꿔 실행. 대시보드는 `[Logs Apache] Access and error logs`, `[Metrics Apache] Overview` |

설정 초안 (`/etc/apache2/conf-available/ecs-logging.conf` → `a2enconf ecs-logging`):

```apache
# NPM 뒤에 있는 경우: 실제 사용자 IP 복원 (a2enmod remoteip)
<IfModule remoteip_module>
    RemoteIPHeader X-Forwarded-For
    RemoteIPInternalProxy <NPM_SERVER_IP>
</IfModule>

# vhost_combined 기반, %h → %a (remoteip 적용 후 실제 IP)
LogFormat "%v:%p %a %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" ecs_vhost_combined
CustomLog ${APACHE_LOG_DIR}/ecs_access.log ecs_vhost_combined
```

Fleet의 apache Integration 입력값은 다음과 같다.

- Access 경로: `/var/log/apache2/ecs_access.log*`
- Error 경로: `/var/log/apache2/error.log*`
- Status Hosts: `http://127.0.0.1` (전용 포트로 분리했다면 `:8080`)
- Status path: `/server-status`

nginx와 apache가 같은 ECS 필드로 저장되므로 `event.dataset : (nginx.access or apache.access)`로 함께 분석할 수 있다.

---

## 10. 남은 작업

| # | 작업 | 담당 / 비고 |
|---|---|---|
| 1 | NPM: `Webserver Policy` 생성 → Agent 재할당 → `verify-ingest.txt` 재검증 | 사용자 실행, 결과 전달 |
| 2 | NPM: 타임존 override 적용 여부 확인 | 사용자 |
| 3 | nginx 서버: `/nginx_status` 404 진단 (`curl -i :8080`, `nginx -T`, `ss -ltnp` 결과 전달) | 사용자 → 원인 판정 |
| 4 | nginx 서버: real-ip 적용과 위조 시험, `Nginx Host Policy` 생성, Agent 설치, 검증 | 사용자 |
| 5 | 정책 JSON 백업 (P9) | 사용자 |
| 6 | apache: 서버 위치와 형태 확인 → 설정 파일과 스크립트 작성 → P1 `_simulate` 검증부터 진행 | 다음 단계 |
| 7 | 운영 보안: `.env` 기본 비밀번호 변경, Fleet 서비스 토큰 사용, TLS 적용(`--insecure` 제거) 검토 | 운영 전 |
| 8 | 저장소 관리: `kibana.yml`에 암호화 키가 들어 있으므로 원격 저장소에 push하지 않거나 별도로 관리. 이전 작업의 빈 폴더(`.local-work/`, `apache access log/`) 정리 여부 결정 | 사용자 결정 |
