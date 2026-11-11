# 로컬 MCP 연결

App Group 권한으로 서명된 앱을 설치한 뒤, 같은 Mac의 로컬 MCP 클라이언트에 아래 설정을 추가합니다. 앱을 다른 위치에 설치했다면 `command`를 해당 앱 번들의 실행 파일 경로로 바꿉니다. 클라이언트가 필요할 때 `--mcp` 모드를 시작하며, 표준 입출력(`stdio`)으로 연결합니다.

```json
{
  "mcpServers": {
    "what-to-do-today": {
      "command": "/Applications/What to Do Today.app/Contents/MacOS/What to Do Today",
      "args": ["--mcp"]
    }
  }
}
```

| 할 수 있는 일 | 채팅에서 요청하는 예 | MCP 도구 |
| --- | --- | --- |
| 미완료 목록과 설정된 알림 조회 | “오늘 할 일과 알림을 보여줘.” | `list_open_tasks` |
| 오늘 또는 지정 날짜의 완료 기록 조회 | “어제 끝낸 일 알려줘.” | `list_completed_today`, `list_completed_on` |
| 할 일 추가·제목 수정·삭제 | “‘회의 자료 정리’를 업무에 추가해 줘.” | `add_task`, `update_task`, `delete_task` |
| 완료 또는 완료 취소 | “‘회의 자료 정리’ 완료 처리해 줘.” | `set_task_completed` |
| 알림 설정·변경·해제 | “‘회의 자료 정리’ 내일 오전 10시에 알려줘.” | `set_task_reminder`, `remove_task_reminder` |
| 할 일의 카테고리 이동 | “‘회의 자료 정리’를 프로젝트로 옮겨줘.” | `move_task` |
| 카테고리 조회·생성·이름 변경·삭제 | “업무를 프로젝트로 이름 바꿔줘.” | `list_categories`, `create_category`, `rename_category`, `delete_category` |

할 일을 추가할 때 카테고리를 생략하면 기본 카테고리에 넣습니다. 수정과 이동에는 조회 결과의 ID를 사용합니다. 카테고리를 삭제할 때는 기존 할 일과 완료 기록을 받을 카테고리를 지정합니다.

알림은 Mac의 현지 날짜와 시각을 사용합니다. 알림을 받으려면 What to Do Today에서 알림 권한을 허용하고 앱을 실행해 두거나 로그인 시 자동 실행을 켭니다. MCP에서 저장한 변경은 앱과 위젯이 공유하는 저장소에 반영됩니다.
