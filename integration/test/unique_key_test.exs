# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.UniqueJob do
  @moduledoc """
  A job whose identity is decided by two payload fields.

  Declared at the top level because `use Zizq.JobKind` runs while the
  module compiles, which is also where its paths are parsed.
  """

  use Zizq.JobKind,
    type: "unique_probe",
    unique_key: {:payload, only: [".user_id", ".template"]},
    unique_while: :queued

  # Never run: these tests enqueue but never start a worker. It is here
  # because `use Zizq.JobKind` requires one, the module being the way to
  # declare a job that is *run* somewhere.
  @impl Zizq.JobKind
  def perform(_payload), do: :ok
end

defmodule Zizq.Integration.UniqueKeyTest do
  @moduledoc """
  Payload-derived unique keys against a real server.

  The digest is computed on the client but enforced on the server,
  so only a round trip shows that the two agree: the key reaches the
  server intact, and that two enqueues the client considers
  identical are one job.
  """

  use ExUnit.Case, async: false

  alias Zizq.Integration.UniqueJob

  # Uniqueness is a Pro feature; the server answers 403 without a
  # licence. `test_helper.exs` probes for one and excludes this tag when
  # there is none.
  @moduletag :pro

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :uk, url: url})

    # Unique per run: the key is derived from the payload alone, so a
    # fixed id would collide with jobs left by an earlier run.
    %{
      queue: "uk_#{System.unique_integer([:positive])}",
      user_id: System.unique_integer([:positive])
    }
  end

  defp enqueue!(ctx, payload) do
    payload
    |> Map.put("user_id", ctx.user_id)
    |> UniqueJob.new(queue: ctx.queue, retention: [completed: :timer.minutes(5)])
    |> Zizq.enqueue!(:uk)
  end

  test "a second enqueue with the same hashed fields is the same job", ctx do
    first = enqueue!(ctx, %{"template" => "welcome"})
    second = enqueue!(ctx, %{"template" => "welcome"})

    assert second.id == first.id
    assert second.duplicate == true
    assert first.duplicate == false
  end

  # The whole point of `:only`: fields outside it are free to differ.
  test "fields outside the hashed paths do not create a new job", ctx do
    first = enqueue!(ctx, %{"template" => "welcome", "requested_at" => "2026-01-01T00:00:00Z"})
    second = enqueue!(ctx, %{"template" => "welcome", "requested_at" => "2026-06-30T12:00:00Z"})

    assert second.id == first.id
    assert second.duplicate == true
  end

  test "a different value in a hashed field is a different job", ctx do
    first = enqueue!(ctx, %{"template" => "welcome"})
    second = enqueue!(ctx, %{"template" => "reminder"})

    refute second.id == first.id
    assert second.duplicate == false
  end

  test "the key the client derived is the key the server stored", ctx do
    job = enqueue!(ctx, %{"template" => "welcome"})

    expected =
      Zizq.PayloadHasher.key(
        Zizq.PayloadHasher.new!(only: [".user_id", ".template"]),
        "unique_probe",
        %{"user_id" => ctx.user_id, "template" => "welcome"}
      )

    assert job.unique_key == expected
    assert String.starts_with?(job.unique_key, "unique_probe:")
  end

  test "a plain string key still works alongside the derived kind", ctx do
    key = "manual_#{System.unique_integer([:positive])}"
    enqueue = [type: "unique_manual", queue: ctx.queue, payload: %{}, unique_key: key]

    first = Zizq.enqueue!(enqueue, :uk)
    second = Zizq.enqueue!(enqueue, :uk)

    assert second.id == first.id
    assert second.duplicate == true
    assert first.unique_key == key
  end
end
