# Pure names-only policy. Callers must validate the config before using it.
# A string inherits the global ceiling; an object can only narrow it.
def secret_entries:
  [(.secrets.allow // [])[] |
   if type == "string" then {key: ., roles: null} else . end];

def secret_denial(role; key):
  . as $cfg |
  ([secret_entries[] | select(.key == key)][0]) as $entry |
  if $entry == null then "not_allowed"
  elif (($cfg.roles // {}) | has(role) | not) then "unknown_role"
  elif (($cfg.secrets.visible_to_roles // []) | index(role)) == null then "global_role"
  elif $entry.roles != null and ($entry.roles | index(role)) == null then "key_role"
  else null end;

def secret_keys_for_role(role):
  . as $cfg |
  [secret_entries[].key as $key |
   select(($cfg | secret_denial(role; $key)) == null) | $key];

def secret_keys_by_role:
  . as $cfg |
  reduce (($cfg.roles // {}) | keys[]) as $role
    ({}; .[$role] = ($cfg | secret_keys_for_role($role)));

def secret_has_role_rules:
  any((.secrets.allow // [])[]; type == "object");

# Legacy doctor diagnoses all file entries. With per-key rules, diagnose only
# keys with an effective recipient. Resolution/parser semantics stay unchanged.
def secret_doctor_keys:
  if secret_has_role_rules then
    ([secret_keys_by_role[] | .[]] | unique) as $effective |
    [secret_entries[].key | select(. as $key | $effective | index($key))]
  else [secret_entries[].key] end;
