defmodule Zizq.Integration.MixProject do
  use Mix.Project

  # A standalone Mix project, deliberately separate from the client's.
  # Nested Mix projects are independent by construction.
  def project do
    [
      app: :zizq_integration,
      version: "0.0.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application do
    # `:inets`/`:ssl` back `:httpc`, which the smoke test uses to reach
    # the server without going through the client's own HTTP layer —
    # so a harness failure can't be mistaken for a client bug.
    [extra_applications: [:logger, :inets, :ssl]]
  end

  defp deps do
    [{:zizq, path: zizq_path()}]
  end

  # Points at the *unpacked Hex tarball*, never the source tree, so the
  # suite exercises the packaged artifact, including whatever the
  # `:files` list in the client's mix.exs actually shipped. A path
  # dependency on `../` would compile files that never make it into the
  # package, which is precisely the class of bug this harness exists to
  # catch.
  defp zizq_path do
    System.get_env("ZIZQ_PKG_PATH") ||
      Mix.raise("""
      ZIZQ_PKG_PATH is not set.

      Run this suite via integration/run.sh, which unpacks the built
      package and points this variable at it:

          ./release.sh
          ./integration/run.sh --binary /path/to/zizq \\
                               --tarball _build/release/zizq-<version>.tar
      """)
  end
end
