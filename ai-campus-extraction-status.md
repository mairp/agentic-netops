# AI Campus Exercise Extraction Status

Date: 2026-09-01

## Goal

Extract all available exercises from:

https://ai-campus-training.vercel.app/core42/profile

Save the extracted material into `/root/ai-champion` as one markdown file per exercise, using the exercise number in the filename. Each exercise file should include the visible instructions and any ready-to-copy prompts.

## Credentials Provided

- Email: `marlon.lopez@core42.ai`
- Training code: `CORE42-SOV26`

## Local Files Observed

- Screenshot provided by user:
  - `/root/ai-champion/Screenshot 2026-09-01 203911.png`
- Target output folder exists:
  - `/root/ai-champion`

## Installed / Available Dependencies

- Node.js is available.
- Playwright is not installed in the current repo at `/root/agentic-netops`.
- Playwright is not installed globally in Node.
- Python Playwright is not installed.
- A usable Node Playwright installation exists at:
  - `/root/agentflow/frontend/node_modules/playwright`
- Playwright Chromium browser binaries exist at:
  - `/root/.cache/ms-playwright/chromium-1223`
  - `/root/.cache/ms-playwright/chromium-1234`
  - `/root/.cache/ms-playwright/chromium_headless_shell-1223`
  - `/root/.cache/ms-playwright/chromium_headless_shell-1234`

## Runtime Notes

- Chromium launch fails inside the managed sandbox with:
  - `FATAL:content/browser/sandbox_host_linux.cc:41`
  - `shutdown: Operation not permitted`
- Playwright commands need elevated execution in this environment.
- Writing final files directly to `/root/ai-champion` also needs elevated execution because the writable workspace root is `/root/agentic-netops`.

## Confirmed Site State

- Unauthenticated access to `/core42/profile` redirects to:
  - `https://ai-campus-training.vercel.app/core42/welcome`
- The screenshot matches the site header navigation.
- Returning-user login works with:
  - Work email: `marlon.lopez@core42.ai`
  - Training code: `CORE42-SOV26`
- After login, these modules are unlocked:
  - `Welcome` -> `/core42/welcome`
  - `You & your ARQ` -> `/core42/profile`
  - `Hands-on AI practice` -> `/core42/guide`
  - `AI in Tech` -> `/core42/industry`
  - `Use case definition` -> `/core42/define`
  - `Use case portfolio` -> `/core42/landscape`
  - `Santander AI` -> `/core42/santander`
  - `Vibe Coding Lab` -> `/core42/vibe`
  - `Second brain` -> `/core42/second-brain`
  - `AI Playground` -> `/core42/playground`
- `Creative Studio` remains locked for this cohort.
- The welcome page reports:
  - 11 modules
  - 37 hands-on exercises
  - 25 industry use cases
  - 2 live AI agents

## Extraction Strategy

1. Start a Playwright Chromium session using the existing Playwright package at `/root/agentflow/frontend/node_modules/playwright`.
2. Log in through the `I've registered before` path on `/core42/welcome`.
3. Persist browser context storage state after login so every module can be opened without repeating login.
4. Visit each unlocked module URL and collect:
   - Page title
   - Main visible text
   - Navigation links
   - Buttons and tabs
   - Expandable sections, accordions, chapter controls, and exercise selectors
5. Prioritize `/core42/guide`, because it appears to contain the numbered hands-on exercise set.
6. For each numbered exercise:
   - Open/select the exercise.
   - Expand any hidden details.
   - Capture the exercise number and title.
   - Extract instructions.
   - Extract prompt blocks or copyable prompt text.
   - Preserve useful module/chapter context.
7. Save one markdown file per exercise in `/root/ai-champion`, using stable filenames such as:
   - `exercise-01-title.md`
   - `exercise-02-title.md`
8. Also save an index file listing all extracted exercises and their source module/page.
9. Download linked training files only if they are part of the exercise materials or useful supporting material. The currently observed downloadable file is:
   - `https://ai-campus-training.vercel.app/files/Core42_AI-Bootcamp-Deck_v1.pdf`

## Pending Work

- Inspect `/core42/guide` after login.
- Enumerate all chapter/exercise controls in the guide.
- Determine whether exercises are rendered all at once, loaded by tab/chapter state, or stored in page data/API responses.
- Extract all 37 available hands-on exercises.
- Check other unlocked modules for additional exercises or prompts:
  - `/core42/industry`
  - `/core42/define`
  - `/core42/santander`
  - `/core42/vibe`
  - `/core42/second-brain`
  - `/core42/playground`
- Save final per-exercise markdown files into `/root/ai-champion`.
- Save an extraction index/manifest.
- Optionally save raw page snapshots/screenshots for auditability.

## Last Known Progress

- Login was successful.
- Unlocked navigation links were confirmed.
- The first attempt to inspect `/core42/guide` was interrupted before completion.
