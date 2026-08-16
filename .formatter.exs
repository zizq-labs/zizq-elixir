[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    # Only the standalone scripts. The example apps under
    # `examples/*/` are separate Mix projects and format themselves.
    "examples/*.exs",
    "integration/mix.exs",
    "integration/test/**/*.{ex,exs}"
  ]
]
