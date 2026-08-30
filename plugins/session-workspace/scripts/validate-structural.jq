## validate-structural.jq — pure jq half of workspace.json validation.
##
## validate-config.sh runs this filter against the token-interpolated config
## and gets back a flat JSON array of human-readable error strings (empty
## array == passes every rule this file knows how to check). Anything that
## needs the filesystem (cwd/symlink escape, secrets file mode/ownership/
## git-ignore) is NOT here — see validate-config.sh's bash-side checks for
## that half.
##
## There is no bundled JSON Schema validator in this toolchain, so this file
## hand-rolls both the structural checks (unknown keys, required keys, basic
## types) that workspace.schema.json documents, and the cross-field business
## rules a JSON Schema cannot express at all.

def chk(o; allowed; required; lbl):
  if (o | type) == "object" then
    (
      (((o | keys) - allowed)[] | "unknown key in " + lbl + ": " + .),
      (required[] as $k | select((o | has($k)) | not) | "missing required key in " + lbl + ": " + $k)
    )
  else
    "expected an object at " + lbl + ", got " + (o | type)
  end;

def perm_allowed: ["inherit", "default", "plan", "acceptEdits", "dontAsk"];
def coordination_vars: ["SESSION_CHAT_TARGET_MESSAGES_DIR", "SESSION_SCHEDULER_HOME", "SESSION_CONTEXT_HOME"];
def harness_engine_vars: [
  "SESSION_WORKSPACE_CONFIG",
  "SESSION_WORKSPACE_PROJECT_ROOT",
  "SESSION_WORKSPACE_PANE_NAME",
  "SESSION_WORKSPACE_ROLE",
  "SESSION_WORKSPACE_PANE_CWD",
  "SESSION_WORKSPACE_HARNESS_MODE"
];

