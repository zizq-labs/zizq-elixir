defmodule UptimeMonitor.Sitemap do
  @moduledoc """
  Extracts the URLs listed in a sitemap.

  Handles both documents the standard defines:

    * `<urlset>` — a list of pages, each `<url><loc>`.
    * `<sitemapindex>` — a list of *other sitemaps*, each
      `<sitemap><loc>`.

  Both are read the same way: every `<loc>` is a URL worth monitoring.
  For an index that means its child sitemaps become monitored URLs,
  and because probing one flags it as a sitemap in turn, a nested
  sitemap is discovered without this module knowing anything about
  nesting.

  Parsed with SAX rather than into a tree — a sitemap may hold 50,000
  entries, and only the `<loc>` text is wanted.
  """

  @behaviour Saxy.Handler

  @roots ~w(urlset sitemapindex)

  @type failure :: {:malformed, String.t()} | {:not_a_sitemap, String.t() | nil}

  @doc """
  The URLs a sitemap lists, in document order.

  Returns `{:error, {:not_a_sitemap, root}}` for well-formed XML that
  is not a sitemap, and `{:error, {:malformed, message}}` for XML that
  does not parse — a truncated download, most often.
  """
  @spec parse(binary()) :: {:ok, [String.t()]} | {:error, failure()}
  def parse(body) when is_binary(body) do
    state = %{root: nil, depth: 0, in_loc?: false, buffer: [], locs: []}

    case Saxy.parse_string(body, __MODULE__, state) do
      {:ok, %{root: root, locs: locs}} when root in @roots ->
        {:ok, Enum.reverse(locs)}

      {:ok, %{root: root}} ->
        {:error, {:not_a_sitemap, root}}

      {:error, exception} ->
        {:error, {:malformed, Exception.message(exception)}}
    end
  end

  @impl Saxy.Handler
  def handle_event(:start_element, {name, _attributes}, state) do
    name = local_name(name)

    state =
      state
      |> Map.update!(:depth, &(&1 + 1))
      |> then(fn state -> if state.root, do: state, else: %{state | root: name} end)

    if name == "loc" do
      {:ok, %{state | in_loc?: true, buffer: []}}
    else
      {:ok, state}
    end
  end

  def handle_event(:end_element, name, state) do
    state = Map.update!(state, :depth, &(&1 - 1))

    if local_name(name) == "loc" and state.in_loc? do
      {:ok, %{state | in_loc?: false, buffer: [], locs: push_loc(state)}}
    else
      {:ok, state}
    end
  end

  # Text may arrive in several chunks, so it is accumulated and joined
  # at the closing tag rather than assumed to come whole.
  def handle_event(:characters, chars, %{in_loc?: true} = state) do
    {:ok, %{state | buffer: [chars | state.buffer]}}
  end

  # Some generators wrap URLs in CDATA, which is the same text as far
  # as a sitemap is concerned.
  def handle_event(:cdata, chars, %{in_loc?: true} = state) do
    {:ok, %{state | buffer: [chars | state.buffer]}}
  end

  def handle_event(_event, _data, state), do: {:ok, state}

  defp push_loc(state) do
    case state.buffer |> Enum.reverse() |> Enum.join() |> String.trim() do
      "" -> state.locs
      loc -> [loc | state.locs]
    end
  end

  # `<sitemap:loc>` and `<loc>` are the same element; only the local
  # name identifies it.
  defp local_name(name), do: name |> String.split(":") |> List.last()
end
