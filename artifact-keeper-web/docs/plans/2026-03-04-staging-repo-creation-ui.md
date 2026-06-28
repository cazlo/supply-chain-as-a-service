# Staging Repo Creation UI - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow users to create staging repositories through the web UI's create repository dialog.

**Architecture:** Add "Staging" to the existing type dropdown, show an inline hint when selected, and display a post-creation toast linking to the /staging page for promotion rule configuration.

**Tech Stack:** Next.js 15, React, TypeScript, sonner (toast), shadcn/ui

---

### Task 1: Add Staging to TYPE_OPTIONS

**Files:**
- Modify: `src/app/(app)/repositories/_lib/constants.ts:74-78`

**Step 1: Add the staging option**

In `constants.ts`, add staging to the `TYPE_OPTIONS` array after "Local":

```ts
export const TYPE_OPTIONS: { value: RepositoryType; label: string }[] = [
  { value: "local", label: "Local" },
  { value: "staging", label: "Staging" },
  { value: "remote", label: "Remote" },
  { value: "virtual", label: "Virtual" },
];
```

**Step 2: Verify the build**

Run: `cd /Users/khan/ak/artifact-keeper-web && npx tsc --noEmit`
Expected: No errors (RepositoryType already includes `'staging'` in `src/types/index.ts`)

**Step 3: Commit**

```bash
git add src/app/(app)/repositories/_lib/constants.ts
git commit -m "feat: add staging to repository type options"
```

---

### Task 2: Add inline hint for staging type

**Files:**
- Modify: `src/app/(app)/repositories/_components/repo-dialogs.tsx:256-313`

**Step 1: Add staging hint after the type selector grid**

After the closing `</div>` of the grid (line 256), before the remote repo upstream URL section (line 257), add:

```tsx
            {/* Staging repository: inline hint */}
            {createForm.repo_type === "staging" && (
              <p className="text-xs text-muted-foreground">
                Staging repos hold artifacts for review before promotion to a release repository.
                Configure promotion rules after creation.
              </p>
            )}
```

**Step 2: Verify the build**

Run: `cd /Users/khan/ak/artifact-keeper-web && npx tsc --noEmit`
Expected: No errors

**Step 3: Commit**

```bash
git add src/app/(app)/repositories/_components/repo-dialogs.tsx
git commit -m "feat: show inline hint when staging type is selected"
```

---

### Task 3: Add post-creation toast with staging link

**Files:**
- Modify: `src/app/(app)/repositories/page.tsx:102-108`

**Step 1: Update the createMutation onSuccess callback**

The current onSuccess at line 104 shows a generic toast. Update it to show a staging-specific toast with an action link when the created repo is staging type:

```tsx
  const createMutation = useMutation({
    mutationFn: (d: CreateRepositoryRequest) => repositoriesApi.create(d),
    onSuccess: (_data, variables) => {
      invalidateAllRepoQueries();
      setCreateOpen(false);
      if (variables.repo_type === "staging") {
        toast.success("Repository created", {
          description: "Configure promotion rules to start promoting artifacts.",
          action: {
            label: "Go to Staging",
            onClick: () => router.push("/staging"),
          },
        });
      } else {
        toast.success("Repository created");
      }
    },
    onError: (err) => {
      toast.error(getErrorMessage(err, "Failed to create repository"));
```

Note: `router` is already imported and available (line 4: `const router = useRouter()`). The `variables` parameter gives access to the mutation input. Sonner's `toast.success` supports `description` and `action` fields.

**Step 2: Verify the build**

Run: `cd /Users/khan/ak/artifact-keeper-web && npx tsc --noEmit`
Expected: No errors

**Step 3: Commit**

```bash
git add src/app/(app)/repositories/page.tsx
git commit -m "feat: show staging-specific toast with link after creation"
```

---

### Task 4: Verify type filter includes staging

**Files:** None (verification only)

**Step 1: Check the repo list type filter**

Read `src/app/(app)/repositories/page.tsx` and find the type filter dropdown. Verify it already uses `TYPE_OPTIONS` from constants (which now includes staging). If it uses a hardcoded list instead, update it to use `TYPE_OPTIONS`.

**Step 2: Check the repo list badge colors**

Read `src/lib/utils.ts` and verify `REPO_TYPE_COLORS` includes a `staging` entry. It should already have one (purple).

**Step 3: Commit (only if changes were needed)**

---

### Task 5: Manual testing checklist

Run the dev server and verify:

1. Open Create Repository dialog, confirm "Staging" appears in the Type dropdown
2. Select "Staging" type, confirm the inline hint text appears
3. Select "Remote" type, confirm the hint disappears and Upstream URL appears
4. Select "Staging" again, confirm Upstream URL is hidden
5. Create a staging repo (key: "test-staging", format: "maven"), confirm the toast shows with "Go to Staging" action
6. Click "Go to Staging" in the toast, confirm navigation to /staging
7. Verify the staging repo appears in /repositories list with purple badge
8. Verify the staging repo appears in /staging page
9. Create a local repo, confirm the generic "Repository created" toast (no staging link)
