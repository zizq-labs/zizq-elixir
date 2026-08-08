# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.JobTest do
  use ExUnit.Case, async: true

  alias Zizq.Job

  # Captured verbatim from a real 0.6.1 server, so the decoder is
  # tested against the shape the server actually sends rather than one
  # invented to suit it.
  @enqueue_response %{
    "id" => "03gn3lg3ska889epm2gr7s6bn",
    "type" => "probe",
    "queue" => "default",
    "priority" => 32_768,
    "status" => "ready",
    "ready_at" => 1_786_152_763_982,
    "attempts" => 0,
    "duplicate" => false,
    "folded" => false
  }

  @take_response %{
    "id" => "03gn5fa6mf64d4p80zwcxg3dw",
    "type" => "probe",
    "queue" => "default",
    "priority" => 32_768,
    "status" => "in_flight",
    "payload" => %{"n" => 1},
    "ready_at" => 1_786_172_985_237,
    "attempts" => 0,
    "dequeued_at" => 1_786_172_985_244
  }

  describe "from_wire/1" do
    test "decodes an enqueue response" do
      job = Job.from_wire(@enqueue_response)

      assert job.id == "03gn3lg3ska889epm2gr7s6bn"
      assert job.type == "probe"
      assert job.queue == "default"
      assert job.priority == 32_768
      assert job.status == :ready
      assert job.attempts == 0
      assert job.duplicate == false
      assert job.folded == false
    end

    test "decodes a take response, including the payload" do
      job = Job.from_wire(@take_response)

      assert job.status == :in_flight
      assert job.payload == %{"n" => 1}
      assert %DateTime{} = job.dequeued_at
    end

    test "leaves fields absent from the response as nil" do
      job = Job.from_wire(@enqueue_response)

      # An enqueue response carries no payload or lifecycle timestamps.
      assert job.payload == nil
      assert job.dequeued_at == nil
      assert job.completed_at == nil
      assert job.failed_at == nil
      assert job.backoff == nil
    end

    test "converts timestamps to UTC DateTimes" do
      job = Job.from_wire(@take_response)

      assert job.ready_at == DateTime.from_unix!(1_786_172_985_237, :millisecond)
      assert job.ready_at.time_zone == "Etc/UTC"
    end

    test "maps every status the server can emit" do
      for {wire, expected} <- [
            {"scheduled", :scheduled},
            {"ready", :ready},
            {"in_flight", :in_flight},
            {"completed", :completed},
            {"dead", :dead}
          ] do
        assert Job.from_wire(%{"status" => wire}).status == expected
      end
    end

    # A newer server adding a lifecycle state should not break an older
    # client that never looks at it.
    test "keeps an unknown status as a raw string rather than raising" do
      assert Job.from_wire(%{"status" => "hibernating"}).status == "hibernating"
    end

    # The server returns the batch configuration on reads because the
    # *first* enqueue's `when`/`fold` govern the whole batch — so what
    # is stored is not necessarily what any later call site passed.
    test "decodes the stored batch configuration" do
      job =
        Job.from_wire(%{
          "batch" => %{
            "key" => "digest:42",
            "when" => "$existing.count < 100",
            "fold" => "$existing | .count += 1"
          }
        })

      assert job.batch == %Zizq.BatchConfig{
               key: "digest:42",
               when: "$existing.count < 100",
               fold: "$existing | .count += 1"
             }
    end

    test "decodes nested backoff and retention" do
      job =
        Job.from_wire(%{
          "backoff" => %{"base_ms" => 15_000, "exponent" => 4.0, "jitter_ms" => 30_000},
          "retention" => %{"completed_ms" => 86_400_000}
        })

      assert job.backoff == %Zizq.Backoff{base: 15_000, exponent: 4.0, jitter: 30_000}
      assert job.retention == %Zizq.Retention{completed: 86_400_000, dead: nil}
    end
  end
end
