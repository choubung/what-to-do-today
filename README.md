# What to Do Today

macOS 바탕화면에서 할 일을 기록하고 완료하는 앱입니다.

P0는 할 일 추가·수정·삭제·완료 취소와 시스템 위젯을 제공합니다. 미완료 항목은 최근 추가한 순서, 완료 항목은 최근 완료한 순서로 표시합니다. 위젯에서는 고정된 크기 안에서 이전·다음 페이지를 탐색합니다.

지원 목표는 macOS 27.0.1 이상입니다. P2까지 모든 정보는 Mac에 로컬로 저장합니다.

## 개발 및 실행

`WhatToDoToday.xcodeproj`를 Xcode에서 열고 `WhatToDoToday` 스킴을 실행합니다. 앱의 Signing & Capabilities에서 사용할 개발 팀을 선택하고 `group.com.choubung.whattodotoday` App Group을 등록합니다. 앱은 App Group의 `Tasks.sqlite` 파일에 저장합니다.

메인 창에서 할 일을 추가하고 체크박스로 완료하거나 완료를 취소합니다. 행의 메뉴에서 제목을 수정하거나 삭제합니다. `⌘N`은 작은 입력 창을, `⌘1`은 목록 창을 엽니다. `whattodotoday://add` URL로도 입력 창을 열 수 있습니다.

## 검증

```sh
bash Scripts/check.sh
```

이 명령은 로컬 저장소의 동시 저장, 완료 재시도, Unicode, 삭제, 페이지 경계 테스트와 Swift 6 타입 검사를 실행합니다. Command Line Tools로 실행할 수 있습니다.

Xcode 빌드는 다음 명령으로 확인합니다.

```sh
xcodebuild -project WhatToDoToday.xcodeproj -scheme WhatToDoToday \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

바탕화면 설치와 App Group 접근 확인은 개발 팀으로 서명한 앱에서 수행해야 합니다. 실행 검수는 macOS 27.0.1과 출시 시점의 최신 정식 macOS에서 진행합니다.
