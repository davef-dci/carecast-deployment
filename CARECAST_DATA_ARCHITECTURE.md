# CareCast — Data Architecture Document
**Version:** 2.0 (Proposed)
**Date:** February 2026
**Status:** For Review — Updated to match current implementation (Feb 2026)
**Audience:** Development team, technical reviewers

---

## Table of Contents

1. [Overview & Goals](#1-overview--goals)
2. [Core Design Principles](#2-core-design-principles)
3. [Entity Model & Relationships](#3-entity-model--relationships)
4. [Firebase Project Strategy](#4-firebase-project-strategy)
5. [Firestore Collections — Detailed Schemas](#5-firestore-collections--detailed-schemas)
6. [Firebase Storage Structure](#6-firebase-storage-structure)
7. [The Daily Frame Pipeline](#7-the-daily-frame-pipeline)
8. [The `latest.json` Manifest](#8-the-latestjson-manifest)
9. [The Visitor Portal](#9-the-visitor-portal)
10. [The Frame Device (LCD Display)](#10-the-frame-device-lcd-display)
11. [Onboarding & Provisioning Flexibility](#11-onboarding--provisioning-flexibility)
12. [Future-Proofing: Dynamic Content](#12-future-proofing-dynamic-content)
13. [Migration from v1](#13-migration-from-v1)
14. [What Is Deliberately Out of Scope](#14-what-is-deliberately-out-of-scope)
15. [Open Questions for Review](#15-open-questions-for-review)

---

## 1. Overview & Goals

CareCast is a digital care communication platform. It allows family members to create and publish daily "frames" — curated digital displays showing scheduled activities, messages, and family photos — for a loved one (the **resident**) living in a care facility or at home.

Supporting systems include:
- A **web app** where family members create and publish daily frame content
- An **API** that converts web content to images and writes to Firebase
- A **physical LCD frame** in the resident's room that displays the published content
- A **visitor portal** (web app, accessed via QR code) where visitors leave messages for the family

### Goals of this architecture revision

| Goal | Reason |
|---|---|
| Separate **user** (family member) from **resident** | Current model hardwires 1 user = 1 resident, blocking real-world family structures |
| Support many-to-many user↔resident relationships | Multiple family members per resident; one person managing multiple residents |
| Make daily frame documents uniquely addressable by date | Eliminate risk of duplicate project documents per day |
| Simplify Firebase Storage paths | Remove indirection layer (`runId` subfolders); use stable, overwritable filenames |
| Key storage by residentId, not email | Email can change; residentId is permanent |
| Lay groundwork for facility portal | Without building it yet |
| Support both self-service and white-glove onboarding | Without complicating the data model |
| Allow more page types in the future | Without schema changes |

---

## 2. Core Design Principles

**Principle 1: The resident is the central entity.**
Everything — frames, photos, calendars, messages, QR codes — belongs to the *resident*, not to whichever family member happens to be logged in. A family member is a *user* with *access* to one or more residents.

**Principle 2: Stable, deterministic document IDs where possible.**
Daily frame documents use `{residentId}_{date}` as their ID. You can never accidentally create two documents for the same resident on the same day. Lookups are direct (no queries needed).

**Principle 3: Storage paths never include email addresses.**
Email can change. `residentId` is permanent. All Storage paths are keyed by `residentId`.

**Principle 4: The join table (`residentMemberships`) handles all access relationships.**
No arrays of UIDs embedded in documents. This keeps access control clean, queryable, and auditable.

**Principle 5: Published frames use fixed filenames, overwritten on each publish.**
No timestamped filenames, no `runId` subfolders, no indirection. Three pages → three files, always in the same place.

**Principle 6: Future features are designed for, not built yet.**
Facility portal, dynamic widget feeds, multi-facility residents — the schema makes room for these without implementing them.

---

## 3. Entity Model & Relationships

```
Firebase Auth
    │
    ▼
users/{uid}                        ← login account (family member / caregiver)
    │
    │  (via residentMemberships)
    ▼
residents/{residentId}             ← the person in the facility
    │
    ├── dailyFrames/{date}         ← one frame document per day
    │       └── pages[]            ← page content (widgets, config)
    │
    ├── (photos collection)        ← photo library
    │   photos/{residentId}/library/{photoId}
    │
    └── (messages)                 ← visitor portal messages
        messages/{residentId}/inbox/{messageId}


residentMemberships/{membershipId} ← who can access which resident
    ├── userId  → users/{uid}
    └── residentId → residents/{residentId}


publicProfiles/{residentId}        ← public-safe data for visitor portal (no auth)


facilities/{facilityId}            ← future: facility portal
```

### Relationship summary

| Relationship | Cardinality | Mechanism |
|---|---|---|
| User → Residents | One user can manage many residents | `residentMemberships` |
| Resident → Users | One resident can have many family members | `residentMemberships` |
| Resident → Daily Frames | One per day | subcollection `dailyFrames/{date}` |
| Resident → Photos | Many | subcollection `photos/{residentId}/library` |
| Resident → Messages | Many | subcollection `messages/{residentId}/inbox` |
| Resident → Facility | Optional, one | `facilityId` field on resident |
| Facility → Residents | Many | query residents where `facilityId == id` |

---

## 4. Firebase Project Strategy

### Use two separate Firebase projects

| Project | Purpose |
|---|---|
| **`carecast-legacy`** (existing) | Keep running for current test user during transition. Do not touch. |
| **`carecast-v2`** (new, to be created) | All new development. Built on this architecture from day one. |

### Why separate projects instead of migrating in place

The proposed changes touch every Firestore collection path, every Storage path, and the core data model. It is not safely possible to migrate these changes in the same Firebase project while a user (even a test user) is actively using the app.

When the new system is stable and ready:
1. Notify the test user of the cutover date
2. Run a one-time photo migration script (download from old bucket → upload to new bucket)
3. All other data (projects, resident info, calendar connections) is re-entered — acceptable given early stage
4. Decommission the legacy project

---

## 5. Firestore Collections — Detailed Schemas

---

### 5.1 `users/{uid}`

**Document ID:** Firebase Auth UID (set at account creation)
**Purpose:** Stores login account information. Contains nothing resident-specific.

```
uid:            string        — Firebase Auth UID (also the doc ID)
email:          string        — login email
emailVerified:  boolean

profile:
  firstName:    string
  lastName:     string
  displayName:  string
  avatar?:      string        — Storage URL for profile photo

createdAt:      timestamp
lastLoginAt:    timestamp
lastActiveAt:   timestamp
isActive:       boolean
```

**Intentionally omitted from this document:**
- `familyId` (removed — relationship handled by `residentMemberships`)
- `qrCodeUrl` (moved to `residents` and `publicProfiles`)
- Calendar preferences (stored on the resident record under `calendarPreferences`, `personalCalendarId`, and `facilityCalendarIds`)
- Resident display settings (moved to `residents`)

---

### 5.2 `residents/{residentId}`

**Document ID:** Auto-generated by Firestore at resident creation
**Purpose:** The resident is the core entity. Everything else references this ID.

```
residentId:       string        — auto-generated Firestore ID (also doc ID)
firstName:        string
lastName:         string
displayName:      string        — e.g. "Mom", "Dorothy", "Dad"
dateOfBirth?:     string        — YYYY-MM-DD (for age-appropriate content)
avatar?:          string        — Storage URL: residents/{residentId}/avatar.jpg
email?:           string        — resident's own email, if they have one
phone?:           string

facilityId?:      string        — null = home care; references facilities/{facilityId}
facilityName?:    string        — denormalized for display (avoid extra lookup)
unit?:            string        — "Room 214B"

timezone:         string        — IANA e.g. "America/Chicago"

calendar:
  personalCalendarId?:   string      — Google Calendar ID for resident
  facilityCalendarIds?:  string[]    — one or more facility calendars
  calendarPreferences?:  map         — per-calendar settings keyed by calendarId

displaySettings:
  activeHoursStart:       string   — "07:00 AM" (frame turns on)
  activeHoursEnd:         string   — "09:30 PM" (frame turns off)
  slideDurationSeconds:   number   — photo slideshow interval

preferences:
  answers:    map<string, "yes"|"no"|"not_sure">  — onboarding questionnaire
  traits:     string[]      — e.g. ["Female", "Religious", "Likes TV"]
  updatedAt:  timestamp

aiScheduleEnabled:  boolean
aiFeedback:         array
  - eventTitle:   string
    verdict:      "accepted" | "rejected"
    reason?:      string
    date:         string    — ISO date

status:       string        — "active" | "inactive" | "onboarding"
createdAt:    timestamp
updatedAt:    timestamp
createdBy:    string        — uid of who created this resident record
```

---

### 5.3 `residentMemberships/{membershipId}`

**Document ID:** Auto-generated
**Purpose:** Defines which users have access to which residents, and at what role level. This is the join table that enables all multi-user and multi-resident scenarios.

```
membershipId:   string        — auto-generated (also doc ID)
residentId:     string        — references residents/{residentId}
userId:         string        — references users/{uid}
role:           string        — "owner" | "caregiver" | "viewer"
                               (future: "facility_staff" | "admin")

invitedBy:      string        — uid of who sent the invitation
invitedAt:      timestamp
acceptedAt?:    timestamp     — null if invitation pending
isActive:       boolean

createdAt:      timestamp
updatedAt:      timestamp
```

**Role definitions:**

| Role | Can view frame | Can edit & publish | Can manage resident settings | Can invite others |
|---|---|---|---|---|
| `owner` | ✅ | ✅ | ✅ | ✅ |
| `caregiver` | ✅ | ✅ | ✅ | ❌ |
| `viewer` | ✅ | ❌ | ❌ | ❌ |
| `facility_staff` (future) | ✅ | limited | ❌ | ❌ |

**Common queries:**

```
// "Which residents can this user access?"
residentMemberships WHERE userId == uid AND isActive == true

// "Who has access to this resident?"
residentMemberships WHERE residentId == id AND isActive == true

// "Does this user have edit rights to this resident?"
residentMemberships WHERE userId == uid AND residentId == id AND isActive == true
→ check role in ["owner", "caregiver"]
```

---

### 5.4 `residents/{residentId}/dailyFrames/{date}`

**Document ID:** `YYYY-MM-DD` date string — e.g. `2026-02-24`
**Purpose:** Stores one day's frame content per resident. The date IS the document ID — it is structurally impossible to create duplicates.

```
date:           string        — "2026-02-24" (also the doc ID)
residentId:     string        — denormalized for queries
status:         string        — "draft" | "published"

pages:          array
  - pageId:     string        — "info-page" | "schedule-page" | "photos-page"
                               (extensible: add new page types without schema change)
    enabled:    boolean
    widgets:    array
      - instanceId:           string
        templateType:         string    — "message"|"notes"|"event"|"photo"|"joke"
                                          (future: "weather"|"news-scroll"|"clock")
        position:
          x, y, width, height: number
        zIndex:               number
        config:               map       — widget-specific content/settings

publishedAt?:   timestamp
lastEditedAt:   timestamp
createdAt:      timestamp
createdBy:      string        — uid
lastEditedBy:   string        — uid
```

**Key design decisions:**
- `pages[]` is extensible — adding a fourth page type requires no schema change, only a new pageId string
- `templateType` on widgets is a string — new widget types (weather, news) are added by defining new template types, not by changing this schema
- No `templateId` field — templates are the starting point for creating a frame but do not need to be permanently referenced in the daily frame document

---

### 5.5 `publicProfiles/{residentId}`

**Document ID:** `residentId`
**Purpose:** The visitor portal is unauthenticated (visitors have no account). This collection holds only the public-safe subset of resident data needed to render the portal. It must never contain private or sensitive information.

```
residentId:     string        — references residents/{residentId}
displayName:    string        — "Dorothy" or "Mom"
firstName:      string        — used in portal greeting: "Send a note to Dorothy's family"
photoURL?:      string        — resident avatar for portal display
facilityName?:  string        — "Sunrise Gardens" (friendly context for visitors)
unit?:          string        — optional, for visitor wayfinding

updatedAt:      timestamp     — kept in sync with residents/{residentId} via Cloud Function or write-through
```

**Security rules:** This collection is publicly readable (no auth required). It is writable only by authenticated backend services, never by the visitor portal app itself.

**QR code format:**
`https://ccportal.carecast.app/?rid={residentId}`
(Uses `rid` — residentId — not `uid`. The visitor portal looks up `publicProfiles/{rid}`.)

**QR code storage path:**
`qr_codes/{residentId}.png`

---

### 5.6 `messages/{residentId}/inbox/{messageId}`

**Document ID:** Auto-generated
**Purpose:** Visitor portal messages, addressed to the resident's family. Stored under the resident, not under a user account.

```
messageId:      string        — auto-generated (also doc ID)
residentId:     string        — denormalized
visitorName:    string        — self-reported by visitor
messageText:    string
createdAt:      timestamp     — serverTimestamp()
status:         string        — "new" | "read" | "archived"
source:         string        — "visitor-qr" (extensible: future sources)
```

**Note on current code:** The existing visitor portal writes to `users/{uid}/messages`. In the new architecture this moves to `messages/{residentId}/inbox/{messageId}`. The visitor portal app.js needs the URL parameter changed from `?uid=` to `?rid=` and the Firestore write path updated accordingly.

---

### 5.7 Calendar preferences (embedded on `residents/{residentId}`)

**Status:** Implemented (current behavior)

Rather than maintaining a separate top-level `calendarIntegrations` collection, the current implementation stores **calendar IDs and per-calendar scheduling preferences** directly on the resident record.

This keeps the resident’s schedule configuration co-located with the resident profile and avoids an extra document lookup for the most common read paths (rendering schedules and determining which calendars contribute events).

#### Fields on `residents/{residentId}`

```
personalCalendarId:     string        — primary personal calendar ID (Google Calendar ID)

facilityCalendarIds:    string[]      — one or more facility/community calendar IDs

calendarPreferences:    map
  {calendarId}:         map
    autoAddToSchedule:  boolean       — whether events from this calendar are auto-included
```

#### Example (from current resident record)

- `personalCalendarId`: a single Google Calendar ID
- `facilityCalendarIds`: an array of Google Calendar IDs
- `calendarPreferences`: keyed by calendarId, with settings such as `autoAddToSchedule`

> Note: This section documents **calendar identifiers and preferences** only. If OAuth tokens or provider credentials are needed, they should be handled server-side (and kept out of client-readable documents) unless explicitly required for a future integration design.


---

---

### 5.8 `facilities/{facilityId}` *(schema defined, not yet built)*

**Document ID:** Auto-generated
**Purpose:** Represents a care facility. Residents can be associated with a facility. In the future, facility staff will have portal access.

```
facilityId:     string        — (also doc ID)
name:           string        — "Sunrise Gardens Memory Care"
address:
  streetAddress: string
  city:          string
  state:         string
  postcode:      string
  country:       string
timezone:        string       — IANA
phone?:          string
contactEmail?:   string
website?:        string
status:          string       — "active" | "inactive"
createdAt:       timestamp
createdBy:       string       — uid (CareCast admin who provisioned)
```

**How it's used now:** `facilityId` and `facilityName` fields exist on resident documents. The `facilities` collection itself does not need to be populated yet — residents can have a `facilityName` string without a formal `facilityId` during early operation. Migrate to formal facility records when the facility portal is built.

---

### 5.9 `templates/{templateId}` *(unchanged from current)*

Stores reusable page layout templates. Not changed in this revision. Templates are the starting point when a user creates a new daily frame; they are not permanently linked to a frame after creation.

---

## 6. Firebase Storage Structure

All paths use `residentId` as the primary key. Email addresses are never used in storage paths.

```
{bucket}/
│
├── residents/{residentId}/
│   └── avatar.jpg                         ← resident profile photo
│
├── photos/{residentId}/
│   ├── originals/{uuid}.jpg               ← full-size uploaded photos
│   └── thumbnails/{uuid}_thumb.jpg        ← generated thumbnails (150×150)
│
├── frames/{residentId}/{date}/
│   ├── info.jpeg                          ← published page (overwritten on each publish)
│   ├── schedule.jpeg                      ← published page (overwritten on each publish)
│   ├── photos.jpeg                        ← published page (overwritten on each publish)
│   └── latest.json                        ← manifest (overwritten on each publish)
│
└── qr_codes/{residentId}.png             ← visitor portal QR code
```

### Key changes from current architecture

| Current path | New path | Reason |
|---|---|---|
| `frames/{email}/{date}/{runId}/{page}_{timestamp}.jpeg` | `frames/{residentId}/{date}/{page}.jpeg` | Stable filenames, no indirection, email-free |
| `photos/{userId}/userPhotos` (Firestore) | `photos/{residentId}/library` (Firestore) | Photos belong to resident |
| `{MEDIA_FOLDER}/{uuid}.jpg` (Storage) | `photos/{residentId}/originals/{uuid}.jpg` | Organized by resident |
| `qr_codes/qr-{uid}.png` | `qr_codes/{residentId}.png` | QR belongs to resident |

### Why fixed filenames instead of timestamped filenames

Current storage uses `info_1704067200000.jpeg` (timestamp in filename) inside a `{runId}/` subfolder. The `runId` is stored in `latest.json` so the frame device knows which subfolder to look in.

In the new architecture, each page always lives at a fixed path (`frames/{residentId}/{date}/info.jpeg`). Publishing overwrites the file. This means:
- No orphaned subfolders accumulating in storage
- No `runId` needed in `latest.json`
- No URL parsing to find and clean up old publish runs
- The frame device reads a known, stable path — no manifest indirection required to locate files

---

## 7. The Daily Frame Pipeline

### Creating a frame (first time for a date)

1. User selects a date in the web app
2. App performs direct Firestore lookup: `residents/{residentId}/dailyFrames/{date}`
3. If document does not exist → create it (status: `draft`, pages from default template)
4. If document exists → open it (draft or published — user continues editing)

No query needed. No risk of duplicates. The date is the document ID.

### Saving a draft

Auto-save writes to `residents/{residentId}/dailyFrames/{date}`:
```
pages: [...updated pages]
lastEditedAt: serverTimestamp()
lastEditedBy: uid
status: (not changed — never auto-reset to draft)
```

### Publishing

1. For each enabled page, render HTML → JPEG (540×960px)
2. Upload to `frames/{residentId}/{date}/{pageName}.jpeg` (overwrites previous if exists)
3. Write `latest.json` to `frames/{residentId}/{date}/latest.json`
4. Update Firestore document:
   ```
   status: "published"
   publishedAt: serverTimestamp()
   lastEditedBy: uid
   ```

### Re-publishing (editing a published day)

Same as publishing. The three JPEG files and `latest.json` are simply overwritten. No cleanup needed. The frame device picks up the new content the next time it reads `latest.json`.

---

## 8. The `latest.json` Manifest

Written to `frames/{residentId}/{date}/latest.json` on every publish.

### Why it still exists

Even with fixed filenames, `latest.json` serves important purposes:
- Tells the frame device which pages are active (some may be disabled)
- Carries display settings (wake/sleep times, slide duration, timezone)
- Carries the photo playlist for the slideshow page
- Provides a clear signal that a publish has completed (the frame device waits for this file)
- Extensible for future dynamic content configuration

### Schema (v2)

```json
{
  "version": 2,
  "publishedAt": "2026-02-24T14:30:00.000Z",
  "pages": ["info", "schedule", "photos"],
  "playback": {
    "slideDurationMs": 3000
  },
  "schedule": {
    "timezone": "America/Chicago",
    "wakeTime": "07:00",
    "sleepTime": "21:30"
  },
  "photoPlaylist": {
    "displayMode": "ordered",
    "photos": [
      { "id": "uuid", "url": "https://...", "name": "Family vacation" }
    ]
  }
}
```

### What was removed from v1

| v1 field | Removed | Why |
|---|---|---|
| `runId` | ✅ | No longer needed — files are at fixed paths |
| `content.prefix` | ✅ | No subfolder indirection |
| `content.files` | ✅ | Filenames are fixed and known |

### How the frame device uses it

1. Fetch `frames/{residentId}/{date}/latest.json`
2. Read `schedule` → enforce wake/sleep times
3. Read `pages` → know which pages to display and in what order
4. Load `frames/{residentId}/{date}/{page}.jpeg` for each page in the list
5. Read `photoPlaylist` → run slideshow on photos page
6. Poll on a schedule (e.g., every 15 minutes) to pick up new publishes

### Future dynamic content

When dynamic widgets are added (weather, news ticker, etc.), `latest.json` gains an optional `dynamicFeeds` section:
```json
"dynamicFeeds": {
  "weather": true,
  "newsTicker": false
}
```
The frame device reads this to know which live data overlays to apply. See Section 12.

---

## 9. The Visitor Portal

### Current state

- Visitors scan a QR code in the resident's room
- Opens: `https://ccportal.carecast.app/?uid={uid}`
- Loads `publicProfiles/{uid}` from Firestore
- Visitor types name + message
- Message written to `users/{uid}/messages/{autoId}`
- Family member reads messages in the web app

### Changes in v2

| Item | Current | v2 |
|---|---|---|
| URL parameter | `?uid={userUid}` | `?rid={residentId}` |
| Profile lookup | `publicProfiles/{userUid}` | `publicProfiles/{residentId}` |
| Message destination | `users/{uid}/messages` | `messages/{residentId}/inbox` |
| QR code encodes | user's Firebase Auth UID | `residentId` |

### Why this matters

In v1, the visitor portal is tied to a *user account* (a family member's login). If the primary family member changes, the QR code becomes invalid. In v2, the QR code is tied to the *resident* — it never needs to change regardless of which family member manages the account.

### `publicProfiles` sync

When resident information changes (display name, avatar, facility name), `publicProfiles/{residentId}` must be kept in sync. Two options:
- **Write-through:** Every update to `residents/{residentId}` also updates `publicProfiles/{residentId}` (simpler, slightly more write operations)
- **Cloud Function trigger:** A Firestore trigger on `residents/{residentId}` updates `publicProfiles/{residentId}` automatically (cleaner separation, slightly more infrastructure)

Recommendation: write-through for now; migrate to Cloud Function trigger later if needed.

---

## 10. The Frame Device (LCD Display)

### Current behavior (static JPEG display)

The Android/embedded frame app:
1. Reads `frames/{email}/{date}/latest.json`
2. Parses `runId` and `prefix` to find the image subfolder
3. Lists all files in the subfolder
4. Displays images on a rotation
5. Enforces wake/sleep schedule
6. Overlays a live clock on the schedule page
7. Runs a photo slideshow on the photos page

### Changes required for v2

1. Change the storage path it reads from `frames/{email}/{date}/` to `frames/{residentId}/{date}/`
2. Remove `runId`/`prefix` parsing — load fixed filenames directly:
   - `frames/{residentId}/{date}/info.jpeg`
   - `frames/{residentId}/{date}/schedule.jpeg`
   - `frames/{residentId}/{date}/photos.jpeg`
3. Remove `listAll()` call (no longer needed)
4. Read `pages` array from `latest.json` to know which pages to display
5. Update `LatestManifest` model to v2 schema (remove `content.prefix`, `content.files`, `runId`)

### Device configuration

The device needs to know:
- `residentId` — to construct the storage path
- Firebase project credentials

This replaces the current configuration which uses the user's email address.

### Planned frame behavior (confirmed)

| Behavior | Implementation |
|---|---|
| Turn on/off at scheduled times | Read `schedule.wakeTime` / `schedule.sleepTime` from `latest.json` |
| Display clock on schedule page | Client-side overlay (no server involvement) |
| Photo slideshow on photos page | Read `photoPlaylist` from `latest.json` |
| Rotate through pages | Read `pages` array from `latest.json` |
| Pick up new publishes | Poll `latest.json` on a timer (e.g., every 15 minutes) |

---

## 11. Onboarding & Provisioning Flexibility

The architecture supports both self-service and white-glove provisioning without schema changes. The difference is only in *who* performs step 1.

### Self-service flow

1. Family member creates a Firebase Auth account (email/password or SSO)
2. During onboarding wizard, they fill in resident details → creates `residents/{residentId}` with `createdBy: uid`
3. System auto-creates `residentMemberships` record with `role: "owner"`
4. System generates QR code → writes to `qr_codes/{residentId}.png` and `publicProfiles/{residentId}`
5. Family member can invite others via email → creates pending `residentMemberships` record (`acceptedAt: null`)
6. Invitee creates account (or logs into existing account) → membership is activated

### White-glove flow (admin-provisioned)

1. CareCast admin creates `residents/{residentId}` with `createdBy: "system"` or admin UID
2. Admin generates QR code, configures display settings, sets `status: "onboarding"`
3. Admin invites primary family member by email → creates `residentMemberships` with `role: "owner"`, `acceptedAt: null`
4. Family member receives invitation, creates account → membership activated, status → `"active"`
5. Family member can invite additional members

### What makes both work from the same schema

- `createdBy` field on resident record tracks who provisioned it
- `status: "onboarding"` on resident signals an incomplete setup
- `acceptedAt: null` on membership signals a pending invitation
- No "admin flag" needed in the schema — admin privilege is a role in `residentMemberships` or a separate claim in Firebase Auth

---

## 12. Future-Proofing: Dynamic Content

This is noted as high-priority for consideration but low-priority to build. The architecture makes room without implementing it.

### The concept

Some content on the frame may eventually be live/dynamic rather than a static JPEG:
- Current weather at the facility location
- A scrolling news or announcement ticker
- Live clock (already implemented client-side)
- Facility announcements pushed in real time

### The proposed pattern: Widget Data Feeds

```
residents/{residentId}/widgetFeeds/{widgetType}

Example:
residents/abc123/widgetFeeds/weather
  {
    currentTemp: 72,
    condition: "Sunny",
    feelsLike: 68,
    updatedAt: timestamp
  }
```

A Cloud Function (or scheduled job) updates these documents on a timer. The frame device, when it gains dynamic content support, polls this subcollection alongside `latest.json`.

The static JPEG pages are unaffected — dynamic widgets are an overlay layer the frame renders on top of the static image. This means dynamic content does not require changes to the publish pipeline.

### Why this is deferred

- Current target audience (senior care) has limited need for dynamic content
- Frame device changes required are significant
- Risk is high relative to value at this stage
- Architecture is designed to accommodate it without being blocked by it

### Recommended approach when the time comes

Fork the frame app into a new version. Keep the static JPEG version running. Do not attempt to add dynamic content to the existing frame codebase.

---

## 13. Migration from v1

### What does NOT need to migrate

- Daily frame content (projects) — low value, small amount, re-create from scratch
- Resident profile info — re-enter during new onboarding
- Calendar connections — no OAuth re-authorization needed (service accounts)
- Messages — archive or discard

### What DOES need to migrate

**Photos** — these represent real family memories and should be preserved.

Migration script (one-time, run by admin):
1. For each user in the old `photos/{userId}/userPhotos` collection:
   - Identify the corresponding `residentId` in the new system (manual mapping)
   - Download each photo from old Storage bucket
   - Upload to `photos/{residentId}/originals/{uuid}.jpg` in new bucket
   - Create Firestore document in `photos/{residentId}/library/{photoId}`
2. Verify all photos accessible in new system
3. Confirm with user before decommissioning old system

### Firebase project cutover steps

1. Create new Firebase project (`carecast-v2`)
2. Enable: Authentication, Firestore, Storage, Cloud Functions (if used)
3. Configure Firestore security rules (see Section below)
4. Deploy new API pointed at new Firebase project
5. Deploy new web app pointed at new Firebase project
6. Run photo migration script
7. Test with new user account
8. Notify test user of cutover date
9. Decommission old project after confirmation

---

## 14. What Is Deliberately Out of Scope

These are acknowledged future features. The architecture makes room for them but does not implement them.

| Feature | Why deferred |
|---|---|
| Facility portal | Requires facility staff auth flows, role management, significant UI work |
| Dynamic widget feeds | High complexity, low priority for target audience |
| Multi-provider calendar (Outlook, Apple) | Google Calendar is sufficient for now |
| Push notifications to family | Nice-to-have; requires notification service |
| Resident-to-family video calls | Separate product surface |
| AI-generated content | Partially implemented; architecture supports it via `aiScheduleEnabled` |
| Visitor message threading/replies | Current one-way message model is sufficient |

---

## 15. Open Questions for Review

The following questions are flagged for the development team to validate before implementation begins.

**Q1. Firestore security rules strategy**
With the new membership model, security rules must enforce that a user can only read/write a resident's data if an active `residentMemberships` record exists. What is the preferred approach — Firestore rules that check the memberships collection, or route all writes through authenticated API endpoints (which perform the check server-side)?
*Recommendation: API-enforced for now (simpler rules, easier to audit). Migrate to Firestore rules when team has bandwidth.*

**Q2. `publicProfiles` sync method**
Write-through (webapp updates both `residents` and `publicProfiles` simultaneously) vs. Cloud Function trigger. Are there concerns about the write-through approach at this scale?

**Q3. Frame device identifier**
The frame device currently identifies the resident by email address (from `latest.json` path). In v2 it needs `residentId`. How is this configured on the physical device? Is there a setup/pairing flow? This affects QR code setup, device provisioning, and potentially the frame app's first-run experience.

**Q4. `latest.json` polling interval**
The frame device polls `latest.json` to detect new publishes. What polling interval is appropriate? (Suggested: 15 minutes during wake hours, 60 minutes or none during sleep hours.) Are there Firebase Storage read cost implications at scale?

**Q5. Photo migration ownership mapping**
The migration script needs to map old `userId` → new `residentId`. Since there is currently one user per resident, this is a 1:1 mapping. Should this be a manual config file or an automated lookup?

**Q6. Invitation flow implementation**
When a family member invites another (creates a `residentMemberships` record with `acceptedAt: null`), how is the invitee notified? Email via Firebase Extensions (Trigger Email), a custom email service, or manual/out-of-band for now?

**Q7. Page type extensibility**
New page types are added as new `pageId` strings in the `pages[]` array. Are there any constraints on page types the development team foresees that would require schema changes (e.g., pages with fundamentally different data structures)?

**Q8. Template system future**
Currently one template exists. As page types grow, will templates become per-page-type rather than whole-frame? The current `templateId` reference on projects has been removed from daily frames — is this acceptable or should it be retained for auditing which template was used?

---

## Appendix A: Firestore Collection Index

| Collection | Doc ID | Key fields | Queries needed |
|---|---|---|---|
| `users` | Firebase Auth UID | email, isActive | By UID (direct lookup) |
| `residents` | Auto-generated | facilityId, status | By facilityId (future) |
| `residentMemberships` | Auto-generated | userId, residentId, isActive, role | By userId; by residentId |
| `residents/{id}/dailyFrames` | `YYYY-MM-DD` date | status, residentId | Direct lookup by date |
| `publicProfiles` | `residentId` | displayName, photoURL | Direct lookup by residentId |
| `messages/{id}/inbox` | Auto-generated | status, createdAt | By status; by createdAt |
| `photos/{id}/library` | Auto-generated | isActive, uploadedAt | By isActive + uploadedAt |
| *(embedded)* `residents/{residentId}` | `residentId` | personalCalendarId, facilityCalendarIds, calendarPreferences | Direct lookup by residentId |
| `facilities` | Auto-generated | status | By status (future) |
| `templates` | Auto-generated | isActive | By isActive |

---

## Appendix B: Firebase Storage Path Index

| Path | Content | Overwrite on update? |
|---|---|---|
| `residents/{residentId}/avatar.jpg` | Resident profile photo | Yes |
| `photos/{residentId}/originals/{uuid}.jpg` | Uploaded family photos | No (immutable) |
| `photos/{residentId}/thumbnails/{uuid}_thumb.jpg` | Generated thumbnails | No (immutable) |
| `frames/{residentId}/{date}/info.jpeg` | Published info page | Yes (each publish) |
| `frames/{residentId}/{date}/schedule.jpeg` | Published schedule page | Yes (each publish) |
| `frames/{residentId}/{date}/photos.jpeg` | Published photos page | Yes (each publish) |
| `frames/{residentId}/{date}/latest.json` | Frame manifest | Yes (each publish) |
| `qr_codes/{residentId}.png` | Visitor portal QR code | Only if regenerated |

---

## Appendix C: Entities That Move (v1 → v2 mapping)

| Data | v1 location | v2 location | Action |
|---|---|---|---|
| User profile | `users/{uid}` | `users/{uid}` | Slim down (remove resident fields) |
| Resident profile | `residents/{residentId}` (familyId field) | `residents/{residentId}` (no familyId) | Re-key relationships |
| User↔Resident relationship | `familyId` field on resident | `residentMemberships/{id}` | New collection |
| Daily frame content | `projects/{uuid}` | `residents/{id}/dailyFrames/{date}` | New structure |
| Photos (Firestore) | `photos/{userId}/userPhotos` | `photos/{residentId}/library` | Re-key by residentId |
| Photos (Storage) | `{MEDIA_FOLDER}/{uuid}.jpg` | `photos/{residentId}/originals/{uuid}.jpg` | Migrate |
| Visitor messages | `users/{uid}/messages` | `messages/{residentId}/inbox` | New path |
| Public profile | `publicProfiles/{uid}` | `publicProfiles/{residentId}` | Re-key |
| QR code | `qr_codes/qr-{uid}.png` | `qr_codes/{residentId}.png` | Regenerate |
| Calendar preferences | *(varied)* | `residents/{residentId}` (embedded fields) | Implemented |
| Frame images (Storage) | `frames/{email}/{date}/{runId}/{page}_{ts}.jpeg` | `frames/{residentId}/{date}/{page}.jpeg` | New structure |
| Frame manifest | `frames/{email}/{date}/latest.json` | `frames/{residentId}/{date}/latest.json` | Same path pattern, new schema |

---

*End of document.*
*Review comments and questions welcome — see Section 15.*
