# CareCast Release Versioning

CareCast uses a two-layer release identifier system:

1. Human-readable release labels for support and deployment conversations.
2. Git commit revisions for exact code traceability.

This lets support ask a user, "What release do you see?" while still letting engineering map the deployed app back to the exact source code.

## Release Label Format

Use a date-based label:

```text
YYYY.MM.DD-a
```

Examples:

```text
2026.07.02-a
2026.07.02-b
2026.07.03-a
```

Use `-a` for the first deployment on a date, `-b` for the second, and so on.

## Component Releases

The webapp and API can deploy independently, so they should have separate component release labels.

Recommended environment names:

```text
CARECAST_RELEASE
CARECAST_WEBAPP_RELEASE
CARECAST_API_RELEASE
```

`CARECAST_RELEASE` is the overall support-facing product release. In most cases it should match the user-facing webapp release.

`CARECAST_WEBAPP_RELEASE` identifies the Family Portal build.

`CARECAST_API_RELEASE` identifies the deployed API build.

These may diverge. For example, if only the webapp changes:

```text
CARECAST_RELEASE=2026.07.03-a
CARECAST_WEBAPP_RELEASE=2026.07.03-a
CARECAST_API_RELEASE=2026.07.02-a
```

Do not increment the API release label for a webapp-only deployment unless the API is also deployed with meaningful changes.

## Git Revisions

Each deployment should also include the Git commit SHA for each component:

```text
Webapp revision: d1340fdabc12
API revision: 53a8184def34
```

The Git SHA is the source of truth for exact code. The human-readable release label is for support, communication, and deployment notes.

## Help Panel Display

The Family Portal Help panel should display both release labels and Git revisions.

Preferred format:

```text
CareCast Release: 2026.07.03-a
Webapp: 2026.07.03-a (d1340fdabc12)
API: 2026.07.02-a (53a8184def34)
Built: Jul 3, 2026 10:14 AM
```

If a release label is not provided, the app may show `local-dev` or `unknown`.

## Deployment Rules

Before deploying:

1. Commit the API and webapp changes that should be part of the deployment.
2. Confirm both repos are on the intended branch.
3. Confirm both repos have the expected latest commit.
4. Choose the release label.
5. Run the deploy script with the appropriate release labels.
6. After deployment, open the Help panel and confirm the displayed release and revisions.

## Deploy Script Examples

Deploy both API and webapp with the same release label:

```powershell
.\deploy-v2.ps1 -CareCastRelease "2026.07.02-a" -WebappRelease "2026.07.02-a" -ApiRelease "2026.07.02-a"
```

Deploy only the webapp with a new webapp release label while leaving the API release unchanged:

```powershell
.\deploy-v2.ps1 -SkipApiDeploy -CareCastRelease "2026.07.03-a" -WebappRelease "2026.07.03-a" -ApiRelease "2026.07.02-a"
```

Deploy only the API:

```powershell
.\deploy-v2.ps1 -SkipWebDeploy -CareCastRelease "2026.07.03-b" -WebappRelease "2026.07.03-a" -ApiRelease "2026.07.03-b"
```

If release labels are omitted, the deploy script defaults all release labels to the current date with `-a`.

## Rollback Notes

If a deployment causes problems, rollback should be based on Git commits and deployed Cloud Run/Firebase revisions, not only the human-readable release label.

The release label helps identify the deployment in conversation. The Git SHA identifies the exact source revision to restore.
