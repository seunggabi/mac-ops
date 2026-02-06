# mac-ops - macOS 시스템 최적화 CLI 도구

## 1. 프로젝트 개요

### 목표

macOS 시스템에 축적되는 불필요한 캐시, 임시 파일, 좀비/고아 프로세스를 자동으로 정리하는 CLI 도구.

### 핵심 철학: "안전한 정리"

파일을 바로 삭제하지 않는다. 모든 정리 대상은 `~/.mac-ops/.trash/{원래경로}`로 이동하고, **72시간 유예 기간** 후 실제 삭제한다. 실수로 정리된 파일은 언제든 복원할 수 있다.

### 대상 환경

- macOS 12+ (Monterey 이상)
- Apple Silicon (M1/M2/M3/M4) + Intel 모두 지원
- 외부 의존성 없음 (macOS 기본 도구만 사용)

### 예상 절약 공간

| 모드 | 예상 절약 |
|------|----------|
| 보수적 (기본값) | 39 - 130GB |
| 공격적 (opt-in) | 120 - 415GB |

---

## 2. 기술 스택 결정

### 선택: zsh + plist + launchd

| 기술 | 선택 이유 |
|------|----------|
| **zsh** (메인 언어) | macOS 기본 셸. 외부 의존성 0. zsh 5.9 내장 기능(zstat, zmv, 연관 배열) 적극 활용 |
| **plist** (설정/메타데이터) | macOS 네이티브 포맷. `plutil` 내장 도구로 읽기/쓰기. JSON 파서 불필요 |
| **launchd** (스케줄링) | Apple 공식 권장 스케줄러. 절전 모드 깨어날 때 밀린 작업 실행. 자동 재시작 지원 |

### 왜 다른 언어가 아닌가

| 언어 | 탈락 이유 |
|------|----------|
| Go/Rust | 컴파일 필요, 바이너리 배포 복잡, macOS API 호출에 FFI 필요 |
| Python | macOS 기본 탑재 아님 (3.12부터 제거), 런타임 의존성 |
| Swift | 개발 속도 느림, 셸 스크립팅 대비 이점 없음 |
| Bash | zsh 대비 기능 부족 (연관 배열 미지원, 글로빙 약함) |

---

## 3. 프로젝트 구조

```
mac-ops/
├── bin/
│   └── mac-ops                    # 메인 엔트리포인트
├── lib/
│   ├── core/
│   │   ├── config.zsh             # 설정 로더 (plist 기반)
│   │   ├── trash.zsh              # 휴지통 관리 (이동, 만료, 복원)
│   │   ├── logger.zsh             # 로깅 시스템
│   │   ├── lock.zsh               # 중복 실행 방지 (flock)
│   │   ├── safety.zsh             # 화이트리스트/블랙리스트, 크기 가드
│   │   └── disk.zsh               # 디스크 공간 모니터링
│   ├── modules/
│   │   ├── cache-cleanup.zsh      # ~/Library/Caches 등
│   │   ├── tmp-cleanup.zsh        # /tmp, /var/folders
│   │   ├── log-cleanup.zsh        # ~/Library/Logs 등
│   │   ├── zombie-killer.zsh      # 좀비 프로세스 정리
│   │   ├── orphan-killer.zsh      # 고아 프로세스 정리
│   │   ├── brew-cleanup.zsh       # Homebrew 캐시
│   │   ├── dev-cleanup.zsh        # Xcode, npm, yarn, pip, gradle 등 개발도구
│   │   ├── docker-cleanup.zsh     # Docker 이미지/볼륨
│   │   └── orphan-app-cleanup.zsh # 삭제된 앱 잔존 파일 정리
│   └── utils/
│       ├── plist-helper.zsh       # plist 읽기/쓰기 유틸리티
│       ├── format.zsh             # 사람이 읽기 좋은 크기 표시, 색상
│       └── parallel.zsh           # 백그라운드 작업 오케스트레이션
├── config/
│   ├── default.plist              # 기본 설정
│   └── protected-processes.plist  # 보호 프로세스 목록
├── launchd/
│   └── com.mac-ops.cleanup.plist  # launchd 에이전트 정의
├── tests/
│   ├── test-trash.zsh
│   ├── test-safety.zsh
│   └── test-modules.zsh
└── docs/
    └── plan.md
```

