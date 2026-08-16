# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Mix.Tasks.Simulate do
  @shortdoc "Enqueue fake-but-plausible audit.create jobs"

  @moduledoc """
  Fire one (or N) `audit.create` jobs at the Zizq server.

      mix simulate            # one event
      mix simulate 50         # fifty, in a single request

  To stream at irregular intervals:

      while true; do mix simulate; sleep $((RANDOM % 3 + 1)); done

  This is a **producer**. It starts a Zizq client of its own and
  never touches the repo, the schema or the job module — the only
  thing it shares with the audit app is the queue name and the shape
  of the payload. Ported to Ruby, Node or Rust it would look
  different and the audit app would not notice.
  """

  use Mix.Task

  @requirements ["app.config"]

  @client __MODULE__.Client

  @users ~w(alice@example.com bob@example.com chris@example.com diana@example.com)
  @admins ~w(ops@example.com admin@example.com)
  @ips ["203.0.113.7", "198.51.100.12", "192.0.2.99", "10.0.0.45", nil]

  @impl Mix.Task
  def run(args) do
    count = count!(args)

    {:ok, _} = Application.ensure_all_started(:zizq)
    {:ok, _} = Zizq.start_link(name: @client, url: url())

    # One request for the lot, rather than N — the same reason any
    # producer would batch.
    jobs = Enum.map(1..count, fn _n -> event() end)

    case Zizq.enqueue_all(jobs, @client) do
      {:ok, enqueued} ->
        Mix.shell().info("enqueued #{length(enqueued)} audit event(s) to #{queue()}")

      {:error, error} ->
        Mix.raise("could not enqueue: #{Exception.message(error)}")
    end
  end

  defp count!([]), do: 1

  defp count!([arg | _rest]) do
    case Integer.parse(arg) do
      {count, ""} when count > 0 -> count
      _ -> Mix.raise("expected a positive integer, got: #{inspect(arg)}")
    end
  end

  defp url, do: System.get_env("ZIZQ_URL") || "http://127.0.0.1:7890"

  defp queue, do: System.get_env("AUDIT_QUEUE") || AuditLog.Jobs.queue()

  defp event do
    {source, event_type, spec} = pick(catalog()).()

    [
      type: "audit.create",
      queue: queue(),
      payload: %{
        # ISO8601, which is what every Zizq example app emits and the
        # only form the audit sink accepts.
        "occurred_at" =>
          DateTime.utc_now() |> DateTime.add(-:rand.uniform(30), :second) |> DateTime.to_iso8601(),
        "source" => source,
        "event_type" => event_type,
        "actor" => spec[:actor] || pick(@users),
        "ip" => pick(@ips),
        "resource" => spec[:resource],
        "text" => spec[:text],
        "data" => spec[:data]
      }
    ]
  end

  defp catalog do
    [
      fn ->
        cents = rand(100, 50_000)
        card = 0..9999 |> Enum.random() |> Integer.to_string() |> String.pad_leading(4, "0")

        {"billing_api", "invoice.refunded",
         resource: "invoice:#{rand(1000, 9999)}",
         text: "Refunded #{money(cents)} to card ending #{card}",
         data: %{"amount_cents" => cents, "card_last4" => card}}
      end,
      fn ->
        cents = rand(500, 120_000)
        items = rand(1, 8)

        {"billing_api", "invoice.created",
         resource: "invoice:#{rand(1000, 9999)}",
         text: "Invoiced #{money(cents)} across #{items} item(s)",
         data: %{"amount_cents" => cents, "items_count" => items}}
      end,
      fn ->
        cents = rand(500, 50_000)
        reason = pick(~w(insufficient_funds card_declined expired_card processor_timeout))

        {"billing_api", "payment.failed",
         actor: "system",
         resource: "invoice:#{rand(1000, 9999)}",
         text: "Payment of #{money(cents)} failed: #{reason}",
         data: %{"amount_cents" => cents, "reason" => reason}}
      end,
      fn ->
        method = pick(~w(password sso mfa))

        {"auth_service", "user.login.success",
         resource: "user:#{rand(100, 999)}",
         text: "Signed in via #{method}",
         data: %{"method" => method}}
      end,
      fn ->
        attempts = rand(1, 5)

        {"auth_service", "user.login.failed",
         resource: "user:#{rand(100, 999)}",
         text: "Failed sign-in (#{attempts} attempt(s))",
         data: %{"attempts" => attempts}}
      end,
      fn ->
        role = pick(~w(admin billing support readonly))

        {"admin_console", "user.role.changed",
         actor: pick(@admins),
         resource: "user:#{rand(100, 999)}",
         text: "Role changed to #{role}",
         data: %{"role" => role}}
      end,
      fn ->
        {"admin_console", "feature_flag.toggled",
         actor: pick(@admins),
         resource: "flag:#{pick(~w(new_billing dark_mode beta_search))}",
         text: "Feature flag toggled",
         data: %{"enabled" => Enum.random([true, false])}}
      end,
      fn ->
        {"crm", "contact.merged",
         resource: "contact:#{rand(1000, 9999)}",
         text: "Merged duplicate contact records",
         data: %{"merged_from" => rand(1000, 9999)}}
      end
    ]
  end

  defp money(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp rand(min, max), do: min + :rand.uniform(max - min + 1) - 1

  defp pick(list), do: Enum.random(list)
end
