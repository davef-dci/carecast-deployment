# Deploying CareCast

Two targets now: **production** (`carecast-v2`) and **sandbox** (`carecast-sandbox`). Same
script, `deploy-v2.ps1`, run from the repo root either way — the difference is which
parameters you pass. No parameters = production, unchanged from before.

## Environments at a glance

This file only covers the two *deployed* (Cloud Run + Hosting) targets below. There are
three more, all run locally via the root `package.json` — worth knowing about so you pick
the cheapest one that actually tests what you're changing:

| Command                  | Runs where       | Talks to                                    |
|---------------------------|------------------|----------------------------------------------|
| `npm run start`           | Local processes  | Real **prod** Firestore/Storage (`carecast-v2`) |
| `npm run start:sandbox`   | Local processes  | Real **sandbox** Firestore/Storage (`carecast-sandbox`) |
| `npm run start:emulated`  | Local processes  | **Local** Firestore + Storage emulator, seeded from a gitignored real-data snapshot — no cloud project touched |
| `deploy-v2.ps1 -ProjectId carecast-sandbox ...` | Cloud Run + Hosting | Real **sandbox** Firestore/Storage |
| `deploy-v2.ps1` (no params) | Cloud Run + Hosting | Real **prod** Firestore/Storage — the actual release |

The emulator isn't a "safer sandbox" — sandbox is safe too, now that it's a real, isolated
project. The emulator's actual value is different: zero cost, no network, and an instant
reset (`emulators:fresh` wipes state; `emulators` re-imports the snapshot), which makes it
the right choice for anything destructive or repetitive — dry-running a migration script,
churning test data, a tight edit/test loop — without leaving junk behind in an environment
other testing (or a real guest) might be using at the same time.

What it *can't* test is real infrastructure: Cloud Run, Hosting rewrites, CORS, Firebase
Auth against a real authorized-domains list, IAM/service-account permissions, real Storage
URLs. Every sandbox-deploy bug fixed while standing this up (wrong Firebase project baked
into the build, a missing CORS origin, three IAM grants) was in that category — the
emulator is structurally incapable of catching it, since none of that infrastructure exists
in emulator-land. Sandbox and the emulator test disjoint failure modes; keep using both.

## One-time setup (per machine)

Fill in `Secrets\set-deploy-secrets.ps1` with your real credentials (Anthropic key, cron
secret, admin emails, Gmail sender + app password, Google OAuth client id/secret). That
file is gitignored — it never leaves your machine. See the comments in the file itself for
where each value comes from.

## Every deploy session

```powershell
cd D:\software_projects\CareCast
. .\Secrets\set-deploy-secrets.ps1
firebase login --reauth
```

`firebase login --reauth` in practice is needed before basically every deploy session, not
just after a long gap — do it every time rather than skipping it and finding out partway
through a deploy.

The leading `. ` before the secrets script matters — it "dot-sources" it so the variables
land in your current shell instead of a throwaway child process.

## Deploy production

```powershell
.\deploy-v2.ps1
```

That's it — same one-liner as always. Every parameter it needs defaults to the exact
production values (`carecast-v2`, `care-cast-api-v2`, `app.carecast.app`, etc.), so this
behaves identically to every prod deploy before sandbox support existed.

### Deploying more than once in a day

`$CareCastRelease` defaults to `yyyy.MM.dd-a` — date only, no time. A second prod deploy
on the same calendar day silently reuses the exact same release label as the first (no
error, no warning) unless you override it, which makes the two deploys indistinguishable
later when you're trying to figure out which one shipped a given regression. Bump the
suffix by hand for any repeat deploy:

```powershell
.\deploy-v2.ps1 -CareCastRelease "2026.09.09-b"
```

`-WebappRelease` and `-ApiRelease` each fall back to `-CareCastRelease` when not set
separately, so passing just that one flag is enough — pass the other two too only if you
want the API and webapp release strings to diverge (e.g. an API-only hotfix).

## Deploy sandbox

```powershell
.\deploy-v2.ps1 `
  -ProjectId carecast-sandbox `
  -ApiService care-cast-api-sandbox `
  -WebAppUrl https://carecast-sandbox.web.app `
  -ClientUrl https://carecast-sandbox.web.app `
  -StorageBucket carecast-sandbox.firebasestorage.app `
  -ServiceAccount firebase-adminsdk-fbsvc@carecast-sandbox.iam.gserviceaccount.com `
  -HostingTarget sandbox-app `
  -WebappBuildScript build:sandbox
```

