# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# Some endpoints need a Pro licence, and the server answers 403 without
# one. ExUnit has no runtime skip, so the equivalent is to ask the
# server once, up front, and exclude the `:pro` tag when the answer is
# no.
#
# Probed rather than inferred from whether `run.sh` was given
# `--license-key`, so the suite reflects what the server under test
# will actually do (e.g. expired license).
defmodule Zizq.Integration.License do
  @moduledoc false

  def pro?(url) do
    name = :"license_probe_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Zizq.start_link(name: name, url: url)

    try do
      probe(name)
    after
      Supervisor.stop(name)
    end
  end

  # `unique_key` is Pro-gated, so a 403 here is the licence answer.
  # Anything else means the feature is available.
  defp probe(name) do
    enqueue = [
      type: "license_probe",
      queue: "license_probe",
      payload: %{},
      unique_key: "probe_#{System.unique_integer([:positive])}"
    ]

    case Zizq.enqueue(enqueue, name) do
      {:error, %Zizq.Error{reason: :forbidden}} -> false
      {:ok, _job} -> true
      {:error, _other} -> true
    end
  end
end

url = System.fetch_env!("ZIZQ_URL")

exclude =
  if Zizq.Integration.License.pro?(url) do
    []
  else
    IO.puts("    (no Pro licence on the server — excluding Pro-gated tests)")
    [:pro]
  end

ExUnit.start(exclude: exclude)
