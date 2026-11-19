include "runtime";
include "secret-policy";

## compute-plan.jq — pure jq half of `workspace-plan`.
##
## Takes the already-validated, token-interpolated workspace.json on stdin
## plus a few bash-computed inputs (project root, config path, and a
## pane-name -> resolved-cwd map, since canonicalizing a path against the
## filesystem needs `cd ... && pwd -P`, not something jq can do) and emits
## one normalized "plan" JSON object. Both the --json renderer and the
## human-readable renderer in workspace-plan.sh read from this single
## computation, so the two output modes can never disagree.
##
## Resolution precedence for agent.{model,effort,profile,permission_mode}:
## pane-level `agent` -> role-level `roles.<role>.agent` -> omitted (no
## engine flag). A value of "inherit" is treated exactly like "omitted" at
## whichever level it appears, per the plan's binding decision #1. Phase B
## has no CLI-override step (that lands with workspace-start in Phase C).
##
## Environment variable NAMES ONLY are ever computed here — never a value.
## Shown names are the union of: the role's env_group value keys, configured
## pane_name_aliases, the engine-always identity and harness vars, and — when the role's
## env_group has pin_to_session=true — the coordination HOME var name for
## each store in stores.pin.
##
## Each session additionally carries `pinned_session_env`: the NAMES the
## engine mirrors into that tmux session's environment with `tmux
## set-environment` (see lifecycle.sh's _sw_pin_session_env), i.e. the union
## over the session's panes of the pin_to_session group's value keys plus the
## stores.pin coordination vars. Per-pane identity — every engine-always var
## and pane_name_aliases (whose value IS the pane name) — is deliberately
## excluded, as are secrets, which never travel through session env at all.
## This field exists so the displayed plan and the engine's actual mirroring
## are computed from one definition and cannot drift apart.

def resolve_field(pane_val; role_val):
  if (pane_val != null and pane_val != "inherit") then pane_val
  elif (role_val != null and role_val != "inherit") then role_val
  else null end;

