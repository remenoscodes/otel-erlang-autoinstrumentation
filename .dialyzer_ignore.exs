# Empty: no warnings need silencing. :ecto was never a direct dependency of
# this package (still isn't — detected via Code.ensure_loaded?/1 at
# runtime), but became an indirect one once opentelemetry_oban -> oban ->
# ecto_sql -> ecto entered the dependency tree, which is enough for
# Dialyzer's closed-world PLT to see the real Ecto.Repo module and stop
# treating Ecto.Repo.all_running/0 as unknown. See mix.exs's dialyzer/0.
[]