---

## 4. 핵심 모듈 상세 설계

### 4.1 안전한 삭제 시스템 (Trash Manager)

#### 디렉토리 구조

```
~/.mac-ops/
├── .trash/          # 삭제된 파일 (원래 경로 구조 유지)
│   └── Users/
│       └── seunggabi/
│           └── Library/
│               └── Caches/
│                   └── com.example.app/
├── .metadata/       # 파일별 메타데이터
│   └── {sha256}.plist
└── .logs/           # 실행 로그
```

#### 메타데이터 (plist)

각 삭제 항목마다 `~/.mac-ops/.metadata/{sha256}.plist`에 다음 정보를 저장한다:

| 필드 | 설명 |
|------|------|
| `OriginalPath` | 원래 전체 경로 |
| `TrashPath` | 휴지통 내 경로 |
| `MovedAt` | 이동 시각 (ISO 8601) |
| `ExpiresAt` | 만료 시각 (이동 후 72시간) |
| `SizeBytes` | 파일/디렉토리 크기 |
| `Reason` | 삭제 사유 (예: "cache-expired", "zombie-process") |
| `Module` | 정리를 수행한 모듈명 |

#### 핵심 동작

- **이동**: 같은 볼륨이면 `mv` 사용 (O(1) rename 시스템콜). 다른 볼륨이면 경고 출력 후 스킵.
- **만료 삭제**: 72시간 경과된 항목 자동 영구 삭제.
- **복원**: `mac-ops restore <path>` 명령으로 원래 위치에 복원.
- **충돌 처리**: 같은 경로에 이미 파일이 있으면 타임스탬프 접미사 추가.

### 4.2 정리 대상 상세

#### 캐시 정리 (안전도: HIGH)

| 경로 | 예상 크기 | 조건 |
|------|----------|------|
| `~/Library/Caches/*` | 5 - 20GB | 7일 이상 된 파일 |
| `~/Library/Logs/*` | 500MB - 2GB | 7일 이상 |
| `~/Library/Developer/Xcode/DerivedData/*` | 10 - 50GB | 전체 |
| `~/Library/Caches/Homebrew/*` | 5 - 20GB | 전체 |
| `~/.npm/_cacache/*` | 2 - 10GB | 전체 |
| `~/.yarn/cache/*` | 1 - 5GB | 전체 |
| `~/.pnpm-store/*` | 2 - 8GB | 전체 |
| `~/.cache/pip/*` | 500MB - 2GB | 전체 |
| `~/.gradle/caches/*` | 2 - 10GB | 전체 |

#### 임시 파일 (안전도: HIGH)

| 경로 | 예상 크기 | 조건 |
|------|----------|------|
| `/tmp/*` | 100MB - 1GB | 3일 이상 |
| `/private/var/folders/*` | 2 - 10GB | 7일 이상 |
| `~/Library/Application Support/CrashReporter/*` | 100 - 500MB | 14일 이상 |

#### 브라우저 캐시 (안전도: HIGH)

| 브라우저 | 경로 | 예상 크기 |
|---------|------|----------|
| Safari | `~/Library/Containers/com.apple.Safari/Data/Library/Caches/*` | 500MB - 5GB |
| Chrome | `~/Library/Caches/Google/Chrome/Default/Cache/*` | 1 - 10GB |
| Firefox | `~/Library/Caches/Firefox/Profiles/*.default/cache2/*` | 500MB - 3GB |

#### Docker (안전도: HIGH, opt-in)

- dangling images 제거
- stopped containers 제거
- unused volumes 제거
- `docker system prune -a` 동등 효과

