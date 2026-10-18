# 웹서버 응답시간 수집 (nginx · NPM · apache)

작성일: 2026-10-16 · Dev Tools 명령: `webserver/common/response-time.txt`

## 1. 방식

Integration 기본 파이프라인은 combined 포맷까지만 파싱하고, 응답시간 필드를 만들지 않는다. 그래서 다음 세 단계로 추가한다. 세 단계 모두 기본 파이프라인과 템플릿을 수정하지 않고 Fleet이 제공하는 `@custom` 확장 지점만 쓰므로, 패키지를 업그레이드해도 유지된다.

1. **로그 포맷:** 기존 포맷의 **맨 끝에 접미어를 붙인다.** 기본 파이프라인은 앞부분만 읽기 때문에 기존 파싱 결과는 바뀌지 않는다(_simulate로 확인).
2. **파싱:** `logs-<pkg>.access@custom` 파이프라인이 원문(`event.original`)에서 접미어를 읽어 필드로 변환한다.
3. **원문 전달:** 기본 파이프라인은 처리가 끝나면 `event.original`을 지운다. 그래서 Fleet 태그 `preserve_original_event`로 원문을 남기게 한다. 응답시간을 추출한 뒤에는 `@custom`이 원문과 태그를 다시 지우므로 저장 용량은 늘지 않는다.

| 서버 | 추가 접미어 | 원래 단위 | 저장 필드 (ns, long) |
|---|---|---|---|
| nginx, NPM | `rt=$request_time` | 초 (ms 정밀도) | `event.duration` (ECS 표준) |
| nginx, NPM | `urt="$upstream_response_time"` | 초, 여러 upstream이면 `,`/`:`로 나열 | `webserver.upstream_duration` (사용자 정의, 합산값) |
| apache | `rt=%D` | 마이크로초 | `event.duration` |

`event.duration`은 ECS 표준 필드라서 nginx와 apache를 같은 쿼리로 비교할 수 있다. upstream 시간은 ECS에 해당 필드가 없다. 그래서 앞으로 패키지 필드와 겹치지 않도록 `webserver.*` 네임스페이스를 따로 만들어 저장했다.

### 각 값의 의미

| 값 | 측정 구간 | 용도 |
|---|---|---|
| nginx `$request_time` | 요청의 첫 바이트를 읽은 때부터 응답의 마지막 바이트를 보낸 때까지. 클라이언트 전송 시간이 포함된다 | 사용자가 체감하는 전체 시간 |
| nginx `$upstream_response_time` | upstream(백엔드)과 연결한 때부터 응답을 다 받은 때까지 | 백엔드 처리 시간. `rt`와의 차이는 네트워크나 클라이언트 지연이다 |
| apache `%D` | 요청을 받은 때부터 응답을 보낸 때까지 | 전체 처리 시간 |

**리버스 프록시 체인에서 보는 법**

NPM의 `urt`는 그 뒤에 있는 nginx나 apache가 응답한 시간과 거의 같다. NPM의 `urt`가 크면 백엔드 쪽에 원인이 있다. 그 백엔드의 `rt`도 크면 애플리케이션이 원인이다.

## 2. 적용 순서

순서가 중요하다. 파이프라인을 먼저 만든 뒤 로그 포맷을 바꾸면 이행 중인 로그도 오류 없이 처리된다. 접미어가 없는 줄은 그대로 통과하기 때문이다.

### Step 1. ELK: 매핑, 파이프라인, 검증 (Dev Tools)

`response-time.txt`를 위에서부터 차례로 실행한다.

| 블록 | 내용 | 확인 |
|---|---|---|
| A | `@custom` component template에 `event.duration`, `webserver.upstream_duration`을 `long`으로 매핑 | GET으로 기존 내용을 먼저 확인한다. 기존 설정이 있으면 합쳐서 PUT 한다 |
| B | `logs-nginx.access@custom`, `logs-apache.access@custom` 파이프라인 생성 | `acknowledged: true` |
| C | 기본 파이프라인 전체에 대해 `_simulate` (nginx 4건, apache 2건) | 파일 안의 "기대" 값과 같아야 한다. 특히 **`user_agent.original`에 `rt=`가 섞이지 않아야 한다** |
| D | rollover | 새 매핑은 다음 backing index부터 적용된다 |

C에서 `error.message`가 나오거나 `rt=`가 `user_agent.original`에 섞이면 기본 파이프라인이 접미어를 허용하지 않는다는 뜻이다. 이 경우 Step 2 이후로 진행하지 말고 결과를 공유한다. 대안은 Agent 쪽에서 접미어를 떼어 내는 processor를 쓰는 방식이다.

### Step 2. Fleet: 태그 추가 (Kibana UI)

