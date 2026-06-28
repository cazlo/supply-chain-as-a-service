# Tutorial Recording Infrastructure Design

## Purpose

Build a Playwright-based tutorial recording system that generates YouTube-ready video content from scripted UI walkthroughs of the Artifact Keeper web UI. The system captures MP4 recordings, screenshots at key steps, and narration scripts for AI voiceover.

## Audience

Mixed: new users evaluating the product (overview/intro videos) and existing admins configuring their instance (how-to guides).

## Architecture

### Separate config, shared infrastructure

A dedicated `playwright-tutorials.config.ts` sits at the web project root. It imports shared page objects and fixtures from `e2e/fixtures/` but runs independently from the test suite. Tutorial scripts live in `e2e/tutorials/` and produce output to `e2e/tutorials/output/` (gitignored).

### Config differences from E2E tests

| Setting | E2E Tests | Tutorials |
|---------|-----------|-----------|
| Video | `off` (trace on retry) | `on` always |
| Viewport | 1280x720 (Desktop Chrome) | 1920x1080 (YouTube 1080p) |
| Screenshot | only-on-failure | manual at key steps |
| Workers | parallel | 1 (sequential, one at a time) |
| Timeouts | 30s default | 120s (flows are slow and deliberate) |
| Base URL | same Tailscale instance | same |
| Auth | admin storage state | admin storage state |

### Tutorial script anatomy

Each `.tutorial.ts` file defines a single tutorial video. It uses a `TutorialHelper` class that wraps common patterns:

- `helper.pause(ms)` - deliberate delay so viewers can follow
- `helper.chapter(name)` - marks a chapter boundary with timestamp
- `helper.step(name)` - captures a screenshot and logs a narration cue
- `helper.narrate(text)` - records narration text with current timestamp for AI TTS script generation

Scripts do NOT use assertions. They are recordings, not tests. They use page objects for navigation but add deliberate pacing between actions.

### Output structure

```
e2e/tutorials/output/
  manifest.json                          # All tutorials with metadata
  01-getting-started/
    recording.webm                       # Playwright video capture
    narration-script.md                  # Timestamped narration for AI TTS
    screenshots/
      step-01-login-page.png
      step-02-dashboard-overview.png
      ...
  02-create-repositories/
    recording.webm
    narration-script.md
    screenshots/
      ...
```

### Manifest format

```json
{
  "tutorials": [
    {
      "id": "01-getting-started",
      "title": "Getting Started with Artifact Keeper",
      "description": "Log in, explore the dashboard, and navigate the main sections of Artifact Keeper.",
      "chapters": [
        { "time": "0:00", "name": "Login" },
        { "time": "0:32", "name": "Dashboard Overview" },
        { "time": "1:15", "name": "Navigation Tour" }
      ],
      "outputDir": "01-getting-started",
      "thumbnailScreenshot": "step-02-dashboard-overview.png"
    }
  ]
}
```

### Seed data

Reuses the existing `seedAll()` from `e2e/setup/seed-data.ts` for base data (users, groups). Adds a tutorial-specific seed module (`tutorial-seed.ts`) that creates more realistic-looking content:

- Repositories with production-style names (`maven-releases`, `npm-proxy`, `docker-hub-proxy`, `company-virtual`)
- Pre-populated with realistic descriptions
- Quality gates and lifecycle policies with meaningful thresholds

### Narration pipeline

1. Tutorial scripts call `helper.narrate("Click Create Repository to set up a new local Maven repository.")`
2. Each call stores `{ timestamp, text }` in memory
3. After the tutorial finishes, the helper writes `narration-script.md` with timestamped entries
4. The markdown file gets fed to ElevenLabs / similar TTS service externally
5. Audio is synced with video in Clueso or a video editor

The Playwright infrastructure does NOT do TTS itself. It produces the script. Audio generation and video compositing happen externally.

## Tutorial set (6 videos)

| # | File | Title | Duration est. | Key flows |
|---|------|-------|---------------|-----------|
| 1 | `01-getting-started.tutorial.ts` | Getting Started with Artifact Keeper | 2-3 min | Login, dashboard tour, sidebar navigation |
| 2 | `02-create-repositories.tutorial.ts` | Creating Repositories | 3-4 min | Create local Maven, remote NPM, virtual Docker repos |
| 3 | `03-proxy-setup.tutorial.ts` | Setting Up a Proxy Repository | 3-4 min | Create NPM proxy, configure upstream URL, browse proxied packages |
| 4 | `04-virtual-repositories.tutorial.ts` | Virtual Repositories | 3-4 min | Create virtual repo, add local + proxy sources, explain resolution |
| 5 | `05-security-quality-gates.tutorial.ts` | Security Scanning and Quality Gates | 3-4 min | Security dashboard, view scan results, create quality gate |
| 6 | `06-user-management.tutorial.ts` | User Management and Access Control | 3-4 min | Create users, groups, assign permissions, generate API keys |

## File structure

```
artifact-keeper-web/
  playwright-tutorials.config.ts
  e2e/tutorials/
    fixtures/
      tutorial-helper.ts          # TutorialHelper class (pause, chapter, step, narrate)
      tutorial-seed.ts            # Realistic seed data for tutorials
    scripts/
      generate-manifest.ts        # Post-run: build manifest.json from output dirs
    01-getting-started.tutorial.ts
    02-create-repositories.tutorial.ts
    03-proxy-setup.tutorial.ts
    04-virtual-repositories.tutorial.ts
    05-security-quality-gates.tutorial.ts
    06-user-management.tutorial.ts
    output/                       # gitignored
```

## npm scripts

```json
{
  "tutorial:record": "playwright test --config playwright-tutorials.config.ts",
  "tutorial:record:one": "playwright test --config playwright-tutorials.config.ts -g",
  "tutorial:manifest": "npx tsx e2e/tutorials/scripts/generate-manifest.ts"
}
```

## Dependencies

No new dependencies needed. Playwright already handles video recording and screenshots. The narration script generation is pure TypeScript file I/O.