#### 삭제된 앱 잔존 파일 (안전도: MEDIUM)

/Applications에서 앱을 삭제한 후에도 남아있는 고아 파일을 탐지하여 정리한다.

| 경로 | 저장 내용 | 예상 크기 | 안전도 |
|------|----------|----------|--------|
| `~/Library/Application Support/{번들ID}/` | 앱 데이터, 플러그인 | 10MB - 5GB | MEDIUM |
| `~/Library/Caches/{번들ID}/` | 캐시 데이터 | 100MB - 10GB | HIGH |
| `~/Library/Preferences/{번들ID}.plist` | 앱 환경설정 | 10KB - 1MB | HIGH |
| `~/Library/Saved Application State/{번들ID}.savedState/` | 창 상태 저장 | 1MB - 100MB | HIGH |
| `~/Library/Containers/{번들ID}/` | Sandbox 앱 컨테이너 | 100MB - 5GB | MEDIUM |
| `~/Library/Group Containers/{그룹ID}.*/` | 앱간 공유 데이터 | 50MB - 2GB | LOW (공유 가능) |
| `~/Library/HTTPStorages/{번들ID}/` | HTTP 쿠키/캐시 | 10MB - 500MB | HIGH |
| `~/Library/WebKit/{번들ID}/` | WebKit 데이터 | 50MB - 1GB | HIGH |

**탐지 알고리즘**:
1. `/Applications/*.app`에서 설치된 앱의 번들 ID 목록 추출 (`PlistBuddy` 사용)
2. 위 경로들을 스캔하여 번들 ID가 매칭되지 않는 파일 탐지
3. `com.apple.*` 시스템 번들 ID는 항상 제외
4. Group Containers는 보수적 처리 (여러 앱 공유 가능)

#### 절대 건드리면 안 되는 경로 (금지 목록)

| 경로 | 이유 |
|------|------|
| `/System/*`, `/bin/*`, `/sbin/*`, `/usr/*` | SIP (System Integrity Protection) 보호 |
| `~/Library/Keychains/*` | 키체인 (암호, 인증서) |
| `~/Library/Preferences/*` | 앱 설정 파일 |
| `/Library/LaunchDaemons/*`, `/Library/LaunchAgents/*` | 시스템 서비스 정의 |

### 4.3 프로세스 관리

#### 좀비 프로세스 정리

1. `ps aux | awk '$8 ~ /^Z/'`로 좀비 프로세스 탐지
2. 부모 프로세스(PPID)에 `SIGCHLD` 전송
3. 부모가 응답하지 않으면 부모 프로세스 `kill` (보호 목록 제외)

#### 고아 프로세스 정리

1. `PPID=1`이면서 `launchctl list`에 등록되지 않은 프로세스 탐지
2. **24시간 이상** 실행 중인 것만 대상으로 함
3. `SIGTERM` 전송 후 5초 대기, 응답 없으면 `SIGKILL`

#### 절대 종료 금지 프로세스

다음 프로세스는 어떤 상황에서도 종료하지 않는다:

```
kernel_task, launchd, WindowServer, loginwindow,
SystemUIServer, Finder, cfprefsd, mds, mds_stores
```

### 4.4 5계층 안전 시스템

| 계층 | 이름 | 설명 |
|------|------|------|
| 1 | **화이트리스트** | 절대 건드리지 않는 경로 목록 |
| 2 | **블랙리스트** | 항상 정리하는 경로 목록 |
| 3 | **크기 가드** | 단일 파일 2GB 초과 시 스킵, 배치 10GB 초과 시 분할 처리 |
| 4 | **프로세스 보호** | 보호 프로세스 목록으로 시스템 필수 프로세스 보호 |
| 5 | **락 파일** | PID 기반 `flock`으로 중복 실행 방지 |

---

## 5. 실행 흐름도

