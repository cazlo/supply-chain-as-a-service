# Add Staging Repository Creation to UI

**Issue:** https://github.com/artifact-keeper/artifact-keeper-web/issues/123
**Date:** 2026-03-04

## Problem

Users cannot create staging repositories through the web UI. The create repository dialog only offers Local, Remote, and Virtual types, even though the backend fully supports staging as a repository type. Users must use the API directly to create staging repos.

## Design Decisions

- **Two-step workflow**: Create the staging repo first, configure promotion rules separately. Matches how the backend works (promotion_target_id and promotion_policy_id are always NULL at creation).
- **Visible in both places**: Staging repos appear in the main /repositories list (with existing purple badge) and the dedicated /staging page.
- **Brief inline hint**: When "Staging" is selected in the type dropdown, show a one-line hint explaining what staging repos are and that promotion rules are configured after creation.
- **Post-creation toast**: After successful creation, show a toast with a link to configure promotion rules on the /staging page.

## Changes

### 1. constants.ts - Add staging to TYPE_OPTIONS

Add `{ value: 'staging', label: 'Staging' }` to the TYPE_OPTIONS array after "Local". Staging repos are writable like local repos, so grouping them together is logical.

### 2. repo-dialogs.tsx - Form behavior for staging type

When `repo_type === 'staging'`:
- Hide "Upstream URL" field (same as local)
- Hide "Member Repositories" section (same as local)
- Show inline hint text below the type selector: "Staging repos hold artifacts for review before promotion to a release repository. Configure promotion rules after creation."

On successful creation of a staging repo, show a toast:
- Message: "Repository created. Configure promotion rules to start promoting artifacts."
- Action link pointing to `/staging`

### 3. No backend changes needed

The `POST /api/v1/repositories` endpoint already accepts `repo_type: "staging"`. The `parse_repo_type()` function handles it. No new fields are required at creation time.

### 4. No repo list changes needed

The repo list already supports all four types:
- Type filter dropdown queries the API with `?type=staging`
- Purple badge styling exists in REPO_TYPE_COLORS
- Staging repos render correctly when returned by the API

## Files to Modify

| File | Change |
|------|--------|
| `src/app/(app)/repositories/_lib/constants.ts` | Add staging to TYPE_OPTIONS |
| `src/app/(app)/repositories/_components/repo-dialogs.tsx` | Inline hint + post-creation toast |

## Testing

- Create a staging repo via the UI, verify it appears in /repositories and /staging
- Verify the inline hint shows only when "Staging" is selected
- Verify the toast appears with a working link after creation
- Verify switching between types hides/shows the correct fields
- Verify the type filter on /repositories includes staging repos
