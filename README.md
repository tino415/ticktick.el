# ticktick.el

[![MELPA](https://melpa.org/packages/ticktick-badge.svg)](https://melpa.org/#/ticktick)
[![MELPA Stable](https://stable.melpa.org/packages/ticktick-badge.svg)](https://stable.melpa.org/#/ticktick)

ticktick.el enables two-way synchronization between [TickTick](https://ticktick.com), a popular task management app, and Emacs Org Mode. This is a newer project, so you might wish to [backup your TickTick data](https://help.ticktick.com/articles/7055781405648748544).

![alt text](screenshot.png)

## Features

- **Bidirectional sync**
- **OAuth2 authentication**
- **Preserves task metadata**: priorities, due dates, completion status, descriptions, tags
- **Project-based organization** matching TickTick's structure
- **Automatic syncing** on focus changes or timer-based intervals
- **Tag synchronization** using Org mode's native tag syntax

## Installation

### Manual
1. Clone this repository:
   ```bash
   git clone https://github.com/polhuang/ticktick.el.git
   ```

2. Add to your Emacs configuration:
   ```elisp
   (add-to-list 'load-path "/path/to/ticktick.el")
   (require 'ticktick)
   ```

### From MELPA

Add to your Emacs configuration:
```elisp
(use-package ticktick
  :ensure t)

```

### 
## Setup

### 1. Register TickTick OAuth Application

1. Go to https://developer.ticktick.com
2. Create a new OAuth application
3. Set the redirect URI to: `http://localhost:8080/ticktick-callback`
4. Note your Client ID and Client Secret

### 2. Configure Credentials

```elisp
(setq ticktick-client-id "your-client-id"
      ticktick-client-secret "your-client-secret")
```

Instead of hard-coding your client secret into your configuration, storing it with [auth-source](https://www.gnu.org/software/emacs/manual/html_mono/auth.html) is recommended.

### 3. Authorize Application

```
M-x ticktick-authorize
```

This will open your browser for OAuth consent and automatically capture the authorization.

### 4. Perform Initial Sync

```
M-x ticktick-sync
```

## Usage

### Main Commands

| Command | Description |
|---------|-------------|
| `ticktick-sync` | Full bidirectional sync |
| `ticktick-fetch-to-org` | Pull tasks from TickTick to Org |
| `ticktick-push-from-org` | Push Org tasks to TickTick |
| `ticktick-authorize` | Set up OAuth authentication |
| `ticktick-refresh-token` | Manually refresh auth token |
| `ticktick-toggle-sync-timer` | Toggle automatic timer-based syncing |

### Org File Structure

Tasks are stored in `~/.emacs.d/ticktick/ticktick.org` with this structure:

```org
* Project Name
:PROPERTIES:
:TICKTICK_PROJECT_ID: abc123
:END:
** TODO Task Title [#A]
DEADLINE: <2024-01-15 Mon>
:PROPERTIES:
:TICKTICK_ID: def456
:TICKTICK_ETAG: xyz789
:SYNC_CACHE: hash
:LAST_SYNCED: 2024-01-15T10:30:00+0000
:END:
Task description content here.
```

## Configuration

### Key Variables

```elisp
;; Path to the org file for tasks (default: ~/.emacs.d/ticktick/ticktick.org)
(setq ticktick-sync-file "/path/to/your/ticktick.org")

;; Directory for storing tokens and data (default: ~/.emacs.d/ticktick/)
(setq ticktick-dir "/path/to/ticktick/data/")

;; Enable automatic syncing on focus changes (default: nil)
(setq ticktick--autosync t)

;; Enable automatic syncing every N minutes (default: nil)
(setq ticktick-sync-interval 30)

;; Port for OAuth callback server (default: 8080)
(setq ticktick-httpd-port 8080)

;; Pull tasks that are already completed into the org file (default: nil)
(setq ticktick-import-completed-tasks t)

;; Org keyword for tasks marked "won't do" (default: "CANCELLED")
(setq ticktick-wont-do-keyword "CANCELLED")
```

### Completed Tasks

Completing a task in TickTick marks it `DONE` in Org on the next sync.

Tasks that were already completed before Org ever saw them are left out by
default, so syncing a long-running project does not pull in its whole
history. Set `ticktick-import-completed-tasks` to `t` if you want them.

Tasks marked "won't do" in TickTick become `CANCELLED` in Org, and back
again on the way out. Org does not know that keyword by default, so a
`#+TODO: TODO | DONE CANCELLED` line is added to the top of the sync file
the first time one shows up — without it, Org would read `CANCELLED` as the
first word of the task's title. Change the keyword with
`ticktick-wont-do-keyword`.

### Automatic Syncing

Enable automatic syncing with one of these methods:

**Focus-based syncing** (syncs when switching buffers or losing focus):
```elisp
(setq ticktick--autosync t)
```

**Timer-based syncing** (syncs every N minutes):
```elisp
(setq ticktick-sync-interval 30)  ; Sync every 30 minutes
```

You can also toggle timer syncing interactively:
```
M-x ticktick-toggle-sync-timer
```

## Task Management

### Creating Tasks

Create tasks by just adding a `TODO` heading directly in your org file under any project heading:

```org
* Work Project
:PROPERTIES:
:TICKTICK_PROJECT_ID: project123
:END:
** TODO Review quarterly reports [#A]
DEADLINE: <2024-01-20 Sat>
Need to analyze Q4 performance metrics and prepare summary.
```

Run `M-x ticktick-push-from-org` to sync to TickTick.

### Task Priorities

Org priorities are mapped to TickTick priorities.

- `[#A]` - High priority
- `[#B]` - Normal priority  
- `[#C]` - Low priority
- No priority - Normal priority

### Task Status

- `TODO` - Open task
- `DONE` - Completed task
- `CANCELLED` - Marked "won't do" in TickTick

### Subtasks

By default a heading nested under a task is treated as part of that task's
description — the long-standing behaviour. TickTick shows the nested
headings as text and no subtask is created.

Set `ticktick-subheading-behavior` to `subtask` to make nesting real:

```elisp
(setq ticktick-subheading-behavior 'subtask)
```

Then a level-3 heading is a TickTick subtask of the level-2 task above it,
nesting survives in both directions, and the child's text is no longer part
of its parent's description:

```org
** TODO Plan trip
:PROPERTIES:
:TICKTICK_ID: abc123
:END:
notes that stay with the parent
*** TODO Book flights
:PROPERTIES:
:TICKTICK_ID: def456
:TICKTICK_PARENT_ID: abc123
:END:
```

Two things to know before switching. Nested headings you already have will
move out of their parent's descriptions and be created as real tasks on the
next sync. And a subtask's parent is set when the task is created — moving a
heading under a different parent afterwards is not yet sent to TickTick.

A subtask whose parent is missing from TickTick's response — completed,
deleted, or beyond the API's 200-task reply limit — is shown at the top
level rather than hidden.

### Checklists

A TickTick checklist arrives as an org checkbox list under the task, ordered
as TickTick orders it:

```org
** TODO Shopping
:PROPERTIES:
:TICKTICK_ID: abc123
:TICKTICK_KIND: CHECKLIST
:END:
- [ ] bread
- [X] milk
```

This is currently one-way: the items are shown, but ticking a box in Org
does not tick it in TickTick. The list is not sent back as the task's
description, and the items held by TickTick are left untouched, so nothing
is lost by syncing a checklist — its items simply follow whatever TickTick
says. Editing the rest of the task works as normal.

### Tags

Tags are synchronized between TickTick and Org mode using Org's native tag syntax:

```org
** TODO Task with tags [#A]     :work:urgent:
DEADLINE: <2024-01-20 Sat>
Task description here.
```

Tags from TickTick are automatically converted to Org tags, and any tags you add to tasks in Org will be synced back to TickTick.

## Development

### Tests

The test suite replays real API responses, recorded from a dedicated TickTick
project, through a local [WireMock](https://wiremock.org) instance. Nothing
talks to the live service, so the tests need no account and no credentials.

```bash
make test      # ERT suite against the recorded responses
make lint      # byte-compile (must be warning-free) and checkdoc
make           # both
```

`make test` needs `wiremock` on `PATH`, or `WIREMOCK_CMD` pointing at one:

```bash
WIREMOCK_CMD='java -jar wiremock-standalone.jar' make test
```

The fixtures live in `tests/wiremock/` and are committed. To re-record them
against a real account — after adding a case to the source project, or when
the API changes — see the instructions at the top of `tests/record.el`. Only
the target project is written out, so an account's other projects never reach
the repository.