def store_path(base; overrides; store):
  ((overrides[store]) // (base + "/" + store)) as $p
  | if ($p | startswith("/")) then $p else ($root + "/" + $p) end;

def memory_shard(name; pid; strip_prefix; strip_suffixes; fallback):
  (if (strip_prefix != "" and (name | startswith(strip_prefix))) then name[(strip_prefix | length):] else name end) as $s1
  | (reduce strip_suffixes[] as $suf ($s1; if (. | endswith($suf)) then .[0:(length - ($suf | length))] else . end)) as $s2
  | if ($s2 == "") then fallback else $s2 end;

# The part of a pane's environment scope that its launch pins
# (SESSION_WORKSPACE_SCOPE_JSON). A bound pane pins its own environment entry
# and the root orchestrator's name; the unbound root orchestrator pins the
# environments it coordinates directly (those without a local orchestrator).
# Adding, changing or removing ANOTHER environment therefore leaves a running
# pane's identity intact, while a change to its own entry still fails it
# closed until it restarts. The policy reads everything else (route peers,
# owned sessions) from the validated config on each call.
#
# Peers (schema 6): a worker pins its checkout's own entry and its owner, an
# orchestrator only its own pane name. Neither depends on which other
# orchestrators or workers exist, so starting or stopping one changes no other
# pane's pinned value. Any other pane keeps the formula above.
def scope_identity:
  if . == null then null
  elif has("peer") then {environment: null, peer: .peer}
  elif has("owner") then
    . as $sc
    | {environment: $sc.environment, own: ([$sc.environments[] | select(.id == $sc.environment)][0] // null), owner: $sc.owner}
  else . as $sc
  | {environment: $sc.environment, root_orchestrator: $sc.root_orchestrator}
    + (if $sc.environment != null
       then {own: ([$sc.environments[] | select(.id == $sc.environment)][0] // null)}
       else {direct: [$sc.environments[] | select((.orchestrator // null) == null)]} end)
  end;

def coordination_var_name(store):
  if store == "messages" then "SESSION_CHAT_TARGET_MESSAGES_DIR"
  elif store == "scheduler" then "SESSION_SCHEDULER_HOME"
  elif store == "contexts" then "SESSION_CONTEXT_HOME"
  else empty end;

. as $cfg
| ([ $cfg.browsers[]?, $cfg.browser? | select(. != null) ] | map(. as $b | . + {
    pane_name: ($b.pane_name // ([$cfg.sessions[] | select(.id == $b.session_id) | .panes[].name][0])),
    profile_dir: ($browser_profiles[$b.session_id] // $browser_profile_dir),
    browser_url: ("http://127.0.0.1:" + ($b.port | tostring)),
    mcp_server_name: ($b.mcp_server_name // "chrome-devtools")
  })) as $browsers
| ($browsers[0] // null) as $browser
| ($browser.pane_name // null) as $browser_pane_name
| ([($cfg.sessions // [])[] | (.panes // [])[]]) as $all_panes
| (($cfg.schema_version == 5 or $cfg.schema_version == 6)) as $envs_schema
| (($cfg.schema_version == 6) and ($cfg | has("peers"))) as $peers
| (($cfg.schema_version == 2 or $cfg.schema_version == 3 or ($cfg.schema_version == 4 or $cfg.schema_version == 5 or $cfg.schema_version == 6)) and ($cfg.harness.enabled // false)) as $harness_active
| (($cfg.schema_version == 3 or ($cfg.schema_version == 4 or $cfg.schema_version == 5 or $cfg.schema_version == 6)) and $harness_active and ($cfg.harness | has("guards"))) as $guards_configured
| ($cfg.stores.base // ".tmp") as $store_base
| ($cfg.stores.overrides // {}) as $store_overrides
| ($cfg.stores.pin // []) as $pin
| ($cfg.stores.memory // {}) as $mem
| ($mem.mode // "shared") as $mem_mode
| ($mem.root // ".agents/memory") as $mem_root_rel
| (if ($mem_root_rel | startswith("/")) then $mem_root_rel else ($root + "/" + $mem_root_rel) end) as $mem_root_abs
| ($mem.shard.strip_prefix // "") as $mem_strip_prefix
| ($mem.shard.strip_suffixes // []) as $mem_strip_suffixes
| ($mem.shard.fallback // "master") as $mem_fallback
| ($cfg.project.id // "") as $pid
| ($cfg.env.pane_name_aliases // []) as $aliases
| ([
    "TMUX_PANE",
    "SESSION_CHAT_PANE_NAME",
    "KNOWLEDGE_PANE_NAME",
    "SESSION_WORKSPACE_CONFIG",
    "SESSION_WORKSPACE_PROJECT_ROOT",
    "SESSION_WORKSPACE_PANE_NAME",
    "SESSION_WORKSPACE_ROLE",
    "SESSION_WORKSPACE_PANE_CWD",
    "SESSION_WORKSPACE_HARNESS_MODE",
    "SESSION_WORKSPACE_READ_PATHS_JSON"
  ] + (if $envs_schema and ($cfg.environments // [] | length) > 0 then ["SESSION_WORKSPACE_SCOPE_JSON"] else [] end) + [
  ] + (if $guards_configured then ["SESSION_WORKSPACE_GUARDS_JSON"] else [] end)) as $engine_always
|
({
  schema_version: $cfg.schema_version,
  config_path: $config_path,
  secret_keys_by_role: ($cfg | secret_keys_by_role),
  environments: ($cfg.environments // []),
  project: {
    id: $pid,
    display_name: ($cfg.project.display_name // $pid),
    root: $root
  },
  harness: (if $harness_active then ({
    active: true,
    mode: $cfg.harness.mode,
    profile: $cfg.harness.profile,
    roles: $cfg.harness.roles,
    gates: $cfg.harness.gates
  } + (if $guards_configured then {guards: $cfg.harness.guards} else {} end)) else {active: false} end),
  sessions: [
    ($cfg.sessions // [])[] | . as $s
    | ([$browsers[] | select(.session_id == $s.id)][0] // null) as $browser
    | ($browser.pane_name // null) as $browser_pane_name
    | {
        id: $s.id,
        name: $s.name,
        window_index: ($s.window_index // 0),
        layout: ($s.layout // {kind: "standard", name: "tiled"}),
        retain_layout: ($s.retain_layout // false),
        pinned_session_env: [
          ($s.panes // [])[]
          | ($cfg.roles[.role] // {}) as $r
          | ($r.env_group // "none") as $eg
          | ($cfg.env.groups[$eg] // {values: {}, pin_to_session: false}) as $g
          | select($g.pin_to_session // false)
          | ((($g.values // {}) | keys) + [$pin[] | coordination_var_name(.)])[]
          | select(. as $n | ($engine_always | index($n)) == null)
        ] | unique | sort,
        panes: [
          ($s.panes // [])[] | . as $p
          | ($cfg.roles[$p.role] // {}) as $role
          | pane_runtime($cfg; $p) as $runtime_name
          | ($cfg.runtimes[$runtime_name] // null) as $runtime
          | ($role.env_group // "none") as $env_group
          | ($cfg.env.groups[$env_group] // {values: {}, pin_to_session: false}) as $group
          | ($group.pin_to_session // false) as $pin_to_session
          | (if $peers and ($p | has("worker")) then {
                environments: $cfg.environments,
                environment: $p.worker.checkout,
                owner: $p.worker.owner,
                root_orchestrator: null
              }
             elif $peers and $p.role == $cfg.harness.roles.orchestrator then {
                environments: $cfg.environments,
                environment: null,
                peer: $p.name,
                root_orchestrator: null
              }
             elif $peers then {
                environments: $cfg.environments,
                environment: ([$cfg.environments[] | select((.development + .services) | index($s.id)) | .id][0] // null),
                root_orchestrator: null
              }
             elif $envs_schema and ($cfg.environments // [] | length) > 0 then {
                environments: $cfg.environments,
                environment: ([$cfg.environments[] | select((.development + .services) | index($s.id)) | .id][0] // null),
                root_orchestrator: ([$all_panes[] | select(.role == $cfg.harness.roles.orchestrator) | .name | select(. as $n | [$cfg.environments[].orchestrator] | index($n) | not)][0] // null)
              } else null end) as $scope
          | {
              name: $p.name,
              role: $p.role,
              secret_keys: ($cfg | secret_keys_for_role($p.role)),
              scope: $scope,
              scope_identity: ($scope | scope_identity),
              optional: ($p.optional // false),
              # "on_demand": a full start/reconcile leaves this worker pane
              # down; the orchestrator (or the user) starts and stops it with
              # `start/stop SESSION --pane NAME` (validated: active-harness
              # executor or reviewer only). "always" for every other pane.
              launch: ($p.launch // "always"),
              cwd_raw: ($p.cwd // null),
              cwd: ($cwd_map[$p.name] // null),
              # true when this pane is optional AND declares a cwd AND that
              # cwd did not resolve on disk (an un-cloned child repo). The
              # engine (lifecycle.sh) must never allocate a real tmux pane —
              # let alone launch an agent — for such a slot; it reports
              # "skipped" instead. Computed once, here, so `workspace-plan`
              # and the engine can never disagree about which panes these are.
              skip_unresolved: (($p.optional // false) and ($p.cwd // null) != null and ($cwd_map[$p.name] // null) == null),
              runtime: {
                name: $runtime_name,
                program: (if $runtime_name == "shell" then "shell" else ($runtime.program // null) end),
                args: ($runtime.args // [])
              },
              command: (if $browser != null and $s.id == $browser.session_id and $p.name == $browser_pane_name then
                [$browser.chrome_program,
                 "--remote-debugging-address=127.0.0.1",
                 "--remote-debugging-port=" + ($browser.port | tostring),
                 "--user-data-dir=" + $browser.profile_dir,
                 "--no-first-run",
                 "--no-default-browser-check"]
                else ($p.command // null) end),
              port: (if $browser != null and $s.id == $browser.session_id and $p.name == $browser_pane_name then $browser.port else ($p.port // null) end),
              browser: ($browser != null and $s.id == $browser.session_id and $p.name == $browser_pane_name),
              # Opt-in idle stop (validated: service role, and a port or the
              # browser pane). null means the pane runs until stopped.
              idle_stop_minutes: ($p.idle_stop_minutes // null),
              # What counts as use for an idle-stop dev server, in canonical
              # order (default ["connections"]). null when the pane has no
              # idle stop, and for the browser pane, whose watcher counts CDP
              # commands (validated: idle_activity is refused there).
              idle_activity: (if ($p.idle_stop_minutes // null) == null or ($browser != null and $s.id == $browser.session_id and $p.name == $browser_pane_name) then null
                              else ($p.idle_activity // ["connections"]) as $a | [("connections", "output") | select(. as $v | $a | any(. == $v))] end),
              agent: {
                model: resolve_field($p.agent.model; $role.agent.model),
                effort: resolve_field($p.agent.effort; $role.agent.effort),
                profile: resolve_field($p.agent.profile; $role.agent.profile),
                permission_mode: resolve_field($p.agent.permission_mode; $role.agent.permission_mode)
              },
              read_paths: (($ARGS.named.read_paths_map // {})[$p.name] // []),
              grants: [
                ($role.grants // [])[] | . as $g
                | if $g == "memory" then
                    {store: "memory", path: (if $mem_mode == "per-pane" then ($mem_root_abs + "/" + memory_shard($p.name; $pid; $mem_strip_prefix; $mem_strip_suffixes; $mem_fallback)) else $mem_root_abs end)}
                  else
                    {store: $g, path: store_path($store_base; $store_overrides; $g)}
                  end
              ],
              memory: {
                mode: $mem_mode,
                path: (if $mem_mode == "per-pane" then ($mem_root_abs + "/" + memory_shard($p.name; $pid; $mem_strip_prefix; $mem_strip_suffixes; $mem_fallback)) else $mem_root_abs end)
              },
              env_names: (
                (($group.values // {}) | keys)
                + $aliases
                + $engine_always
                + (if $harness_active then ["CLAUDE_CODE_DISABLE_FILE_MENTIONS"] else [] end)
                + (if $peers then ["XDG_STATE_HOME"] else [] end)
                + (if $pin_to_session then [$pin[] | coordination_var_name(.)] else [] end)
                | unique
                | sort
              )
            } + (if $p | has("worker") then {worker: $p.worker} else {} end)
        ]
      } + (if $s | has("instance") then {instance: $s.instance} else {} end)
  ],
  browsers: $browsers,
  browser: (if $browser == null then null else {
    session_id: $browser.session_id,
    pane_name: $browser_pane_name,
    port: $browser.port,
    browser_url: ("http://127.0.0.1:" + ($browser.port | tostring)),
    profile_dir: $browser.profile_dir,
    chrome_program: $browser.chrome_program,
    mcp_package: $browser.mcp_package,
    mcp_server_name: ($browser.mcp_server_name // "chrome-devtools")
  } end)
} + (if $peers then {
  peers: {session: $cfg.peers.session, limits: ($cfg.peers.limits // {})},
  workers: [
    ($cfg.sessions // [])[] | . as $s | ($s.panes // [])[] | select(has("worker"))
    | {name, role: .worker.role, checkout: .worker.checkout, owner: .worker.owner, visible: .worker.visible, running: null, session: $s.id}
  ]
} else {} end)
+ (if ($cfg.schema_version == 4 or $cfg.schema_version == 5 or $cfg.schema_version == 6) and ($cfg | has("orchestration")) then {
  orchestration: (if ($cfg.orchestration.enabled // false) then {
    active: true,
    profile: $cfg.orchestration.profile,
    gates: $cfg.harness.gates,
    targets: [
      $cfg.orchestration.targets[] | . as $target
      | (if $peers then null else [ $all_panes[] | select(.role == $cfg.harness.roles.executor and (.cwd // null) == $target.cwd) ][0] end) as $executor
      | (if $peers then null else [ $all_panes[] | select(.role == $cfg.harness.roles.reviewer and (.cwd // null) == $target.cwd) ][0] end) as $reviewer
      | {
          id: $target.id,
          environment: ([$cfg.environments[]? | select(.cwd == $target.cwd) | .id][0] // null),
          orchestrator: (if $peers then null else ([$cfg.environments[]? | select(.cwd == $target.cwd) | .orchestrator][0] // ([$all_panes[] | select(.role == $cfg.harness.roles.orchestrator) | .name][0])) end),
          cwd_raw: $target.cwd,
          cwd: (if $peers then ($env_cwd_map[([$cfg.environments[]? | select(.cwd == $target.cwd) | .id][0] // "")] // null) else ($cwd_map[$executor.name] // null) end),
          executor: $executor.name,
          reviewer: $reviewer.name,
          remote: $target.remote,
          work_branch: $target.work_branch,
          release_branch: $target.release_branch,
          deploy: {
            strategy: $target.deploy.strategy,
            align_work_after_release: ($target.deploy.align_work_after_release // false)
          }
        }
    ]
  } else {active: false} end)
} else {} end))

| if $cfg.schema_version != 5 and $cfg.schema_version != 6 then
    del(.schema_version, .environments, .browsers)
    | .sessions |= map(.panes |= map(del(.scope, .scope_identity)))
    | if (.orchestration.active // false) then .orchestration.targets |= map(del(.environment, .orchestrator)) else . end
  else . end
