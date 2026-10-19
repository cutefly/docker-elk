# nginx·apache 로그 수집: Elastic Agent(standalone) → Logstash → Elasticsearch

Fleet Server 없이 Logstash를 거쳐 수집하면서, 인덱스 형식과 대시보드는 nginx·apache Integration 것을 그대로 씁니다.

## 구성

```
[웹서버 호스트]                          [ELK 호스트 (docker-elk)]
 nginx / apache 로그 파일
        │
 Elastic Agent (standalone)  ──5044──▶  Logstash  ──data_stream──▶  Elasticsearch
   data_stream.* 필드를 붙임          (파싱 안 함)                    │
                                                                    ├ index template  logs-nginx.access 등
                                                                    ├ ingest pipeline logs-nginx.access-<버전> 등 ← 여기서 파싱
                                                                    └ Kibana 대시보드 [Logs Nginx] / [Logs Apache]
```

이렇게 동작하는 이유는 다음과 같습니다. Agent는 Integration과 같은 dataset 이름(`nginx.access` 등)을 이벤트의 `data_stream.*` 필드에 넣어서 보냅니다. Logstash는 `data_stream => true` 설정에 따라 이 필드로 `logs-nginx.access-default` 같은 data stream에 문서를 씁니다. Integration이 설치한 index template에는 `default_pipeline`이 지정되어 있어서 파싱과 ECS 매핑은 ES가 합니다. 그래서 Fleet으로 수집할 때와 결과 문서가 같고, 제공 대시보드도 그대로 동작합니다.

Logstash에서 grok 같은 파싱을 추가하지 않는 것이 핵심입니다. 꼭 가공해야 하면 ES의 `logs-nginx.access@custom` 파이프라인에 넣으세요. Integration을 업그레이드해도 유지됩니다.

Kibana의 Fleet 메뉴는 "Integration 자산 설치"에만 씁니다. 이 기능은 Kibana 안에 있어서 Fleet Server가 없어도 됩니다.

## 변경한 파일

| 파일 | 내용 |
|---|---|
| `logstash/pipeline/logstash.conf` | `elastic_agent` input(5044) 추가, `data_stream.*`가 있는 이벤트는 data stream output으로 보냄. tcp 50000은 기존 동작 유지 |
| `setup/roles/logstash_writer.json` | `logs-*-*`, `metrics-*-*`에 `auto_configure`, `create_doc` 권한 추가 |
| `kibana/config/kibana.yml` | `xpack.fleet.packages`에 `nginx`, `apache` 추가(자산 자동 설치) |
| `webserver/install-agent.sh` | 웹서버 호스트용 점검·설치 스크립트 |
| `webserver/elastic-agent/*.yml` | standalone 설정 조각(base + nginx/apache inputs) |
| `webserver/verify-ingest.txt` | Kibana Dev Tools 검증 명령 |

`docker-compose.yml`은 바꾸지 않았습니다. 5044 포트는 원래 열려 있습니다.

## 1단계: ELK 호스트

순서가 중요합니다. **데이터가 들어오기 전에 Integration 자산을 먼저 설치**해야 합니다. 자산 없이 데이터가 먼저 들어오면 기본 `logs` 템플릿으로 data stream이 만들어지고, 파싱되지 않은 채 쌓입니다(복구 방법은 아래 문제 해결 참고).

```bash
cd docker-elk

# (1) logstash_internal 사용자 권한 갱신 (role 파일을 다시 적용)
docker compose up setup

# (2) Kibana 재시작 → kibana.yml의 nginx/apache 패키지 자산 설치
docker compose restart kibana

# (3) Logstash 재시작 (pipeline은 자동 reload되지만 input 포트 변경이 있으므로 재시작 권장)
docker compose restart logstash
docker compose logs -f logstash   # "Pipelines running" 와 5044 listen 확인
```

`docker compose up setup`은 `.env`에 있는 값으로 내장 사용자 비밀번호를 다시 설정합니다. `.env` 값이 현재 비밀번호와 같은지 먼저 확인하세요.

Kibana가 인터넷(epr.elastic.co)에 접속할 수 없는 환경이면 (2)의 패키지 설치가 실패합니다. 이 경우 Kibana 로그를 확인하고, 사내 EPR이나 패키지 파일 업로드(`POST kbn:/api/fleet/epm/packages`에 zip 업로드)를 쓰세요.

kibana.yml을 쓰지 않고 Dev Tools에서 직접 설치해도 됩니다.

```
POST kbn:/api/fleet/epm/packages/nginx
POST kbn:/api/fleet/epm/packages/apache
```

설치를 확인하려면 `webserver/verify-ingest.txt`의 1~3번을 실행하세요. 2번의 `_simulate` 결과에서 `source.ip`와 `http.response.status_code`가 채워지면 ES 쪽 준비는 끝입니다.

## 2단계: 웹서버 호스트

