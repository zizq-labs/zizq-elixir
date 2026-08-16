defmodule UptimeMonitor.Monitors do
  @moduledoc """
  Monitored URLs and the checks recorded against them.

  Every job handler and the web layer go through here, so neither
  builds a query of its own.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias UptimeMonitor.Monitors.Check
  alias UptimeMonitor.Monitors.CheckResult
  alias UptimeMonitor.Monitors.MonitoredUrl
  alias UptimeMonitor.Repo

  @topic "monitors"

  @doc """
  Subscribe to changes, so a live view updates as the worker writes.

  This is what makes the page live without polling: a probe recorded
  in a worker's task is broadcast here and rendered in whatever
  browsers happen to be watching.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(UptimeMonitor.PubSub, @topic)

  # Broadcast from the context rather than from the job handlers, so
  # anything that changes a monitored URL announces it — including a
  # path added later that forgets to.
  defp broadcast(message) do
    Phoenix.PubSub.broadcast(UptimeMonitor.PubSub, @topic, message)
  end

  defp broadcast({:ok, _value} = result, message) do
    broadcast(message)
    result
  end

  defp broadcast(other, _message), do: other

  @doc """
  Every monitored URL, most recently checked last so a never-checked
  URL sorts to the top and is visibly waiting.
  """
  @spec list_urls() :: [MonitoredUrl.t()]
  def list_urls do
    MonitoredUrl
    |> order_by([u], asc_nulls_first: u.last_checked_at, asc: u.id)
    |> Repo.all()
  end

  @doc """
  Fetch one monitored URL, or `nil`.
  """
  @spec get_url(integer()) :: MonitoredUrl.t() | nil
  def get_url(id), do: Repo.get(MonitoredUrl, id)

  @doc """
  Find a URL within the scope that produced it.

  A URL listed by two different sitemaps is two rows, and neither is
  the manual one someone may also have submitted — so the sitemap is
  part of the identity, not just provenance.
  """
  @spec find_url(String.t(), String.t() | nil) :: MonitoredUrl.t() | nil
  def find_url(url, source_sitemap_url \\ nil) do
    MonitoredUrl
    |> where([u], u.url == ^url)
    |> scope_to_sitemap(source_sitemap_url)
    |> Repo.one()
  end

  # `Repo.get_by/2` cannot express this: Ecto refuses `field == nil`,
  # since in SQL that is never true. A manual URL is exactly the one
  # with no sitemap, so the nil case has to be `is_nil/1`.
  defp scope_to_sitemap(query, nil), do: where(query, [u], is_nil(u.source_sitemap_url))
  defp scope_to_sitemap(query, sitemap), do: where(query, [u], u.source_sitemap_url == ^sitemap)

  @doc """
  Start monitoring a URL.
  """
  @spec create_url(map()) :: {:ok, MonitoredUrl.t()} | {:error, Ecto.Changeset.t()}
  def create_url(attrs) do
    %MonitoredUrl{}
    |> MonitoredUrl.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:urls_changed)
  end

  @doc """
  A changeset for the "add a URL" form.
  """
  @spec change_url(MonitoredUrl.t(), map()) :: Ecto.Changeset.t()
  def change_url(%MonitoredUrl{} = url \\ %MonitoredUrl{}, attrs \\ %{}) do
    MonitoredUrl.changeset(url, attrs)
  end

  @doc """
  Stop monitoring a URL, discarding its checks.
  """
  @spec delete_url(MonitoredUrl.t()) :: {:ok, MonitoredUrl.t()} | {:error, Ecto.Changeset.t()}
  def delete_url(%MonitoredUrl{} = url) do
    url |> Repo.delete() |> broadcast(:urls_changed)
  end

  @doc """
  Record a probe's result and roll it up onto the URL.

  Both happen in one transaction: a check row that exists while the
  URL still claims its previous status would be read by the feed as a
  URL that has not been checked.
  """
  @spec record_check(MonitoredUrl.t(), CheckResult.t()) ::
          {:ok, Check.t()} | {:error, Ecto.Changeset.t()}
  def record_check(%MonitoredUrl{} = url, %CheckResult{} = result) do
    check_attrs = %{
      monitored_url_id: url.id,
      checked_at: result.checked_at,
      status: result.status,
      http_status: result.http_status,
      response_time_ms: result.response_time_ms,
      final_url: result.final_url,
      error_message: result.error_message
    }

    url_attrs = %{
      last_status: result.status,
      last_checked_at: result.checked_at,
      consecutive_failures: next_failure_count(url, result)
    }

    Multi.new()
    |> Multi.insert(:check, Check.changeset(%Check{}, check_attrs))
    |> Multi.update(:url, MonitoredUrl.changeset(url, url_attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{check: check}} -> broadcast({:ok, check}, :urls_changed)
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  A URL's checks, most recent first.
  """
  @spec recent_checks(MonitoredUrl.t(), keyword()) :: [Check.t()]
  def recent_checks(%MonitoredUrl{} = url, opts \\ []) do
    Check
    |> where([c], c.monitored_url_id == ^url.id)
    |> order_by([c], desc: c.checked_at, desc: c.id)
    |> limit(^Keyword.get(opts, :limit, 20))
    |> Repo.all()
  end

  @doc """
  Fetch one check, or `nil`.
  """
  @spec get_check(integer()) :: Check.t() | nil
  def get_check(id), do: Repo.get(Check, id)

  @doc """
  The ids of enabled URLs whose last check is older than `stale_after`
  milliseconds, or that have never been checked.

  Ids rather than rows: the caller enqueues a job per id, and loading
  whole rows to read one field of each would be wasteful when this is
  swept on a timer.
  """
  @spec stale_url_ids(non_neg_integer()) :: [integer()]
  def stale_url_ids(stale_after) do
    cutoff = DateTime.add(DateTime.utc_now(), -stale_after, :millisecond)

    MonitoredUrl
    |> where([u], u.enabled)
    |> where([u], is_nil(u.last_checked_at) or u.last_checked_at < ^cutoff)
    |> select([u], u.id)
    |> Repo.all()
  end

  @doc """
  The ids of the enabled URLs a given sitemap produced.
  """
  @spec sitemap_child_ids(String.t()) :: [integer()]
  def sitemap_child_ids(sitemap_url) do
    MonitoredUrl
    |> where([u], u.enabled and u.source_sitemap_url == ^sitemap_url)
    |> select([u], u.id)
    |> Repo.all()
  end

  @doc """
  Bring a sitemap's children into line with what it now lists.

  URLs it no longer lists are **disabled rather than deleted**, so the
  checks recorded against them survive — a page that disappears from a
  sitemap is exactly when its history is worth keeping. One that
  reappears is re-enabled.

  Returns `{created, enabled, disabled}`.
  """
  @spec reconcile_sitemap_children(String.t(), [String.t()]) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def reconcile_sitemap_children(sitemap_url, discovered) do
    discovered = discovered |> Enum.map(&String.trim/1) |> Enum.uniq()

    created = create_missing_children(sitemap_url, discovered)

    enabled =
      set_children_enabled(sitemap_url, true, fn query ->
        where(query, [u], u.url in ^discovered and not u.enabled)
      end)

    disabled =
      set_children_enabled(sitemap_url, false, fn query ->
        where(query, [u], u.url not in ^discovered and u.enabled)
      end)

    if created + enabled + disabled > 0, do: broadcast(:urls_changed)

    {created, enabled, disabled}
  end

  defp create_missing_children(sitemap_url, discovered) do
    existing =
      MonitoredUrl
      |> where([u], u.source_sitemap_url == ^sitemap_url)
      |> select([u], u.url)
      |> Repo.all()
      |> MapSet.new()

    discovered
    |> Enum.reject(&MapSet.member?(existing, &1))
    |> Enum.count(fn url ->
      # Checked-then-created rather than an upsert so the URL
      # validation runs. Another worker may have won the race in
      # between, which is a duplicate, not a failure.
      case create_url(%{
             url: url,
             source: "sitemap",
             source_sitemap_url: sitemap_url
           }) do
        {:ok, _url} -> true
        {:error, _changeset} -> false
      end
    end)
  end

  defp set_children_enabled(sitemap_url, enabled, narrow) do
    {count, _returning} =
      MonitoredUrl
      |> where([u], u.source_sitemap_url == ^sitemap_url)
      |> narrow.()
      |> Repo.update_all(set: [enabled: enabled, updated_at: DateTime.utc_now()])

    count
  end

  # A success clears the count rather than decrementing it, so it
  # reads as "how long has this been down", not "how flaky is it".
  defp next_failure_count(_url, %CheckResult{status: "up"}), do: 0
  defp next_failure_count(url, _result), do: url.consecutive_failures + 1
end
