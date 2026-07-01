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

# --- 1. Load + compile the REST class INTO THE USER NAMESPACE (where the web
#        app dispatches — loading it in %SYS makes the route 404). ---
docker compose exec -T iris iris session iris -U USER <<'EOF'
  set sc = $system.OBJ.Load("/irisrun/repo/src/web/Gaia.REST.cls", "ck")
  write "load Gaia.REST (USER): ", $system.Status.GetErrorText(sc), !
  halt
EOF

docker compose exec -T iris iris session iris -U %SYS <<'EOF'
  // Apps live under /csp/ because the Community Edition built-in web server
  // only forwards the /csp path prefix to IRIS (its CSP.ini APP_PATH_INDEX
  // knows only "/" and "/csp"). REST at /csp/gaia/api, static UI at /csp/gaia/ui.

  // --- 2. REST web application /csp/gaia/api -> Gaia.REST (96 = password+unauth) ---
  set ns = $namespace
  zn "%SYS"
  if '##class(Security.Applications).Exists("/csp/gaia/api") {
    set p("NameSpace") = "USER"
    set p("DispatchClass") = "Gaia.REST"
    set p("AutheEnabled") = 96
    set p("Enabled") = 1
    set sc = ##class(Security.Applications).Create("/csp/gaia/api", .p)
    write "create /csp/gaia/api: ", $system.Status.GetErrorText(sc), !
  } else {
    write "create /csp/gaia/api: already exists", !
  }

  // --- 3. Static UI web application /csp/gaia/ui -> /irisrun/repo/web ---
  if '##class(Security.Applications).Exists("/csp/gaia/ui") {
    kill q
    set q("NameSpace") = "USER"
    set q("Path") = "/irisrun/repo/web/"
    set q("AutheEnabled") = 96
    set q("Enabled") = 1
    set q("ServeFiles") = 1
    set q("ServeFilesTimeout") = 3600
    set sc = ##class(Security.Applications).Create("/csp/gaia/ui", .q)
    write "create /csp/gaia/ui: ", $system.Status.GetErrorText(sc), !
  } else {
    write "create /csp/gaia/ui: already exists", !
  }

  // --- 4. UnknownUser is the identity for unauthenticated web access. Ensure it
  //         exists, is enabled, and has read access (local demo only: %All). We
  //         use Create-or-Modify with a props array (reliable across images;
  //         direct object %Save on this account can silently no-op). ---
  kill up
  set up("Enabled") = 1
  set up("Roles") = "%All"
  set up("Password") = "SYS"
  if ##class(Security.Users).Exists("UnknownUser") {
    set sc = ##class(Security.Users).Modify("UnknownUser", .up)
    write "modify UnknownUser: ", $system.Status.GetErrorText(sc), !
  } else {
    set sc = ##class(Security.Users).Create("UnknownUser", .up)
    write "create UnknownUser: ", $system.Status.GetErrorText(sc), !
  }

  zn ns
  write "web-setup-done", !
  halt
EOF