`webserver/` 폴더(install-agent.sh, elastic-agent/)를 웹서버 호스트에 복사한 뒤 실행합니다. Agent 버전은 ES 버전(`.env`의 `ELASTIC_VERSION`, 현재 9.5.5)과 맞춥니다.

```bash
scp -r webserver/ user@web01:/tmp/webserver
ssh user@web01
cd /tmp/webserver
chmod +x install-agent.sh

# 먼저 생성될 설정을 확인
./install-agent.sh --logstash 192.168.219.131:5044 --dry-run

# 설치 (nginx/apache는 로그 디렉터리를 보고 자동 감지)
sudo ./install-agent.sh --logstash 192.168.219.131:5044 --version 9.5.5
```

스크립트는 다음 순서로 동작합니다. Logstash 포트에 연결할 수 있는지 확인하고, 로그 파일이 있는지와 크기를 점검합니다. 그다음 Agent tar를 받아 체크섬을 검증하고, `elastic-agent.yml`을 넣은 뒤 standalone 모드로 설치합니다. Agent가 이미 설치되어 있으면 설정만 교체(기존 파일은 백업)하고 재시작합니다.

로그 경로가 기본값(Ubuntu apt 기준 `/var/log/nginx/`, `/var/log/apache2/`)과 다르면 환경변수로 지정합니다.

```bash
sudo NGINX_ACCESS_PATH='/srv/nginx/logs/access*.log' \
     NGINX_ERROR_PATH='/srv/nginx/logs/error*.log' \
     ./install-agent.sh --logstash 192.168.219.131:5044 --target nginx
```

로그 형식은 nginx와 apache 모두 기본 `combined` 형식이어야 Integration pipeline이 파싱합니다. `log_format`/`LogFormat`을 바꿨다면 2단계 전에 `verify-ingest.txt` 2번의 message를 실제 로그 한 줄로 바꿔서 파싱되는지 먼저 확인하세요.

## 3단계: 확인

웹서버에 요청을 몇 번 보낸 뒤 `verify-ingest.txt`의 4~6번을 실행합니다.

```bash
# 웹서버 호스트에서
for i in $(seq 1 20); do curl -s -o /dev/null http://localhost/; done
sudo elastic-agent status --output=full
```

대시보드는 Kibana > Dashboards에서 `[Logs Nginx] Access and error logs`, `[Logs Apache] Access and error logs` 등을 열면 됩니다(이름은 Integration 버전에 따라 조금 다를 수 있습니다). `[Metrics Nginx]`, `[Metrics Apache]` 대시보드는 stub_status·server-status 메트릭 수집을 추가로 설정해야 채워집니다. 이번 구성에는 넣지 않았습니다.

## 문제 해결

| 증상 | 원인과 조치 |
|---|---|
| `_count`가 0이고 `logs-elastic_agent*`도 0 | Agent가 Logstash에 도달하지 못함. `sudo elastic-agent status --output=full`, 방화벽(5044), `docker compose logs logstash` 확인 |
| `logs-elastic_agent*`는 있는데 nginx만 0 | 로그 파일이 1KB 미만이면 filestream이 아직 읽지 않음(파일 앞 1KB로 식별). 요청을 더 보내 크기를 키움. 경로·권한도 확인 |
| Logstash 로그에 `403` / `security_exception` | role 권한이 적용되지 않음. `docker compose up setup` 재실행 후 `GET _security/role/logstash_writer` 확인 |
| data stream의 template이 `logs`, 문서에 `message`만 있음 | 자산 설치 전에 데이터가 들어옴. 자산 설치 후 `DELETE _data_stream/logs-nginx.access-default` 하고 Agent 재시작(삭제한 데이터는 다시 수집되지 않으므로 필요하면 Agent registry도 초기화) |
| 문서에 `error.message`가 있음 | 로그 형식이 Integration pipeline과 다름. 웹서버 로그 형식을 combined로 맞추거나 `@custom` 파이프라인으로 보정 |
| 시간이 9시간 어긋남 | error 로그는 시간대 정보가 없어서 `event.timezone`(add_locale)을 씀. 웹서버 호스트 시간대(`timedatectl`) 확인 |

## 운영 시 고려 사항

Agent와 Logstash 사이는 현재 평문입니다. 내부망 밖으로 나가거나 보안 요건이 있으면 Logstash `elastic_agent` input에 `ssl_enabled`, 인증서를 설정하고, `base.yml`의 `ssl.certificate_authorities`를 켜세요.

Integration 버전을 올리면 ingest pipeline 이름(`logs-nginx.access-<버전>`)이 바뀝니다. 하지만 Logstash와 Agent 설정은 버전과 무관하므로 바꿀 필요가 없습니다. 다음 rollover부터 새 pipeline이 적용됩니다.

nginx 앞에 프록시가 있으면 같은 요청이 여러 로그에 남습니다. 대시보드에서는 `host.name`으로 구분해서 보세요.
