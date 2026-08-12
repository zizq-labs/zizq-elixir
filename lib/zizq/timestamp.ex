# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Timestamp do
  @moduledoc false
  # Conversion between `DateTime` and the Unix milliseconds the API
  # speaks.
  #
  # Every instant the server exchanges is unsigned milliseconds since
  # the epoch — `ready_at`, `dequeued_at`, `failed_at`, `completed_at`,
  # `purge_at`, `retry_at`, and the cron timestamps — while everything
  # this client hands back is a `DateTime` in UTC. Both directions live
  # here rather than beside whichever type first needed them, so a
  # change to how instants are handled is one edit, not a search.
  #
  # Outbound conversions accept milliseconds already, so a caller
  # holding a raw timestamp is not made to wrap it in a `DateTime` only
  # for it to be unwrapped again.

  @doc "A `DateTime` or milliseconds, as the milliseconds the API wants."
  @spec to_ms(DateTime.t() | integer() | nil) :: integer() | nil
  def to_ms(nil), do: nil
  def to_ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  def to_ms(ms) when is_integer(ms), do: ms

  @doc "Milliseconds from the API, as a UTC `DateTime`."
  @spec from_ms(integer() | nil) :: DateTime.t() | nil
  def from_ms(nil), do: nil
  def from_ms(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)
end
