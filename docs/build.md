# 직접 빌드하기

macOS 27.0.1 이상과 macOS 27 SDK를 포함한 Xcode가 필요합니다. [GitHub 릴리즈](https://github.com/choubung/what-to-do-today/releases/latest)에서 소스를 받거나 저장소를 복제하세요.

저장소 루트에 `Signing.xcconfig`를 만들고 Xcode 계정의 Team ID를 입력합니다.

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

이 파일은 Git에서 제외됩니다. 공통 `Configuration.xcconfig`가 이를 읽어 앱과 `TodoWidget`의 Debug·Release 빌드에 같은 팀을 적용합니다. Xcode와 명령줄 빌드 모두 이 설정을 사용합니다.

`WhatToDoToday.xcodeproj`를 Xcode에서 열고 `WhatToDoToday` 스킴을 빌드합니다. 두 타깃의 Signing & Capabilities에서 자동 서명과 `group.com.choubung.whattodotoday` App Group을 확인합니다. 앱과 위젯은 App Group의 `Tasks.sqlite` 파일을 함께 사용합니다.

## 설치 및 업데이트

DMG를 받았다면 열고 **Install What to Do Today.command**를 실행하세요. Xcode에서 빌드했다면 저장소에서 아래 명령을 실행하세요.

```sh
bash Scripts/install.sh "/path/to/What to Do Today.app"
```

업데이트 전에는 앱을 `⌘Q`로 종료하세요. 설치 도구는 서명된 앱과 위젯을 `/Applications`에 설치하고 위젯 확장을 등록합니다. 그 경로에서 실행 중인 이전 위젯을 종료한 뒤 앱을 열어 WidgetKit에 갱신을 요청합니다. 앱과 위젯이 사용하는 할 일 저장소는 App Group에 있습니다.

## DMG 만들기

서명된 빌드로 앱과 설치 도구가 들어 있는 DMG를 만듭니다.

```sh
bash Scripts/build-dmg.sh "/path/to/What to Do Today.app" "./WhatToDoToday.dmg"
```

다른 Mac에 배포할 때는 Developer ID로 앱과 위젯을 서명하고 DMG를 서명·공증한 뒤 릴리즈에 첨부합니다. [Apple의 Mac 앱 배포 안내](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

## 검증

앱 아이콘은 오른쪽 아래 모서리가 접힌 연한 노란 포스트잇입니다. 원본은 `App/Resources/AppIcon.png`, 앱에 포함되는 파일은 `App/Resources/AppIcon.icns`입니다. 원본을 바꾼 뒤 `bash Scripts/build-icon.sh`로 16–1024px 표현을 다시 만들 수 있습니다. 생성 프롬프트는 `App/Resources/AppIcon.source.json`에 기록합니다.

```sh
bash Scripts/check.sh
```

이 명령은 최초 동시 실행·동시 저장·완료 재시도·Unicode·삭제·페이지 경계, 기존 데이터베이스의 포스트잇 상태 확장·복원·완료/삭제 연동, 다중 화면 위치 보정 테스트와 Swift 6 타입 검사를 실행합니다. Command Line Tools로 실행할 수 있습니다.

Xcode 빌드는 다음 명령으로 확인합니다.

```sh
xcodebuild -project WhatToDoToday.xcodeproj -scheme WhatToDoToday \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

바탕화면 설치와 App Group 접근 확인은 개발 팀으로 서명한 앱에서 수행해야 합니다. 첫 릴리즈의 빌드와 자동 테스트는 macOS 27.2.1에서 확인했습니다.
