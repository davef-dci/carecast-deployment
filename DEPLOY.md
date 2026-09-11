# Deploying CareCast

Two targets now: **production** (`carecast-v2`) and **sandbox** (`carecast-sandbox`). Same
script, `deploy-v2.ps1`, run from the repo root either way — the difference is which
parameters you pass. No parameters = production, unchanged from before.

## One-time setup (per machine)

Fill in `Secrets\set-deploy-secrets.ps1` with your real credentials (Anthropic key, cron
secret, admin emails, Gmail sender + app password, Google OAuth client id/secret). That
file is gitignored — it never leaves your machine. See the comments in the file itself for
where each value comes from.

## Every deploy session

```powershell
cd D:\software_projects\CareCast
. .\Secrets\set-deploy-secrets.ps1
firebase login --reauth   # only if firebase/gcloud auth has expired
```

The leading `. ` before the secrets script matters — it "dot-sources" it so the variables
land in your current shell instead of a throwaway child process.

## Deploy production

```powershell
.\deploy-v2.ps1
```

That's it — same one-liner as always. Every parameter it needs defaults to the exact
production values (`carecast-v2`, `care-cast-api-v2`, `app.carecast.app`, etc.), so this
behaves identically to every prod deploy before sandbox support existed.

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

## What sandbox does NOT have yet (deferred, not needed for current testing)

- `-ApiBaseUrl` and `-GoogleRedirectUri` are left at their **prod** defaults for sandbox
  deploys so far. Neither affects Guest Greetings or Personal Events testing (they matter
  for absolute icon URLs and "Connect Google Calendar" OAuth respectively) — revisit if a
  later test needs Calendar OAuth working on sandbox.