[
  # ---- schema_version ----
  (.schema_version as $version |
   if (has("schema_version") | not) or ([1, 2] | index($version)) == null then
     "schema_version must be 1 or 2 (got: " + ((.schema_version // "missing") | tostring) + ")"
   else empty end),

  # ---- structural: unknown/missing keys, one call per object shape ----
  (if .schema_version == 2 then
     chk(.; ["schema_version", "project", "runtimes", "roles", "stores", "env", "secrets", "sessions", "behavior", "browser", "harness"]; ["project", "runtimes", "roles", "stores", "sessions"]; "top-level")
   else
     chk(.; ["schema_version", "project", "runtimes", "roles", "stores", "env", "secrets", "sessions", "behavior", "browser"]; ["project", "runtimes", "roles", "stores", "sessions"]; "top-level")
   end),
  (if .schema_version == 2 and has("harness") then
     chk(.harness; ["enabled", "mode", "profile", "roles", "gates"]; ["enabled"]; "harness")
   else empty end),
  (if .schema_version == 2 and (.harness.enabled // false) == true then
     chk(.harness; ["enabled", "mode", "profile", "roles", "gates"]; ["enabled", "mode", "profile", "roles", "gates"]; "harness"),
     chk(.harness.roles // {}; ["orchestrator", "executor", "reviewer"]; ["orchestrator", "executor", "reviewer"]; "harness.roles"),
     chk(.harness.gates // {}; ["plan_review_ttl_minutes", "audit_ttl_minutes"]; ["plan_review_ttl_minutes", "audit_ttl_minutes"]; "harness.gates")
   else empty end),
  chk(.project // {}; ["id", "display_name", "root"]; ["id", "root"]; "project"),
  chk(.stores // {}; ["base", "pin", "overrides", "memory"]; ["pin"]; "stores"),
  chk(.stores.memory // {}; ["mode", "root", "shard"]; []; "stores.memory"),
  chk(.stores.memory.shard // {}; ["strip_prefix", "strip_suffixes", "fallback"]; []; "stores.memory.shard"),
  chk(.env // {}; ["groups", "pane_name_aliases"]; []; "env"),
  chk(.secrets // {}; ["env_file", "allow", "visible_to_roles", "on_missing"]; []; "secrets"),
  chk(.behavior // {}; ["default_start_target", "attach", "stop_scope", "save_before_stop", "session_chat_helper"]; []; "behavior"),
  chk(.behavior.session_chat_helper // {}; ["resolve", "on_missing"]; []; "behavior.session_chat_helper"),
  (if has("browser") then chk(.browser; ["session_id", "port", "chrome_program", "mcp_package", "mcp_server_name"]; ["session_id", "port", "chrome_program", "mcp_package"]; "browser") else empty end),

  ((.runtimes // {}) | to_entries[] | . as $e |
    chk($e.value; ["program", "args"]; ["program"]; "runtimes." + $e.key)),

  ((.roles // {}) | to_entries[] | . as $e | (
    chk($e.value; ["runtime", "agent", "grants", "env_group"]; ["runtime"]; "roles." + $e.key),
    chk($e.value.agent // {}; ["model", "effort", "profile", "permission_mode"]; []; "roles." + $e.key + ".agent")
  )),

  ((.env.groups // {}) | to_entries[] | . as $e |
    chk($e.value; ["values", "pin_to_session"]; ["values"]; "env.groups." + $e.key)),

  ((.sessions // []) | to_entries[] | . as $s | ($s.value.id // ("sessions[" + ($s.key | tostring) + "]")) as $slabel | (
    chk($s.value; ["id", "name", "window_index", "layout", "retain_layout", "panes"]; ["id", "name", "panes"]; "sessions." + $slabel),
    chk($s.value.layout // {}; ["kind", "name", "only_when_fresh", "mask_after_split_hook", "nodes", "pane_order"]; ($s.value.layout | if . then ["kind"] else [] end); "sessions." + $slabel + ".layout"),
    (($s.value.layout.nodes // []) | to_entries[] | . as $n |
      chk($n.value; ["id", "from", "dir", "percent"]; ["id"]; "sessions." + $slabel + ".layout.nodes[" + ($n.key | tostring) + "]")),
    (($s.value.panes // []) | to_entries[] | . as $p | ($p.value.name // ("panes[" + ($p.key | tostring) + "]")) as $plabel | (
      chk($p.value; ["name", "role", "cwd", "optional", "command", "port", "agent"]; ["name", "role"]; "sessions." + $slabel + ".panes." + $plabel),
      chk($p.value.agent // {}; ["model", "effort", "profile", "permission_mode"]; []; "sessions." + $slabel + ".panes." + $plabel + ".agent")
    ))
  )),

  # ---- schema-v2 opt-in harness contract. The executable policy owns a
  #      non-configurable safety floor; config only selects the typed profile,
  #      mode, semantic role names, and gate freshness windows. ----
  (if .schema_version == 2 and has("harness") then
     (if (.harness.enabled | type) != "boolean" then
        "harness.enabled must be a boolean"
      else empty end),
     (if (.harness.enabled // false) == false and ((.harness | keys) - ["enabled"] | length) != 0 then
        "harness.enabled=false must not include mode, profile, roles, or gates"
      else empty end)
   else empty end),
  (if .schema_version == 2 and (.harness.enabled // false) == true then
     .harness as $h |
     (if (["audit", "enforce"] | index($h.mode)) == null then
        "harness.mode must be one of [\"audit\",\"enforce\"]"
      else empty end),
     (if $h.profile != "strict-v1" then
        "harness.profile must be strict-v1"
      else empty end),
     (($h.roles // {}) as $hr |
       ([($hr.orchestrator // null), ($hr.executor // null), ($hr.reviewer // null)] | map(select(type == "string" and length > 0))) as $role_values |
       (if $role_values | length != 3 then
          "harness.roles values must be non-empty strings"
        elif ($role_values | unique | length) != 3 then
          "harness.roles orchestrator, executor, and reviewer must name three distinct roles"
        else empty end),
       (($role_values[]) as $role_name |
         if $role_name == "service" then
           "harness.roles must not use the reserved service role"
         elif ((.roles // {}) | has($role_name)) | not then
           "harness.roles references unknown role \"" + $role_name + "\""
         elif (.roles[$role_name].runtime // "") == "shell" then
           "harness role \"" + $role_name + "\" must not use the built-in shell runtime"
         else empty end),
       ([.sessions[] | .panes[]] as $panes |
         ([ $panes[] | select(.role == $hr.orchestrator) ] | length) as $orchestrators |
         ([ $panes[] | select(.role == $hr.executor) ] | length) as $executors |
         ([ $panes[] | select(.role == $hr.reviewer) ] | length) as $reviewers |
         (if $orchestrators != 1 then
            "enabled harness requires exactly one orchestrator pane (got: " + ($orchestrators | tostring) + ")"
          else empty end),
         (if $executors < 1 then
            "enabled harness requires at least one executor pane"
          else empty end),
         (if $reviewers < 1 then
            "enabled harness requires at least one reviewer pane"
          else empty end),
         ($panes[] | select(.role == $hr.executor) as $executor |
           if (($executor.cwd // "") | type) != "string" or ($executor.cwd // "") == "" or ($executor.cwd == ".") then
             "harness executor pane " + ($executor.name // "?") + " must declare a non-dot cwd"
           else
             ([ $panes[] | select(.role == $hr.reviewer and (.cwd // null) == $executor.cwd) ] | length) as $matches |
             if $matches != 1 then
               "harness executor pane " + ($executor.name // "?") + " must have exactly one reviewer pane with cwd \"" + $executor.cwd + "\" (got: " + ($matches | tostring) + ")"
             else empty end
           end),
         ($panes[] | select(.role == $hr.reviewer) as $reviewer |
           if (($reviewer.cwd // "") | type) != "string" or ($reviewer.cwd // "") == "" or ($reviewer.cwd == ".") then
             "harness reviewer pane " + ($reviewer.name // "?") + " must declare a non-dot cwd"
           else
             ([ $panes[] | select(.role == $hr.executor and (.cwd // null) == $reviewer.cwd) ] | length) as $matches |
             if $matches != 1 then
               "harness reviewer pane " + ($reviewer.name // "?") + " must have exactly one executor pane with cwd \"" + $reviewer.cwd + "\" (got: " + ($matches | tostring) + ")"
             else empty end
           end)
       )
     ),
     (($h.gates.plan_review_ttl_minutes // null) as $ttl |
       if ($ttl | type) != "number" or ($ttl | floor) != $ttl or $ttl < 1 or $ttl > 1440 then
         "harness.gates.plan_review_ttl_minutes must be an integer in 1..1440"
       else empty end),
     (($h.gates.audit_ttl_minutes // null) as $ttl |
       if ($ttl | type) != "number" or ($ttl | floor) != $ttl or $ttl < 1 or $ttl > 1440 then
         "harness.gates.audit_ttl_minutes must be an integer in 1..1440"
       else empty end)
   else empty end),

  # ---- commands must be argv arrays, never a command string ----
  ((.sessions // [])[] | (.panes // [])[] | . as $p |
    if ($p | has("command")) then
      (if ($p.command | type) == "string" then
         "pane " + ($p.name // "?") + ": command must be an argv array, not a string (got: \"" + $p.command + "\")"
       elif ($p.command | type) != "array" then
         "pane " + ($p.name // "?") + ": command must be an argv array (got type: " + ($p.command | type) + ")"
       else empty end)
    else empty end),

  # ---- project.id charset (also documented as a pattern in
  #      workspace.schema.json, but the hand-rolled jq validator never
  #      enforced it -- project.id is used to build on-disk state-dir paths
  #      (sw_project_state_dir/sw_layout_file) and is spliced into session/
  #      pane names via ${PROJECT_ID} interpolation, so an unrestricted value
  #      is a path-construction and downstream-charset hole) ----
  ((.project.id // "") as $pid |
    if ($pid | test("\\A[a-z0-9][a-z0-9-]*\\z") | not) then
      "project.id has invalid characters (must match ^[a-z0-9][a-z0-9-]*$): " + $pid
    else empty end),

  # ---- session id charset -- session.id (distinct from session.name) is
  #      used verbatim to build the on-disk layout-cache filename
  #      (sw_layout_file: "<state-dir>/layouts/<id>.layout"); an unrestricted
  #      id could otherwise inject "/" and escape the layouts directory ----
  ((.sessions // [])[] | . as $s | ($s.id // "") as $sid |
    if ($sid | test("\\A[A-Za-z0-9._-]+\\z") | not) then
      "session id has invalid characters (allowed: A-Za-z0-9._-): " + $sid
    else empty end),

  # ---- first-class Chrome DevTools browser integration ----
  (if has("browser") then
    .browser as $b |
    ([.sessions[] | select(.id == $b.session_id)] | length) as $matches |
    (if ($b.session_id | type) != "string" or ($b.session_id | test("\\A[A-Za-z0-9._-]+\\z") | not) then
       "browser.session_id must match ^[A-Za-z0-9._-]+$"
     elif $matches != 1 then
       "browser.session_id must reference exactly one sessions[].id (got: " + ($b.session_id | tostring) + ")"
     else empty end),
    (if ($b.port | type) != "number" or ($b.port | floor) != $b.port or $b.port < 1 or $b.port > 65535 then
       "browser.port must be an integer in 1..65535"
     else empty end),
    (if ($b.chrome_program | type) != "string" or ($b.chrome_program | length) == 0 or ($b.chrome_program | test("[\\r\\n]")) then
       "browser.chrome_program must be a non-empty single-line string"
     else empty end),
    (if ($b.mcp_package | type) != "string" or ($b.mcp_package | test("\\Achrome-devtools-mcp@[0-9]+\\.[0-9]+\\.[0-9]+([-.][A-Za-z0-9.]+)?\\z") | not) then
       "browser.mcp_package must pin an exact version such as chrome-devtools-mcp@1.2.3"
     else empty end),
    (($b.mcp_server_name // "chrome-devtools") as $n |
      if ($n | type) != "string" or ($n | test("\\A[A-Za-z0-9_-]+\\z") | not) then
        "browser.mcp_server_name must match ^[A-Za-z0-9_-]+$"
      else empty end),
    (if $matches == 1 then
       (.sessions[] | select(.id == $b.session_id)) as $s |
       (if ($s.panes | length) != 1 then "browser session must contain exactly one pane" else empty end),
       ($s.panes[0] // {}) as $p |
       (if $p.role != "service" then "browser session pane role must be named service so --no-services remains authoritative" else empty end),
       (if ($p.optional // false) then "browser session pane must not be optional" else empty end),
       (if ($p | has("command")) then "browser session pane must omit command; session-workspace derives the Chrome argv" else empty end),
       (if ($p | has("port")) then "browser session pane must omit port; use browser.port as the single source of truth" else empty end),
       ((.roles[$p.role].runtime // "") as $rt | if $rt != "shell" then "browser session pane role must use the built-in shell runtime" else empty end)
     else empty end),
    ([.sessions[] | .panes[] | select(has("port")) | .port] | index($b.port)) as $port_collision |
    (if $port_collision != null then "browser.port duplicates an explicit sessions[].panes[].port" else empty end)
   else empty end),

  # ---- session/pane name uniqueness (post-interpolation) + charset ----
  ([(.sessions // [])[] | .name] as $snames | (
    (($snames | group_by(.) | map(select(length > 1) | .[0]))[] | "duplicate session name after resolution: " + .),
    ($snames[] | select(test("\\A[A-Za-z0-9._-]+\\z") | not) | "session name has invalid characters (allowed: A-Za-z0-9._-): " + .)
  )),
  ([(.sessions // [])[] | (.panes // [])[] | .name] as $pnames | (
    (($pnames | group_by(.) | map(select(length > 1) | .[0]))[] | "duplicate pane name after resolution: " + .),
    ($pnames[] | select(test("\\A[A-Za-z0-9._-]+\\z") | not) | "pane name has invalid characters (allowed: A-Za-z0-9._-): " + .)
  )),

  # ---- split_tree layout: node sequencing, percent range, pane_order ----
  ((.sessions // [])[] | . as $s | ($s.id // $s.name // "?") as $slabel |
    ($s.layout // {}) as $lay |
    if ($lay.kind // "") == "split_tree" then
      (
        (($lay.nodes // [] | map(.id)) as $ids |
          if ($ids | unique | length) != ($ids | length) then
            "session " + $slabel + ": layout.nodes ids must be unique"
          else empty end),
        (($lay.nodes // []) | reduce .[] as $n
          ({seen: [], errs: []};
            if (.seen | length) == 0 then
              if ($n | has("from")) then
                {seen: (.seen + [$n.id]), errs: (.errs + ["session " + $slabel + ": first split_tree node (" + $n.id + ") must not have \"from\" (it is the root pane)"])}
              else
                {seen: (.seen + [$n.id]), errs: .errs}
              end
            else
              (if ($n | has("from") | not) then
                 {seen: (.seen + [$n.id]), errs: (.errs + ["session " + $slabel + ": split_tree node " + $n.id + " is missing \"from\""])}
               elif (.seen | index($n.from)) == null then
                 {seen: (.seen + [$n.id]), errs: (.errs + ["session " + $slabel + ": split_tree node " + $n.id + " references from=\"" + ($n.from // "") + "\" which does not exist earlier in nodes[]"])}
               elif (($n.percent // 0) < 1 or ($n.percent // 0) > 99) then
                 {seen: (.seen + [$n.id]), errs: (.errs + ["session " + $slabel + ": split_tree node " + $n.id + " percent must be 1..99 (got: " + (($n.percent // "missing") | tostring) + ")"])}
               else
                 {seen: (.seen + [$n.id]), errs: .errs}
               end)
            end) | .errs[]),
        (($lay.nodes // [] | map(.id)) as $ids | ($lay.pane_order // []) as $order |
          if ((($ids - $order) + ($order - $ids)) | length) > 0 or (($order | length) != ($ids | length)) then
            "session " + $slabel + ": layout.pane_order must be a permutation of the split_tree node ids " + ($ids | tostring) + " (got: " + ($order | tostring) + ")"
          else empty end),
        ((($lay.pane_order // []) | length) as $ol | (($s.panes // []) | length) as $pl |
          if $ol != $pl then
            "session " + $slabel + ": layout.pane_order length (" + ($ol | tostring) + ") must equal panes.length (" + ($pl | tostring) + ")"
          else empty end)
      )
    else empty end),

  # ---- stores.pin: known stores only, no duplicates ----
  ((.stores.pin // [])[] | select(. != "messages" and . != "scheduler" and . != "contexts") |
    "stores.pin contains an unknown store: " + .),
  ((.stores.pin // []) as $pin | if ($pin | unique | length) != ($pin | length) then "stores.pin must not contain duplicates" else empty end),

  # ---- roles.*.grants must name a pinned store (or the always-valid "memory") ----
  ((.stores.pin // []) as $pin |
    (.roles // {}) | to_entries[] | . as $r |
    (($r.value.grants // [])[] | . as $g |
      if $g == "memory" then empty
      elif ($pin | index($g)) == null then
        "roles." + $r.key + ".grants names \"" + $g + "\" which is not in stores.pin " + ($pin | tostring)
      else empty end)),

  # ---- stores.memory.mode == per-pane: every dev pane name must be prefixed ----
  (if (.stores.memory.mode // "shared") == "per-pane" then
     ((.project.id // "") as $pid |
       ((.roles // {}) | with_entries(select(.value.env_group == "dev")) | keys) as $dev_roles |
       ((.sessions // [])[] | (.panes // [])[] | . as $p |
         if ($dev_roles | index($p.role)) != null then
           (if ($p.name | startswith($pid + "-") | not) then
              "stores.memory.mode is per-pane: dev pane \"" + $p.name + "\" (role " + $p.role + ") must start with \"" + $pid + "-\""
            else empty end)
         else empty end))
   else empty end),

  # ---- env var NAMES/VALUES ----
  ((.env.groups // {}) | to_entries[] | . as $g |
    (($g.value.values // {}) | to_entries[] | . as $kv | (
      (if ($kv.key | test("\\A[A-Z_][A-Z0-9_]*\\z") | not) then
         "env.groups." + $g.key + ".values key \"" + $kv.key + "\" must match ^[A-Z_][A-Z0-9_]*$"
       else empty end),
      (if (coordination_vars | index($kv.key)) != null then
         "env.groups." + $g.key + ".values must not set " + $kv.key + " -- it is derived from stores.pin, never a free-form env value"
       else empty end),
      (if (harness_engine_vars | index($kv.key)) != null then
         "env.groups." + $g.key + ".values must not set " + $kv.key + " -- it is reserved for engine-owned per-pane harness identity"
       else empty end),
      (($kv.value | if startswith("${PROJECT_ROOT}") then .[("${PROJECT_ROOT}" | length):] else . end) as $rest |
        if ($rest | test("[$`]")) then
          "env.groups." + $g.key + ".values." + $kv.key + " must not contain $ or ` (only an exact \"${PROJECT_ROOT}\" prefix is allowed)"
        else empty end)
    ))),

  # ---- env.pane_name_aliases[] charset -- these become bare env-var NAMES
  #      on the left of "export NAME=..." in adapters.sh's render_env_exports
  #      (the VALUE is printf %q-quoted, the NAME never was); an unrestricted
  #      name lets a config inject a second statement into the export string
  #      that lifecycle.sh later runs via `bash -c` (e.g.
  #      "EVIL; touch /tmp/pwned; export X"). Same charset as
  #      env.groups.*.values keys, for the same reason. ----
  ((.env.pane_name_aliases // [])[] | . as $alias |
    if ($alias | test("\\A[A-Z_][A-Z0-9_]*\\z") | not) then
      "env.pane_name_aliases entry \"" + $alias + "\" must match ^[A-Z_][A-Z0-9_]*$"
    elif (harness_engine_vars | index($alias)) != null then
      "env.pane_name_aliases must not contain reserved engine-owned harness identity name " + $alias
    else empty end),

  # ---- secrets.allow[] charset -- these keys are passed as `adapters.sh
  #      secret-value --key KEY`, which historically resolved them via bash
  #      indirect expansion ("${!key}"). Indirect expansion evaluates an
  #      array-subscript, and a subscript may contain command substitution,
  #      so a key like "x[$(cmd)]" ran `cmd`. adapters.sh no longer uses
  #      indirect expansion at all (printenv instead), but the key is still
  #      charset-restricted here as defense in depth against any future
  #      lookup mechanism that would reintroduce the hazard, and because a
  #      key is inherently meant to be a plain env-var identifier. ----
  ((.secrets.allow // [])[] | . as $key |
    if ($key | test("\\A[A-Za-z_][A-Za-z0-9_]*\\z") | not) then
      "secrets.allow entry \"" + $key + "\" must match ^[A-Za-z_][A-Za-z0-9_]*$"
    else empty end),

  # ---- behavior.default_start_target must name something startable: it IS
  #      the TARGET a bare `start` uses, so an unresolvable value would only
  #      surface as "unknown session target" at launch time. ----
  ((.behavior.default_start_target // empty) as $t |
    if $t != "all" and (((.sessions // []) | map(.id // "")) | index($t)) == null then
      "behavior.default_start_target must be \"all\" or one of sessions[].id (got: \"" + $t + "\")"
    else empty end),

  # ---- behavior.attach is an enum, not free text: workspace-start.sh
  #      branches on it, so a typo must fail validation rather than silently
  #      fall through to the default. ----
  ((.behavior.attach // empty) as $a |
    if (["if_terminal", "never"] | index($a)) == null then
      "behavior.attach must be one of [\"if_terminal\",\"never\"] (got: \"" + $a + "\")"
    else empty end),

  # ---- permission_mode allowlist (bypassPermissions is never allowed) ----
  ((.roles // {}) | to_entries[] | . as $r | ($r.value.agent.permission_mode // empty) as $pm |
    if (perm_allowed | index($pm)) == null then
      "roles." + $r.key + ".agent.permission_mode must be one of " + (perm_allowed | tostring) + " (got: " + $pm + ")" + (if $pm == "bypassPermissions" then " -- bypassPermissions is never allowed" else "" end)
    else empty end),
  ((.sessions // [])[] | (.panes // [])[] | . as $p | ($p.agent.permission_mode // empty) as $pm |
    if (perm_allowed | index($pm)) == null then
      "pane " + ($p.name // "?") + ".agent.permission_mode must be one of " + (perm_allowed | tostring) + " (got: " + $pm + ")" + (if $pm == "bypassPermissions" then " -- bypassPermissions is never allowed" else "" end)
    else empty end),

  # ---- referential sanity: roles/runtimes/roles must resolve ----
  ((.runtimes // {}) | keys) as $rt_names |
  ((.roles // {}) | to_entries[] | . as $r |
    if ($rt_names | index($r.value.runtime)) == null and $r.value.runtime != "shell" then
      "roles." + $r.key + ".runtime references unknown runtime \"" + ($r.value.runtime // "") + "\" (not declared in runtimes, and not the built-in \"shell\")"
    else empty end),
  ((.roles // {}) | keys) as $role_names |
  ((.sessions // [])[] | (.panes // [])[] | . as $p |
    if ($role_names | index($p.role)) == null then
      "pane " + ($p.name // "?") + " references unknown role \"" + ($p.role // "") + "\""
    else empty end),
  ((.secrets.visible_to_roles // [])[] | . as $vr |
    if ($role_names | index($vr)) == null then
      "secrets.visible_to_roles references unknown role \"" + $vr + "\""
    else empty end)
]
| flatten
