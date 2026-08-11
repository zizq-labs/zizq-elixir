# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.DigestJob do
  @moduledoc """
  A job whose batch accumulates at `.events`, capped at five. The key
  is derived automatically from the rest of the payload, so enqueues
  for one tenant fold together and enqueues for another do not.
  """

  use Zizq.JobKind,
    type: "batch_digest",
    batch: [limit: 5, path: ".events"]

  # Never run: these tests enqueue but never start a worker.
  @impl Zizq.JobKind
  def perform(_payload), do: :ok
end

defmodule Zizq.Integration.BatchTest do
  @moduledoc """
  Payload-derived batch keys against a real server.

  The client decides the key and the server decides what folds into
  what, so only a round trip shows the two agreeing — and that a key
  derived from part of the payload groups the jobs it should.
  """

  use ExUnit.Case, async: false

  alias Zizq.Integration.DigestJob

  # Batching is a Pro feature; `test_helper.exs` excludes this tag when
  # the server has no licence.
  @moduletag :pro

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :bt, url: url})

    %{url: url, tenant: System.unique_integer([:positive])}
  end

  defp enqueue!(ctx, events, opts \\ []) do
    tenant = Keyword.get(opts, :tenant, ctx.tenant)

    %{"tenant_id" => tenant, "events" => events}
    |> DigestJob.new(queue: "bt_#{ctx.tenant}", retention: [completed: :timer.minutes(5)])
    |> Zizq.enqueue!(:bt)
  end

  defp fetch_job!(url, id) do
    {:ok, {{_, 200, _}, _headers, body}} =
      :httpc.request(
        :get,
        {~c"#{url}/jobs/#{id}", [{~c"accept", ~c"application/json"}]},
        [],
        body_format: :binary
      )

    JSON.decode!(body)
  end

  test "a second enqueue for the same tenant folds into the first", ctx do
    first = enqueue!(ctx, [%{"a" => 1}])
    second = enqueue!(ctx, [%{"a" => 2}])

    assert second.id == first.id
    assert second.folded == true
    assert first.folded == false
  end

  # The key hashes everything but `.events`, so the events differing is
  # exactly what should not split the batch.
  test "the fold expression merges the payloads", ctx do
    first = enqueue!(ctx, [%{"a" => 1}])
    enqueue!(ctx, [%{"a" => 2}])

    stored = fetch_job!(ctx.url, first.id)

    assert stored["payload"]["events"] == [%{"a" => 1}, %{"a" => 2}]
    assert stored["payload"]["tenant_id"] == ctx.tenant
  end

  test "a different tenant gets its own batch", ctx do
    first = enqueue!(ctx, [%{"a" => 1}])
    other = enqueue!(ctx, [%{"a" => 2}], tenant: ctx.tenant + 1)

    refute other.id == first.id
    assert other.folded == false
  end

  test "the key the client derived is the key the server stored", ctx do
    job = enqueue!(ctx, [%{"a" => 1}])

    expected =
      Zizq.PayloadHasher.key(
        Zizq.PayloadHasher.new!(except: [".events"]),
        "batch_digest",
        %{"tenant_id" => ctx.tenant, "events" => [%{"a" => 1}]}
      )

    assert job.batch.key == expected
    assert String.starts_with?(job.batch.key, "batch_digest:")
  end

  # The first enqueue's expressions govern the whole batch, so reading
  # them back is how a "first wins" surprise gets diagnosed.
  test "the jq expressions come back on the job", ctx do
    job = enqueue!(ctx, [%{"a" => 1}])

    assert job.batch.when == "(($existing | .events) + ($new | .events)) | length <= 5"
    assert job.batch.fold == "$existing | .events += ($new | .events)"
  end

  # `when` is false once the batch is full, which seals it and starts a
  # fresh one rather than folding.
  test "the batch seals once the predicate stops holding", ctx do
    first = enqueue!(ctx, [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}])
    second = enqueue!(ctx, [%{"n" => 4}, %{"n" => 5}])

    assert second.id == first.id
    assert second.folded == true

    # Six events would exceed the limit of five, so this one starts a
    # new batch rather than joining.
    third = enqueue!(ctx, [%{"n" => 6}])

    refute third.id == first.id
    assert third.folded == false
  end
end