```
시작 → 락 획득 → 설정 로드 → 디스크 공간 확인
         │
    ┌────┴─────────────────┐
    │    병렬 실행 트랙       │
    │   (파일 정리 모듈)      │
    │                       │
    │  cache  tmp  log      │
    │  brew   dev  docker   │
    └──────────┬────────────┘
               │
    ┌──────────┴────────────┐
    │    순차 실행 트랙       │
    │   (프로세스 관리)       │
    │                       │
    │  zombie  →  orphan    │
    └──────────┬────────────┘
               │
    72시간 만료 파일 영구 삭제
               │
    락 해제 → 요약 리포트 → 종료
```

### 흐름 상세

1. **락 획득**: PID 기반 flock. 이미 실행 중이면 즉시 종료.
2. **설정 로드**: `~/.mac-ops/config.plist` 사용자 설정 병합.
3. **디스크 공간 확인**: 휴지통 이동에 필요한 최소 여유 공간 확인.
4. **병렬 파일 정리**: 각 모듈이 독립적인 디렉토리 트리를 정리하므로 병렬 실행 가능.
5. **순차 프로세스 관리**: 프로세스 트리 스냅샷 일관성을 위해 순차 실행.
6. **만료 삭제**: 72시간 지난 휴지통 항목 영구 삭제.
7. **요약 리포트**: 정리된 파일 수, 확보된 공간, 종료된 프로세스 수 출력.

---

## 6. CLI 인터페이스

```
mac-ops [command] [options]

Commands:
  run              정리 실행 (기본 명령어)
  status           휴지통 상태, 디스크 사용량, 스케줄 상태 표시
  restore <path>   휴지통에서 원래 위치로 복원
  list-trash       휴지통 내역 조회 (메타데이터 포함)
  purge            만료된 휴지통 항목 즉시 삭제
  install          launchd 에이전트 설치
  uninstall        launchd 에이전트 제거
  config           설정 조회/수정

Options:
  --dry-run        실제 실행 없이 미리보기 (무엇을 정리할지 표시)
  --module=NAME    특정 모듈만 실행 (예: --module=cache-cleanup)
  --verbose        상세 로그 출력
  --force          크기 가드 무시
  --scheduled      launchd에서 실행 시 사용하는 내부 플래그
```

### 사용 예시

```bash
# 기본 정리 (dry-run 미리보기)
mac-ops run --dry-run

# 실제 정리 실행
mac-ops run

# 캐시만 정리
mac-ops run --module=cache-cleanup

# 휴지통 상태 확인
mac-ops status

# 실수로 삭제된 파일 복원
mac-ops restore ~/Library/Caches/com.important.app

# 휴지통 내역 조회
mac-ops list-trash

# 자동 실행 설치
mac-ops install

# 자동 실행 제거
mac-ops uninstall
```

---

## 7. launchd 스케줄링

### 에이전트 설정

- **위치**: `~/Library/LaunchAgents/com.mac-ops.cleanup.plist`
- **실행 주기**: 매 3600초 (1시간)마다 실행
- **리소스 제한**: I/O 및 CPU 우선순위를 낮춰 사용자 작업에 영향 없음

### plist 주요 설정

| 키 | 값 | 설명 |
|----|-----|------|
| `StartInterval` | 3600 | 매시간 실행 |
| `LowPriorityIO` | true | I/O 우선순위 최저 |
| `Nice` | 10 | CPU 우선순위 낮춤 |
| `ProcessType` | Background | 백그라운드 프로세스로 분류 |
| `StandardOutPath` | `~/.mac-ops/.logs/launchd-stdout.log` | 표준 출력 로그 |
| `StandardErrorPath` | `~/.mac-ops/.logs/launchd-stderr.log` | 표준 에러 로그 |

### 설치/제거

```bash
# 설치
mac-ops install
# 내부적으로: cp launchd/com.mac-ops.cleanup.plist ~/Library/LaunchAgents/
#            launchctl load ~/Library/LaunchAgents/com.mac-ops.cleanup.plist

# 제거
mac-ops uninstall
# 내부적으로: launchctl unload ~/Library/LaunchAgents/com.mac-ops.cleanup.plist
#            rm ~/Library/LaunchAgents/com.mac-ops.cleanup.plist
```

