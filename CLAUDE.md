# Working in this repo

Hosts install these scripts straight from `main` over HTTPS. **`main` is the
release** — there is no staging branch and no publish step, so pushing is
deploying.

## You cannot push to `main`

Branch protection, no bypass. Open a pull request; the `check` status must be
green before it can merge. No approving review is required, so you can merge
your own once CI passes (~20s).

```bash
git config core.hooksPath .githooks      # once per clone: runs the checks locally
git checkout -b your-change
gh pr create --fill
gh pr merge --auto --squash --delete-branch
```

## `scripts/supabase-backup/` — the rule that is not enforced

Versions are `<major>.<minor>` (e.g. `1.3`) and **the commit is the patch
level**. A change that does not touch `VERSION` is a patch by definition.

That is load-bearing. Hosts can be set to install patches by themselves, and at
least one is:

> **A commit that leaves `VERSION` alone is a production deploy, unattended,
> within twelve hours.**

So:

| Your change | `VERSION` | Also needed |
|---|---|---|
| fix, tweak, refactor | leave it | a commit subject worth reading — the console shows it under "What's new" |
| new feature or behaviour change | bump minor | a `## <version>` entry in `scripts/supabase-backup/CHANGELOG.md` |
| needs someone to act on the host | bump major | same |

**When in doubt, bump.** The cost is that someone clicks a button. The cost of
the other mistake is your change installing itself on a backup server while
nobody is watching.

`release-check` enforces the version *format* and the changelog entry, and CI
blocks the merge if either is wrong. It cannot tell whether your change
deserved a bump. That judgement is the one thing here with nothing behind it
but you.

## Adding a file to `scripts/supabase-backup/`

It must also go in `CORE_FILES` or `WEB_FILES` in `scripts/supabase-backup/upgrade`,
or no host will ever receive it while every upgrade still reports success.
`release-check` catches this — run it before you push:

```bash
scripts/supabase-backup/release-check
```

An upgrade never deletes, either: removing a file from the repo leaves it on
every host that already has it.

Full detail: `scripts/docs/supabase-backup.md` § "Changing it".
