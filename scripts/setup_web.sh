#!/usr/bin/env bash
# Provision the Gaia web showcase inside the running IRIS container, idempotently:
#   1. Load + compile the REST broker class (Gaia.REST) from the mounted repo.
#   2. Create the /api web application dispatching to Gaia.REST (unauthenticated).
#   3. Enable the UnknownUser account so unauthenticated web requests have an
#      identity that can read the data (local demo only — do not do this in prod).
#   4. Serve the static web/ UI via a /gaia CSP application.
# Requires: the repo bind-mounted at /irisrun/repo (see docker-compose.yml) and
# the IRIS container running. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose exec -T iris iris session iris -U %SYS <<'EOF'
  // --- 1. Load + compile the REST class from the mounted repo ---
  set sc = $system.OBJ.Load("/irisrun/repo/src/web/Gaia.REST.cls", "ck")
  write "load Gaia.REST: ", $system.Status.GetErrorText(sc), !

  // --- 2. REST web application /api -> Gaia.REST (mode 96 = password + unauth) ---
  set ns = $namespace
  zn "%SYS"
  if '##class(Security.Applications).Exists("/api") {
    set p("NameSpace") = "USER"
    set p("DispatchClass") = "Gaia.REST"
    set p("AutheEnabled") = 96
    set p("Enabled") = 1
    set sc = ##class(Security.Applications).Create("/api", .p)
    write "create /api: ", $system.Status.GetErrorText(sc), !
  } else {
    write "create /api: already exists", !
  }

  // --- 3. Static UI web application /gaia -> /irisrun/repo/web ---
  if '##class(Security.Applications).Exists("/gaia") {
    kill q
    set q("NameSpace") = "USER"
    set q("CSPFileStack") = "/irisrun/repo/web/"
    set q("AutheEnabled") = 96
    set q("Enabled") = 1
    set q("ServeFiles") = 1
    set q("ServeFilesTimeout") = 3600
    set sc = ##class(Security.Applications).Create("/gaia", .q)
    write "create /gaia: ", $system.Status.GetErrorText(sc), !
  } else {
    write "create /gaia: already exists", !
  }

  // --- 4. Enable UnknownUser (identity for unauthenticated web access) ---
  set u = ##class(Security.Users).%OpenId("UnknownUser")
  if $isobject(u) {
    set u.Enabled = 1
    do u.Roles.Insert("%All")          // local demo: read access to Gaia.Source
    set sc = u.%Save()
    write "enable UnknownUser: ", $system.Status.GetErrorText(sc), !
  } else {
    write "enable UnknownUser: account missing (unexpected)", !
  }

  zn ns
  write "web-setup-done", !
  halt
EOF