각 정책의 nginx·apache Integration을 편집해 **access logs**의 Tags에 `preserve_original_event`를 추가한다. 기존 태그(`nginx-npm`, `nginx-host`, `apache-host`)는 그대로 둔다. 화면에 "Preserve original event" 토글이 있으면 그것을 켜도 결과는 같다.

| 정책 | Integration | Tags (access logs) |
|---|---|---|
| Webserver Policy (NPM) | nginx | `nginx-npm`, `preserve_original_event` |
| Nginx Host Policy | nginx | `nginx-host`, `preserve_original_event` |
| Apache Host Policy | apache | `apache-host`, `preserve_original_event` |

error logs에는 추가하지 않는다.

### Step 3. 웹서버: 로그 포맷 변경

변경 대상은 `"$http_user_agent"` 뒤(apache는 `\"%{User-Agent}i\"` 뒤) **한 군데**뿐이다.

**NPM** (`<NPM_DATA>/nginx/custom/http_top.conf`), **nginx 서버** (`/etc/nginx/conf.d/ecs-logging.conf`):

```nginx
log_format ecs_combined '$host $remote_addr - $remote_user [$time_local] '
                        '"$request" $status $body_bytes_sent '
                        '"$http_referer" "$http_user_agent" '
                        'rt=$request_time urt="$upstream_response_time"';
```

```bash
# NPM
docker exec <npm> nginx -t && docker exec <npm> nginx -s reload
# nginx 서버
sudo nginx -t && sudo systemctl reload nginx
tail -n2 <로그 경로>/ecs_access.log        # 끝에 rt=0.012 urt="0.010" 형태 확인
```

**apache 서버** (`/etc/apache2/conf-available/ecs-logging.conf`, `ecs_vhost_combined` 한 줄):

```apache
LogFormat "%v:%p %a %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\" rt=%D" ecs_vhost_combined
```

```bash
sudo apache2ctl configtest && sudo systemctl reload apache2
tail -n2 /var/log/apache2/ecs_access.log   # 끝에 rt=1532 형태 확인 (마이크로초)
```

### Step 4. 확인

- `response-time.txt` E 블록: 도메인별 p50/p95/p99를 확인한다. 값은 ns 단위이므로 ÷1,000,000을 하면 ms다.
- E-1 블록: 최신 문서에 `event.original`과 `preserve_original_event` 태그가 남아 있지 않은지 확인한다.
- **Discover:** `event.duration` 필드가 보이는지 확인한다. Data view 필드 형식을 **Duration**(입력 단위 Nanoseconds, 출력 단위 Milliseconds)으로 지정하면 읽기 쉽다.

## 3. 대시보드

Elastic이 제공하는 `[Logs Nginx]`·`[Logs Apache]` 대시보드에는 응답시간 패널이 없다. 관리되는 대시보드를 직접 수정하면 패키지를 업그레이드할 때 덮어써지므로 다음과 같이 한다.

1. 제공 대시보드를 열고 **Save as**로 사본(예: `[Custom] Web access + latency`)을 만든다.
2. Lens 패널을 추가한다.
   - **응답시간 추이:** X축 `@timestamp`, Y축 `event.duration`의 95th percentile, Breakdown `event.dataset`
   - **도메인별 응답시간:** `destination.domain`별 p95 `event.duration` 테이블
   - **백엔드 지연:** `webserver.upstream_duration`의 p95 (nginx만 해당)
3. 대시보드 상단 필터에 `tags`(`nginx-npm` / `nginx-host` / `apache-host`)를 걸어 이중 집계를 피한다.

## 4. 주의사항

| 항목 | 내용 |
|---|---|
| 응답시간이 없는 요청 | 정적 파일이나 `return` 응답은 `urt="-"`가 되고 `webserver.upstream_duration`은 저장되지 않는다. 이것은 정상이다 |
| 업그레이드 후 | 패키지를 업그레이드하면 파이프라인 이름(버전)이 바뀐다. `@custom` 파이프라인은 유지되지만 C 블록 `_simulate`로 다시 확인한다 |
| 다른 `@custom` 사용 | 같은 이름의 파이프라인이나 템플릿을 다른 용도로 이미 쓰고 있다면 덮어쓰지 말고 processor와 properties를 합친다 |
| 원문 보관이 필요할 때 | B 블록의 `remove event.original` processor와 태그 제거 processor를 지우면 원문이 저장된다. 디버깅에 유용하지만 저장 용량이 늘어난다 |
| 추가 확장 | apache TTFB(`%^FB`, `LogIOTrackTTFB On` 필요)나 nginx `$upstream_connect_time`도 같은 방식(접미어 → `@custom` grok)으로 추가할 수 있다 |