`-WebappBuildScript build:sandbox` matters and is easy to forget: Vite selects which
`.env.<mode>` file to load by *build mode*, not by anything this script passes as a
project id. Without it, the webapp builds in the default "production" mode and bakes in
`care-cast-webapp/.env`'s Firebase client config -- which is `carecast-v2`'s (prod)
`apiKey`/`authDomain`/etc. The site *looks* fine (loads, styled correctly) but Google
Sign-In fails with `auth/unauthorized-domain`, because the deployed page is secretly
asking prod's Firebase project "is carecast-sandbox.web.app allowed?" instead of asking
sandbox's. `care-cast-webapp/.env.sandbox` already has the correct sandbox values --
`build:sandbox` (`vite build --mode sandbox`) is what tells Vite to use it.

Verify at `https://carecast-sandbox.web.app` afterward.

### First time / debugging a sandbox deploy

Split it into two runs instead of one, so a problem shows up at the cheaper step:

```powershell
# Step A -- API only. Deploys, then calls its own /health endpoint and confirms
# the release/revision match what was just deployed -- fails loudly here if
# something (a secret, the service account's permissions) is wrong. Still builds
# the webapp locally even though it isn't deployed yet (only -SkipLocalBuild
# skips that) -- keep -WebappBuildScript here too, since Step B's -SkipLocalBuild
# trusts whatever Step A already built.
.\deploy-v2.ps1 -ProjectId carecast-sandbox -ApiService care-cast-api-sandbox `
  -WebAppUrl https://carecast-sandbox.web.app -ClientUrl https://carecast-sandbox.web.app `
  -StorageBucket carecast-sandbox.firebasestorage.app `
  -ServiceAccount firebase-adminsdk-fbsvc@carecast-sandbox.iam.gserviceaccount.com `
  -HostingTarget sandbox-app -WebappBuildScript build:sandbox -SkipWebDeploy

# Step B -- webapp only, once Step A is green. -SkipLocalBuild skips rebuilding
# since Step A just built it (in the right mode); drop that flag to rebuild anyway
# (keep -WebappBuildScript build:sandbox if you do).
.\deploy-v2.ps1 -ProjectId carecast-sandbox -WebAppUrl https://carecast-sandbox.web.app `
  -ClientUrl https://carecast-sandbox.web.app -HostingTarget sandbox-app `
  -SkipApiDeploy -SkipLocalBuild
```

## Why this is safe — prod and sandbox can't cross-contaminate

- **Every cloud-facing line in `deploy-v2.ps1` reads from a parameter, never a hardcoded
  value.** Passing `-ProjectId carecast-sandbox` genuinely redirects every `gcloud`/
  `firebase` call the script makes; nothing "defaults back" to prod partway through.
- **Google Cloud's project boundary is a hard wall.** A Cloud Run service named
  `care-cast-api-v2` living inside `carecast-sandbox` would be a completely different
  resource from the one inside `carecast-v2` — there's no cross-project name collision
  possible, enforced by Google's API itself, not by this script's discipline.
- **`firebase.json` has two independent hosting targets** — `app` (prod, rewrites
  `/api/**` to the prod Cloud Run service) and `sandbox-app` (sandbox, rewrites to the
  sandbox service). `.firebaserc` maps `sandbox-app` only under the `carecast-sandbox`
  project entry. A mismatched combination (e.g. `-ProjectId carecast-v2 -HostingTarget
  sandbox-app`) errors out immediately rather than silently deploying to the wrong place.
- **The webapp build itself is target-agnostic.** It never bakes in a specific API URL
  (`VITE_API_URL` is deliberately cleared before every build) — it always calls a
  relative `/api` path, and the Hosting rewrite decides which Cloud Run service answers
  that. Same build artifact is safe to deploy to either target.

Net effect: if you ever get a parameter wrong, the failure mode is either "it errors
loudly" or "it just deployed prod again" (if you forgot to override the prod defaults) —
never a silent mix of the two environments.

- **`-Memory` defaults to `2Gi`, matching prod.** `gcloud run deploy` preserves whatever a
  service is already configured with for any flag you don't pass, which is exactly how
  prod ended up staying at `2Gi` deploy after deploy despite this script never mentioning
  memory at all — that value was set once, outside the script, long before sandbox existed.
  A brand-new service has no such history to inherit from, so sandbox launched at Cloud
  Run's bare platform default of `512Mi` and stayed there until a parallel 5-page publish
  (Personal Events testing, 2026-09-12) OOM-killed the container mid-request. Passing
  `--memory` explicitly means a fresh environment always starts at the same footprint as
  prod instead of silently inheriting nothing.

## What sandbox does NOT have yet (deferred, not needed for current testing)

- `-ApiBaseUrl` and `-GoogleRedirectUri` are left at their **prod** defaults for sandbox
  deploys so far. Neither affects Guest Greetings or Personal Events testing (they matter
  for absolute icon URLs and "Connect Google Calendar" OAuth respectively) — revisit if a
  later test needs Calendar OAuth working on sandbox.
