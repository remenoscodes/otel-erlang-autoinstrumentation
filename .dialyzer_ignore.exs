# See mix.exs's dialyzer/0 for the full rationale: :ecto is deliberately
# NOT a dependency of this package (detected via Code.ensure_loaded?/1 at
# runtime instead, since it's provided by whatever host release this gets
# injected into), so Dialyzer's closed-world PLT can't see Ecto.Repo and
# flags the call as unknown. Expected, not a bug.
[
  {"lib/otel_auto_bootstrap.ex", "Function Ecto.Repo.all_running/0 does not exist."}
]
