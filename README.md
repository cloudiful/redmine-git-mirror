# redmine_git_mirror

A Redmine 7 plugin that mirrors allowed remote Git repositories into a
local directory and registers the mirror as a native Redmine Git
repository.

The plugin exposes a small JSON endpoint that an external client uses to
schedule mirror work. Authentication is a shared secret managed on the
administrator settings page (**Administration → Git mirrors**) and
passed via an `Authorization: Bearer` header (a legacy
`REDMINE_GIT_MIRROR_API_KEY` environment variable is honoured only
when no key has been saved in the UI). The plugin never clones a
remote during a request — clone and fetch happen asynchronously
through a Sidekiq job.

## Requirements

- Redmine 7.0 or newer
- Sidekiq 8 (already required by `Gemfile.local`)
- The `git` command available in the Sidekiq container
- An SSH key with read access to the target repositories, mounted read-only
  into the Sidekiq container at `/home/redmine/.ssh`

## Configuration

Configure the plugin from the **Administration → Git mirrors** page
(`GET /redmine_git_mirror/settings`, administrator only). The page lets
an administrator view and save the allowed Git hosts and the mirror
root, view and copy the API key, and rotate the API key.

| Setting          | Default                          | Purpose                                      |
| ---------------- | -------------------------------- | -------------------------------------------- |
| Allowed hosts    | (empty)                          | Comma-separated allow-list of Git host names |
| Mirror root      | `/var/lib/redmine/repositories`  | Parent directory where mirror worktrees live |
| API key          | (generated on first visit)       | Shared secret accepted by the JSON endpoint  |
| Command timeout  | `600` (seconds)                  | Bounded timeout for each `git` invocation    |

Precedence for allowed hosts, mirror root, and API key is: saved
setting → legacy environment variable → built-in default. A saved UI
value takes precedence over the environment variable, so the settings
page stays effective on deployments that still export the old
variables. The command timeout is environment-only
(`REDMINE_GIT_MIRROR_TIMEOUT`).

The built-in default for allowed hosts is empty: no Git host is trusted
until an administrator saves a host or sets
`REDMINE_GIT_MIRROR_ALLOWED_HOSTS`. While the allow-list is empty,
registration and refresh requests are rejected because URL validation
fails closed. A job that was already queued can still run its `git`
clone or fetch and only then fail post-fetch URL validation. Configure at
least one host first.

Legacy environment variables (used only when nothing is saved in the
UI):

| Environment variable               | Purpose                      |
| ---------------------------------- | ---------------------------- |
| `REDMINE_GIT_MIRROR_API_KEY`       | Shared secret                |
| `REDMINE_GIT_MIRROR_ALLOWED_HOSTS` | Comma-separated host names   |
| `REDMINE_GIT_MIRROR_ROOT`          | Mirror parent directory      |
| `REDMINE_GIT_MIRROR_TIMEOUT`       | Timeout in seconds           |

The UI works without any of these environment variables set.

### API key provisioning

1. As a Redmine administrator, open **Administration → Git mirrors**
   and confirm your password if asked. Redmine sudo mode protects the
   whole settings page, so saving hosts/root needs the same
   confirmation as viewing or rotating the key. On the first visit —
   or the first form submission — a high-entropy URL-safe key is
   generated and stored automatically when none is configured yet.
2. Copy the displayed key and provision it to the external client,
   which sends it as an `Authorization: Bearer <key>` header.
3. To invalidate a leaked key, press **Rotate API key**. Rotation
   persists a different key immediately: the previous key stops
   authenticating at once, so update the caller right away.

The key is only ever shown on the administrator settings page. It is
never returned by the mirror API, never placed in a URL, and never
written to flash messages or application logs.

### Mirror root constraints

- The mirror root must be an absolute path.
- It must be a persistent directory mounted into both the web and
  Sidekiq containers so that the web tier can read the mirror after
  the worker writes it.
- Changing the mirror root does not move existing mirrors and does
  not update existing repository records; only newly queued mirrors
  use the new root.

## HTTP API

All routes are JSON-only and require the shared secret in an
`Authorization: Bearer <key>` header. The key is compared in constant
time and is never logged or returned in a response.

The query-string `?key=` form is intentionally rejected: Rails access
logs include query strings by default and the plugin must not let the
secret land there. Rails' default parameter filter also masks the
`Authorization` header so the bearer token never appears in logs.

Example request with curl:

```sh
curl -X POST 'http://redmine.local/sys/redmine_git_mirror/projects/42/repository' \
  -H 'Authorization: Bearer very-secret-value' \
  -H 'Content-Type: application/json' \
  --data '{"url":"https://git.example.com/acme/widgets.git"}'
```

### `POST /sys/redmine_git_mirror/projects/:project_id/repository`

Queue a mirror or refresh of the given project.

Request body:

```json
{ "url": "https://git.example.com/acme/widgets.git" }
```

`url` may also use the SSH form `git@git.example.com:acme/widgets.git`.
Embedded credentials, query strings, fragments, path traversal, and shell
metacharacters are rejected.

Response (`202 Accepted`):

```json
{
  "id": 17,
  "project_id": 42,
  "identifier": "mirror_42_acme_widgets",
  "status": "pending",
  "remote_url": "https://git.example.com/acme/widgets.git",
  "local_path": "/var/lib/redmine/repositories/42/acme__widgets.git",
  "error": null,
  "updated_at": "2026-08-24T07:30:00Z"
}
```

### `GET /sys/redmine_git_mirror/projects/:project_id/repository`

Return the most recent mirror for the project. To fetch a specific mirror,
prefer the path form:

```text
GET /sys/redmine_git_mirror/projects/:project_id/repository/:identifier
```

The legacy `?identifier=...` query form remains accepted for compatibility;
it does not contain a secret.

## Status transitions

`pending` → `cloning` → `ready` (success path)

`pending` or `failed` → `cloning` → `ready` or `failed` (subsequent refresh)

A previously `ready` mirror is preserved on disk when a fetch fails; the
record transitions to `failed` and the error message is exposed through
the API.

Failure persistence is performed outside the row lock held by
`MirrorRefreshJob` so a rolled-back transaction cannot erase the
`failed` status or the captured error message.

## Repository registration

When the worker completes a clone or fetch it creates or reuses a native
`Repository::Git` record that points inside the configured mirror root
(saved setting, else `REDMINE_GIT_MIRROR_ROOT`, else the default).
The record's identifier is deterministic and derived from
`<project_id>_<owner>_<repo>`. Conflicting records (same identifier, different
path) raise `ConflictingRepository` and surface as a `failed` status.

## Testing

```sh
ruby -c plugins/redmine_git_mirror/init.rb
bundle exec rake redmine:plugins:test NAME=redmine_git_mirror RAILS_ENV=test
```

The unit tests cover URL validation, path confinement, command argument
safety, status transitions, idempotent repository association, lock-path
failure persistence, the authentication helper, and the settings layer
(saved-over-ENV precedence, key generation and rotation with auth
invalidation, and input validation including NUL-byte roots). They use
stubs/fakes and never clone a remote. The functional tests cover the
authenticated JSON endpoint (including keys, roots, and hosts changed
behind the process cache) and the administrator-only settings page
(access control with sudo-mode confirmation for key view/rotation, key
display and rotation, validation, flash-message secrecy, and
cross-process settings freshness). Every store read refreshes Redmine's
process-wide settings cache first, so the API workers and the Sidekiq
worker observe rotated keys and new roots/hosts without a restart.