---

## 8. 성능 최적화 전략

| 전략 | 설명 |
|------|------|
| **병렬 파일 정리** | 각 정리 모듈이 독립적인 디렉토리 트리를 다루므로 백그라운드 병렬 실행 |
| **순차 프로세스 관리** | 프로세스 트리 스냅샷 일관성을 위해 순차 실행 |
| **O(1) 이동** | 같은 볼륨에서 `mv`는 rename 시스템콜로 O(1) 수행 |
| **배치 분할** | 대용량 캐시는 1GB 배치로 분할 처리하여 I/O 독점 방지 |
| **zstat 활용** | zsh 내장 `zstat` 사용으로 `stat` 프로세스 스폰 최소화 |
| **find -delete** | 대량 소파일 처리 시 fork 오버헤드 방지 |
| **LowPriorityIO** | launchd 에이전트에서 I/O 우선순위를 낮춰 사용자 체감 영향 최소화 |

---

## 9. 차별화 포인트

### 기존 도구와의 비교

| 기능 | mac-cleanup-sh | CleanMyMac | OnyX | **mac-ops** |
|------|:-:|:-:|:-:|:-:|
| 72시간 복구 | - | - | - | **지원** |
| 모듈식 설정 | - | - | 지원 | **지원** |
| 프로세스 인식 | - | 부분 | - | **지원** |
| CLI 자동화 | 지원 | - | - | **지원** |
| launchd 연동 | - | - | - | **지원** |
| dry-run | 지원 | 지원 | 부분 | **지원** |
| 무료/오픈소스 | 지원 | 유료 ($300) | 유료 | **지원** |

### mac-ops만의 강점

1. **72시간 안전망**: 모든 삭제가 이동 방식이므로, 실수가 발생해도 72시간 이내 복원 가능.
2. **프로세스 관리 통합**: 파일 정리뿐 아니라 좀비/고아 프로세스까지 한 도구에서 관리.
3. **완전 자동화**: launchd 연동으로 설치 후 신경 쓸 필요 없음.
4. **외부 의존성 제로**: macOS 기본 도구만 사용하여 설치가 간단하고 호환성 문제 없음.
5. **5계층 안전 시스템**: 다중 안전장치로 시스템 파일 보호.

---

## 10. 개발 로드맵

### Phase 1 - MVP (핵심 기능)

| 순서 | 항목 | 설명 |
|------|------|------|
| 1 | core/ 모듈 구현 | config, trash, logger, lock, safety, disk |
| 2 | cache-cleanup 모듈 | `~/Library/Caches` 등 캐시 정리 |
| 3 | tmp-cleanup 모듈 | `/tmp`, `/var/folders` 임시 파일 정리 |
| 4 | log-cleanup 모듈 | `~/Library/Logs` 등 로그 정리 |
| 5 | zombie-killer 모듈 | 좀비 프로세스 탐지 및 정리 |
| 6 | orphan-killer 모듈 | 고아 프로세스 탐지 및 정리 |
| 7 | 기본 CLI | run, status, restore 명령어 |
| 8 | dry-run 모드 | 미리보기 기능 |
| 9 | 기본 테스트 | core 모듈 단위 테스트 |

### Phase 2 - 확장

| 순서 | 항목 | 설명 |
|------|------|------|
| 10 | brew-cleanup 모듈 | Homebrew 캐시 정리 |
| 11 | dev-cleanup 모듈 | Xcode, npm, yarn, pip, gradle 캐시 |
| 12 | docker-cleanup 모듈 | Docker 이미지/볼륨 정리 |
| 13 | launchd 명령어 | install, uninstall 명령어 구현 |
| 14 | 설정 파일 시스템 | config.plist 기반 사용자 설정 |
| 15 | 로그 로테이션 | 실행 로그 자동 관리 |

### Phase 3 - 고급 기능

