# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.ErrorRecord do
  @moduledoc """
  What a worker reported when an attempt at a job failed.

  The server keeps one per failed attempt, so a job that failed three
  times has three, and `:attempt` says which is which. Read them with
  `Zizq.list_errors/3`.

  Not to be confused with `Zizq.Error`, which is what *this client*
  raises or returns when a request fails. This is a record the server
  stored about a job, while that is an exception about an API call.

  ## `:attempt` and a job's `:attempts`

  They count different things, and differ by one while a job runs.
  `Zizq.Job`'s `:attempts` counts attempts already *finished*, so it
  is `0` on the first run; this `:attempt` numbers the attempt the
  record belongs to, so the first failure is `1`.

      run  handler sees      on failure, records   job ends up with
      1    attempts: 0   ->  attempt: 1        ->  attempts: 1
      2    attempts: 1   ->  attempt: 2        ->  attempts: 2

  So they align once an attempt is over, and a guard like
  `when attempts >= 3` first matches on the fourth run — by which
  point three records exist, numbered 1 to 3.

  ## Fields

    * `:attempt` — which attempt failed, counting from 1. The server
      counts the attempt as finished before writing the record, so
      this is one more than the `:attempts` the handler saw while it
      ran — see below.
    * `:message` — what the worker said went wrong.
    * `:error_type` — the exception or error class, when the worker
      reported one, e.g. `"Mint.TransportError"`.
    * `:backtrace` — a formatted stacktrace, when the worker reported
      one.
    * `:dequeued_at` — when the attempt started.
    * `:failed_at` — when it failed.
  """

  @type t :: %__MODULE__{
          attempt: pos_integer(),
          message: String.t(),
          error_type: String.t() | nil,
          backtrace: String.t() | nil,
          dequeued_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil
        }

  defstruct [:attempt, :message, :error_type, :backtrace, :dequeued_at, :failed_at]

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(wire) do
    %__MODULE__{
      attempt: wire["attempt"],
      message: wire["message"],
      error_type: wire["error_type"],
      backtrace: wire["backtrace"],
      dequeued_at: Zizq.Timestamp.from_ms(wire["dequeued_at"]),
      failed_at: Zizq.Timestamp.from_ms(wire["failed_at"])
    }
  end

  @doc """
  How long the attempt ran before it failed, in milliseconds.

  `nil` if either timestamp is missing.
  """
  @spec duration(t()) :: non_neg_integer() | nil
  def duration(%__MODULE__{dequeued_at: nil}), do: nil
  def duration(%__MODULE__{failed_at: nil}), do: nil

  def duration(%__MODULE__{dequeued_at: started, failed_at: failed}),
    do: DateTime.diff(failed, started, :millisecond)
end
