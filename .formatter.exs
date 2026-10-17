[
  import_deps: [
    :ash,
    :ash_authentication,
    :ash_authentication_phoenix,
    :ash_postgres,
    :ecto,
    :ecto_sql,
    :phoenix,
    :plug
  ],
  plugins: [Spark.Formatter],
  inputs: [
    "mix.exs",
    "config/*.exs",
    "apps/*/mix.exs",
    "apps/*/config/*.exs",
    "apps/*/lib/**/*.{ex,exs}",
    "apps/*/test/**/*.{ex,exs}",
    "apps/*/priv/repo/migrations/*.exs"
  ]
]
