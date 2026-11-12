# 빌드 및 설치

## 위젯 포함 앱 직접 설치

macOS 27.0.1 이상과 macOS 27 SDK를 포함한 Xcode가 필요합니다. [v1.3.5 소스 ZIP](https://github.com/choubung/what-to-do-today/archive/refs/tags/v1.3.5.zip)을 받고 압축을 푸세요. Xcode의 **Settings → Accounts**에서 Apple 계정을 추가합니다. 본인 Mac에 빌드할 때는 무료 **Personal Team**을 사용할 수 있으며 개발용 프로파일이 만료되면 다시 빌드합니다.

저장소 루트에 `Signing.xcconfig`를 만들고 Xcode 계정의 Team ID를 입력합니다.

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

이 파일은 Git에서 제외됩니다. 공통 `Configuration.xcconfig`가 이를 읽어 앱과 `TodoWidget`의 Debug·Release 빌드에 같은 팀을 적용합니다. Xcode와 명령줄 빌드 모두 이 설정을 사용합니다.

`WhatToDoToday.xcodeproj`를 Xcode에서 열고 `WhatToDoToday` 스킴을 빌드합니다. 두 타깃의 Signing & Capabilities에서 자동 서명과 `group.com.choubung.whattodotoday` App Group을 확인합니다. 앱과 위젯은 App Group의 `Tasks.sqlite` 파일을 함께 사용합니다.

Xcode에서 **Product → Build**를 선택한 뒤 **Products → What to Do Today.app**을 우클릭하고 **Show in Finder**를 선택합니다. 저장소에서 아래 명령을 실행하고 Finder에 표시된 앱 경로를 넘겨 주세요.

```sh
bash Scripts/install.sh "/path/to/What to Do Today.app"
```

업데이트 전에는 앱을 `⌘Q`로 종료하세요. 설치 도구는 서명된 앱과 위젯을 `/Applications`에 설치하고 위젯 확장을 등록합니다. 그 경로에서 실행 중인 이전 위젯을 종료한 뒤 앱을 열어 WidgetKit에 갱신을 요청합니다. 같은 개발 팀으로 빌드해 업데이트하면 기존 App Group 저장소를 계속 사용합니다. 앱을 연 뒤 바탕화면의 **위젯 편집**에서 **할 일**을 추가합니다.

## 위젯 없는 DMG 만들기

Apple Silicon Mac에서 실행합니다. 스크립트는 `WhatToDoTodayStandalone` 스킴을 Release로 빌드하고, 위젯을 포함하지 않는 앱과 응용 프로그램 바로가기를 DMG에 담습니다. 개발 팀 설정과 유료 멤버십은 필요 없습니다.

```sh
bash Scripts/build-dmg.sh "./WhatToDoToday-1.3.5.dmg"
```

두 스킴의 버전과 빌드 번호는 `Configuration.xcconfig`에서 함께 관리합니다. DMG에는 Apple 공증이 적용되지 않습니다. DMG 설치와 기존 할 일 이동은 [README의 설치 방법](../README.md#설치하고-시작하기)을 따르세요.

## 검증

앱 아이콘은 오른쪽 아래 모서리가 접힌 연한 노란 포스트잇입니다. 원본은 `App/Resources/AppIcon.png`, 앱에 포함되는 파일은 `App/Resources/AppIcon.icns`입니다. 원본을 바꾼 뒤 `bash Scripts/build-icon.sh`로 16–1024px 표현을 다시 만들 수 있습니다. 생성 프롬프트는 `App/Resources/AppIcon.source.json`에 기록합니다.

```sh
bash Scripts/check.sh
```

이 명령은 최초 동시 실행·동시 저장·완료 재시도·Unicode·삭제·페이지 경계, 기존 데이터베이스의 포스트잇 상태 확장·복원·완료/삭제 연동, 두 설치 방식 간 데이터 이동 및 실패 시 복구, 다중 화면 위치 보정 테스트와 Swift 6 타입 검사를 실행합니다. Command Line Tools로 실행할 수 있습니다.

Xcode 빌드는 다음 명령으로 확인합니다.

```sh
xcodebuild -project WhatToDoToday.xcodeproj -scheme WhatToDoToday \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

바탕화면 설치와 App Group 접근 확인은 개발 팀으로 서명한 앱에서 수행해야 합니다.
