# 웹서버 로그 수집 요구사항 요약

기준일: 2026-10-17 · 대상: docker-elk (ELASTIC_VERSION=9.5.5) · ELK 서버 192.168.219.126
세부 내역은 `docs/work-summary.md`, 단계별 절차는 각 절차 문서를 참고한다.

## 1. 요구사항과 반영 방식

### 1-1. 기본 요구사항 (프로젝트 지침)

| # | 요구사항 | 반영 방식 | 상태 |
|---|---|---|---|
| R1 | Elastic이 제공하는 인덱스와 대시보드로 웹서버 로그를 분석한다 | Elastic Agent + Fleet + 공식 Integration(nginx, apache). ECS 필드로 저장한다. grok과 대시보드를 직접 만들지 않는다 | 설계 완료, 수집 검증 진행 중 |
| R2 | apache와 nginx를 모두 지원한다. 필요하면 웹서버 로그 포맷을 수정한다 | 기존 로그는 그대로 두고 Integration 호환 수집용 로그(`ecs_access.log`)를 추가한다. 도메인 접두어를 붙여 vhost를 구분한다 | nginx·apache 포맷 파싱 검증 통과 |
| R3 | nginx로 1차 작업을 한 뒤 apache로 확장한다 | nginx 작업에서 공통 패턴 P1~P9를 정리하고, 같은 순서를 apache에 적용한다 | nginx 진행 중, apache 파일 작성 완료 |
| R4 | docker compose 파일은 되도록 수정하지 않고 config 파일만 추가·수정한다 | ELK는 `kibana.yml`만 수정하고 `-f extensions/fleet/fleet-compose.yml`로 Fleet을 덧붙여 실행한다. NPM은 `custom/*.conf`와 `docker-compose.override.yml`, 호스트 웹서버는 `conf.d/`·`conf-available/`을 사용한다 | 준수 |
| R5 | 버전 특성에 영향을 받지 않게 한다 | 패키지는 `version: latest`, 인덱스는 data stream 패턴(`logs-nginx.*`)으로 지정한다. 정책은 UI에서 생성한다. 수집 로직 변경은 `@custom` 확장 지점에서만 한다. 업그레이드 후에는 `_simulate`로 다시 검증한다 | 준수 |

### 1-2. 작업 중 확정된 요구사항

| # | 요구사항 | 반영 방식 | 상태 |
|---|---|---|---|
| R6 | ECS 기준으로 다른 메트릭과 연계한다 | system·docker Integration을 함께 수집한다. `host.name`, `destination.domain`, `tags`, `data_stream.namespace`로 연결한다 | 설계 완료 |
| R7 | NPM(Nginx Proxy Manager) 컨테이너 로그를 수집한다 | NPM 자체 `proxy` 포맷은 파싱할 수 없다. 그래서 `ecs_combined` 로그를 따로 추가하고, stub_status와 타임존을 맞춘다 | 포맷 완료, 정책 재구성 후 재검증 필요 |
| R8 | NPM 뒤의 호스트 nginx 로그를 수집한다 | `conf.d` 파일 3개, `Nginx Host Policy`, 점검·설치 스크립트를 사용한다 | 파일 제공, `/nginx_status` 404 진단 중 |
| R9 | NPM 뒤의 호스트 apache2 로그를 수집한다 (별도 Ubuntu, apt 설치) | `conf-available` 파일 3개를 쓴다. vhost 상속 문제는 `GlobalLog`로 해결한다. `Apache Host Policy`와 점검·설치 스크립트를 사용한다 | P1 통과(패키지 3.0.2), 서버 적용 대기 |
| R10 | 프록시 뒤에서도 실제 사용자 IP를 기록한다 | nginx는 `realip`, apache는 `mod_remoteip`를 쓴다. 신뢰 대상은 NPM 서버 IP 하나로 제한한다 | 파일 제공, 위조 시험 대기 |
| R11 | 응답시간을 수집한다 | 로그 끝에 접미어(`rt=`, `urt=`, apache는 `rt=%D`)를 붙인다. `@custom` 파이프라인이 이를 `event.duration`과 `webserver.upstream_duration`(ns)으로 변환한다 | 설계·명령 제공, `_simulate` 대기 |

## 2. 구성 요약

```
사용자 ─▶ NPM 서버 (컨테이너) ─┬─▶ nginx 서버 (apt)  ─▶ 백엔드
          Webserver Policy     │   Nginx Host Policy
                               └─▶ apache 서버 (apt) ─▶ 백엔드
                                   Apache Host Policy
           각 서버의 Elastic Agent ──(:8220 정책 / :9200 데이터)──▶ ELK 192.168.219.126
```

