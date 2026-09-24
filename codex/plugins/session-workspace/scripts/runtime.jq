# One pane-runtime resolver for validation and plan/adapter launch identity.
def pane_runtime(cfg; pane):
  if pane | has("runtime") then pane.runtime else cfg.roles[pane.role].runtime end;
