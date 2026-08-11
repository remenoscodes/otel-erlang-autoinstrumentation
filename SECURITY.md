# Security

## Reporting a vulnerability

Open a GitHub issue, or for anything sensitive, a private security advisory
via this repository's Security tab.

## Known advisories in transitive dependencies

`mix deps.get` currently flags two advisories in `cowlib` (pulled in
transitively via `opentelemetry_cowboy` → `cowboy`/`cowboy_telemetry`), both
still present in `cowlib` 2.19.0, the latest release as of this writing —
there is no patched version to upgrade to yet.

| ID | Severity | Function | Advisory |
|---|---|---|---|
| CVE-2026-43966 | Medium | `cow_http_struct_hd:escape_string/2` | HTTP response splitting via non-VCHAR bytes |
| CVE-2026-43969 | Low | `cow_cookie:cookie/1` | Cookie request header injection via unvalidated encoder |

**Assessment for this package specifically:** neither function is called
anywhere in `otel_auto_bootstrap`'s own code (`lib/`, `src/`) — this
package never constructs cookies or structured HTTP headers. Both
functions are reachable only through the *host* application's own use of
Cowboy to build outbound responses with attacker-influenced cookie/header
values, which is a pre-existing property of running Cowboy at all, not
something this package introduces or amplifies. The plain-Cowboy
integration path (`OtelAutoBootstrap.retrofit_cowboy_telemetry/0`) doesn't
touch cookie or structured-header encoding either — it only mutates a
listener's `stream_handlers` list via `ranch:set_protocol_options/2`.

The bundle's own copy of `cowlib` is a fallback, not authoritative on most
real hosts: any target release that already runs Cowboy already has its
own `cowlib` loaded before this package's bootstrap ever runs, and that
copy — not the bundle's — is what every request actually goes through (see
README.md's "dependency collision" finding). The bundle's copy only
matters on a host that has Cowboy dependencies available to load but no
`cowlib` already resident, which the spikes in this repo don't represent
as a realistic deployment shape.

This will be revisited (dependency bump, or an explicit mitigation) once a
patched `cowlib` release exists. Tracked informally here rather than as an
open issue since there's nothing actionable to *do* yet beyond wait for
upstream.