| 순서 | 항목 | 설명 |
|------|------|------|
| 16 | 브라우저 캐시 정리 | Safari, Chrome, Firefox 캐시 |
| 17 | 공간 분석 리포트 | `mac-ops analyze` 명령어 |
| 18 | macOS 알림 연동 | 정리 완료 시 시스템 알림 |
| 19 | Homebrew tap 배포 | `brew install mac-ops`로 설치 가능 |

---

## 11. 리스크 및 대응

| 리스크 | 영향도 | 대응 방안 |
|--------|--------|----------|
| 중요 파일 실수 삭제 | **높음** | 72시간 trash 시스템 + 화이트리스트 + dry-run 기본값 |
| SIP 보호 경로 접근 | 중간 | 경로 사전 필터링, SIP 상태 체크 후 스킵 |
| 디스크 공간 부족으로 trash 이동 불가 | 중간 | 디스크 공간 사전 체크, 공간 부족 시 긴급 purge 실행 |
| 프로세스 오종료 | **높음** | 보호 프로세스 목록, SIGTERM 우선, 5초 대기 후 SIGKILL |
| 다른 볼륨 파일 이동 시 느림 | 낮음 | 볼륨 체크 후 경고 메시지 출력, 다른 볼륨 파일은 스킵 |
| 동시 실행 충돌 | 낮음 | PID 기반 flock으로 중복 실행 방지 |

---

## 12. 권한 요구사항 (Full Disk Access)

macOS 10.14+ 에서 TCC (Transparency, Consent, Control) 정책에 의해 `~/Library/Caches`, `~/Library/Logs` 등 핵심 정리 경로에 대한 접근이 제한된다.

### 필수 권한

| 권한 | 필요 시점 | 영향 |
|------|----------|------|
| **Full Disk Access (FDA)** | 캐시/로그 정리 | FDA 없이는 `Operation not permitted` 발생 |

### 사용자 안내 절차

1. `mac-ops install` 실행 시 FDA 권한 체크
2. 권한 미부여 상태면 안내 메시지 출력:
   ```
   ⚠️  Full Disk Access 권한이 필요합니다.
   시스템 설정 > 개인정보 보호 및 보안 > Full Disk Access 에서
   Terminal.app (또는 iTerm) 을 추가해주세요.
   ```
3. `open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"` 로 설정 화면 직접 오픈
4. launchd 에이전트도 동일하게 FDA가 필요하므로 `mac-ops` 바이너리 자체를 FDA 목록에 추가하도록 안내

---

## 13. 비정상 종료 처리 (Signal Trap)

### 문제 상황

- trash 이동 중 프로세스가 죽으면: 원본은 이동됐는데 metadata plist 미생성
- 락 파일이 stale 상태로 남아 이후 실행 영구 차단

### 대응 설계

1. **trap 등록**: `SIGTERM`, `SIGINT`, `SIGHUP`, `EXIT` 시그널에 대해 정리 함수 등록
2. **트랜잭션 패턴**:
   - 이동 전: 임시 metadata plist 먼저 생성 (상태: `in_progress`)
   - 이동 후: metadata 상태를 `completed`로 업데이트
   - 비정상 종료 시 재시작하면: `in_progress` 상태의 항목을 감지하여 롤백 (원래 위치로 복원)
3. **stale 락 감지**: 락 파일의 PID가 살아있는지 `kill -0 $PID`로 확인. 죽어있으면 락 제거 후 진행

---

## 14. 메타데이터 키 정의

### SHA256 키 규칙

- **입력**: 원래 절대 경로 문자열의 SHA256 해시
- **충돌 방지**: 같은 경로가 여러 번 trash에 들어가는 경우 `{sha256}_{timestamp}.plist` 형식 사용
- **예시**: `/Users/seunggabi/Library/Caches/com.example` → `a1b2c3..._{20260206_143022}.plist`
- **검색**: 복원 시 원래 경로의 SHA256로 prefix 매칭하여 가장 최근 항목 반환