| 출처 | data stream | 구분 태그 | 제공 대시보드 |
|---|---|---|---|
| NPM | `logs-nginx.access/error`, `metrics-nginx.stubstatus`, `metrics-docker.*` | `nginx-npm` | `[Logs Nginx]`, `[Metrics Nginx]`, `[Metrics Docker]` |
| 호스트 nginx | `logs-nginx.access/error`, `metrics-nginx.stubstatus` | `nginx-host` | `[Logs Nginx]`, `[Metrics Nginx]` |
| 호스트 apache | `logs-apache.access/error`, `metrics-apache.status` | `apache-host` | `[Logs Apache]`, `[Metrics Apache]` |
| 모든 서버 | `metrics-system.*`, `logs-system.*` | — | `[Metrics System] Host overview` |

같은 요청이 NPM과 백엔드 웹서버에 두 번 기록되므로 두 쪽을 합산하지 않는다. 외부 트래픽은 NPM 기준, 백엔드 처리는 nginx·apache 기준으로 보고 `tags`나 `host.name`으로 구분한다.

## 3. 공통 작업 패턴 (P1~P9)

| # | 단계 | 핵심 |
|---|---|---|
| P1 | 로그 포맷 | 수집용 로그를 추가하고, 적용 전에 `_simulate`로 파싱을 확인한다 |
| P2 | vhost 상속 | vhost별 로그 지시어가 전역 설정을 덮어쓰는지 확인한다. apache는 `GlobalLog`를 쓴다 |
| P3 | 실제 IP | 프록시 뒤라면 복원한다. 신뢰 대상은 프록시 IP 하나로만 둔다 |
| P4 | 상태 엔드포인트 | `127.0.0.1:8080` 전용 포트로만 연다 |
| P5 | 타임존 | 컨테이너는 호스트와 맞춘다. error log에는 타임존이 없다 |
| P6 | Fleet 정책 | 서버 유형별로 만든다. **정책을 먼저 만든 뒤 토큰을 발급한다** |
| P7 | Agent 설치 | 점검 스크립트를 실행한 뒤, 해당 정책의 토큰으로 설치한다 |
| P8 | 수집 검증 | `verify-ingest.txt`로 data stream, 파싱 실패 0건, ECS 필드, 시간, `host.name`을 확인한다 |
| P9 | 정책 백업 | Fleet API로 정책 JSON을 받아 `docs/`에 보관한다 |

## 4. 진행 현황

| 대상 | 완료 | 남은 일 |
|---|---|---|
| ELK | `kibana.yml`(암호화 키, Fleet 외부 주소, nginx·apache 패키지), Fleet Server 기동 | 운영 보안(비밀번호, 서비스 토큰, TLS) |
| NPM | 로그 포맷과 파싱 검증, stub_status, Agent 설치 | `Webserver Policy` 생성 → 재할당 → 재검증, 타임존 적용 확인 |
| 호스트 nginx | 설정 파일과 스크립트 제공 | `/nginx_status` 404 진단, real-ip 위조 시험, 정책·Agent·검증 |
| 호스트 apache | 설정 파일, 스크립트, 검증 쿼리 제공. P1 통과 | `--check-only` → 설정 적용 → 정책·Agent·검증 |
| 응답시간 | 매핑, `@custom` 파이프라인, `_simulate`, 절차 제공 | `_simulate` 결과 확인 → Fleet 태그 추가 → 로그 포맷 변경 |
| 공통 | — | 정책 JSON 백업(P9), `kibana.yml` 암호화 키 저장소 관리, 빈 폴더 정리 결정 |

## 5. 주요 결정과 이유

| 결정 | 이유 |
|---|---|
| Logstash grok 대신 Agent + Integration 사용 | ECS 매핑과 대시보드가 패키지에 들어 있다. Elastic이 현재 권장하는 방식이다 |
| 기존 로그는 두고 `ecs_access.log`를 추가 | NPM UI와 기존 운영 로그에 영향을 주지 않는다 |
| Fleet 주소와 output을 외부 IP로 설정 | 원격 Agent는 Docker 내부 DNS 이름을 해석하지 못한다 |
| 서버마다 별도 정책 사용 | 정책 하나는 소속 Agent 모두에 같은 로그 경로를 내려보낸다 |
| 응답시간은 로그 끝 접미어 + `@custom`으로 처리 | 기본 파이프라인의 파싱 결과를 바꾸지 않는다. 패키지를 업그레이드해도 유지된다 |
| 검증은 사용자가 Dev Tools에서 실행 | 작업 환경에서는 ELK 서버에 직접 접근할 수 없다 |

## 6. 관련 문서

| 문서 | 내용 |
|---|---|
| `docs/work-summary.md` | 전체 작업 내역, 산출물 목록, 문제 사례 |
| `docs/webserver-logging-plan.md` | 초기 설계 (아키텍처, NPM 이슈, Phase 0~7) |
| `docs/phase3-fleet-agent.md`, `docs/npm-timezone.md` | NPM 정책·Agent 설치, 타임존 |
| `docs/nginx-host-procedure.md` | 호스트 nginx 절차 |
| `docs/apache-host-procedure.md` | 호스트 apache2 절차 |
| `docs/response-time.md` | 응답시간 수집 절차 |
