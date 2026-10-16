# nginx access 로그 미수집 진단 (verify 4단계 결과 0건)

위에서부터 순서대로 확인한다. 원인을 찾으면 그 단계에서 멈춘다.

## A. 웹서버 — 파일 상태

```bash
F=<NPM_DATA>/logs/ecs_access.log
ls -l $F; stat -c 'size=%s bytes' $F; wc -l $F; tail -n2 $F
```

| 결과 | 판단 |
|---|---|
| 파일 없음 또는 0바이트 | NPM 설정 문제 → `docker exec <npm> nginx -T \| grep ecs_access`로 include 여부 확인 |
| **1,024바이트 미만** | **filestream 기본 동작 때문일 가능성이 높다.** 파일 앞 1KB로 파일을 식별하므로 1KB를 넘을 때까지 읽지 않는다. → **C**로 트래픽을 만든 뒤 확인 |
| 1KB 이상이고 라인이 계속 쌓임 | **B**로 이동 |

## B. 웹서버 — Agent가 이 파일을 대상으로 잡았는지

```bash
# 1) 컴포넌트 상태 (nginx access 입력이 HEALTHY인지)
sudo elastic-agent status --output=full | grep -iA3 nginx

# 2) 실제 적용된 정책의 경로 (호스트 경로 + ecs_access.log* 인지)
sudo elastic-agent inspect | grep -n -A3 'ecs_access\|access.log'

# 3) Agent 로그에서 해당 파일과 오류 확인
sudo elastic-agent logs -n 300 2>/dev/null | grep -iE 'ecs_access|nginx.access|fingerprint|error' | tail -30
#   (logs 하위 명령이 없으면) sudo grep -rhiE 'ecs_access|nginx.access' /opt/Elastic/Agent/data/elastic-agent-*/logs/ | tail -30
```

| 결과 | 판단 및 조치 |
|---|---|
| **B-1 결과가 비어 있음** (nginx 컴포넌트가 없음) | Agent가 실행 중인 정책에 nginx integration이 없다. **B-4**로 이동 |
| inspect 결과에 경로가 `/data/logs/...` (컨테이너 경로) | Fleet에서 nginx integration의 Access logs Paths를 호스트 경로로 수정 |
| inspect에 `ecs_access`가 없음 | Access logs 입력이 꺼져 있거나 경로 오타. Fleet에서 확인 |
| 로그에 `fingerprint` / `file size is too small` 류 메시지 | A의 1KB 조건 → **C** |
| 로그에 `Harvester started` / `harvester` + ecs_access | 파일은 읽고 있음 → **D** |

## B-4. Agent 정책과 nginx integration의 연결 확인

```bash
# 웹서버: Agent에서 실행 중인 컴포넌트 전체 목록
sudo elastic-agent status --output=full | grep -E '^\s*(id|name|state|message):' | head -40
```

```
# Kibana Dev Tools: Agent가 어느 정책, 어느 revision에 있는지
GET kbn:/api/fleet/agents?perPage=20&showInactive=false
#   → items[].local_metadata.host.hostname, policy_id, policy_revision, status 확인

# nginx integration이 어느 정책에 붙어 있는지
GET kbn:/api/fleet/package_policies?kuery=ingest-package-policies.package.name:nginx
#   → items[].name, policy_ids(또는 policy_id), enabled 확인

# 정책 목록 (id ↔ 이름, 현재 revision)
GET kbn:/api/fleet/agent_policies?perPage=50
#   → items[].id, name, revision
```

| 결과 | 조치 |
|---|---|
| Agent의 `policy_id`가 `Webserver Policy`가 아님 | Fleet → Agents → 해당 Agent → Actions → **Assign to new policy** → `Webserver Policy` |
| nginx package policy가 없거나 다른 정책에 붙어 있음 | Fleet → `Webserver Policy` → Add integration → Nginx를 다시 추가 (설정값은 phase3 가이드 Step 2) |
| 정책은 맞는데 Agent의 `policy_revision` < 정책의 `revision` | 정책 변경이 아직 반영되지 않았다. Agent 상세 화면의 Logs, 또는 웹서버에서 `sudo elastic-agent logs`로 policy change 오류를 확인 |

조치 후 1~2분 기다린 뒤 B-1을 다시 실행한다. 정상이면 `nginx` 문자열이 들어간 컴포넌트와 unit(access, error, stubstatus)이 HEALTHY로 보인다.

## C. 트래픽 생성 (1KB 넘기기)

```bash
for i in $(seq 1 30); do curl -s -o /dev/null -H 'Host: <NPM에 등록된 proxy 도메인>' http://127.0.0.1/; done
stat -c 'size=%s' <NPM_DATA>/logs/ecs_access.log     # 1024 초과 확인
```

1~2분 뒤 verify-ingest.txt의 4단계를 다시 실행한다.

## D. Kibana Dev Tools — ES 측에서 거부되었는지

```
# 1) 데이터 스트림 자체가 있는지 (verify 1단계 결과 재확인)
GET _data_stream/logs-nginx.access-*?filter_path=data_streams.name

# 2) failure store에 실패 문서가 있는지 (failure store 미지원/미사용이면 오류 또는 0건)
GET logs-nginx.access-*::failures/_search?size=3

# 3) 혹시 다른 namespace나 이름으로 들어갔는지
GET logs-*/_search?size=0
{ "query": { "term": { "data_stream.dataset": "nginx.access" } },
  "aggs": { "idx": { "terms": { "field": "_index", "size": 10 } } } }
```

Agent 로그(B-3)에 `failed to index`, `mapper_parsing_exception`, `403` 같은 메시지가 있으면 그 내용을 그대로 전달한다.

## 전달할 결과

A의 `ls`/`stat` 출력, B-1·B-2 출력, D-1·D-3 결과. 그 밖에 verify 1·2단계 결과가 있으면 함께 전달한다.
