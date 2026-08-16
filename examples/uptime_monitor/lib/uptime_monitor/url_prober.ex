defmodule UptimeMonitor.UrlProber do
  # Declared before `@moduledoc`, which interpolates it — an attribute
  # must be set before it is read.
  @max_redirects 5

  @moduledoc """
  Fetches a URL once and says whether it is up.

  A 2xx final response is **up**; anything else — a non-2xx, a
  connection that never opened, a timeout — is **down**. Never raises:
  a failure is a `CheckResult` describing it, because every outcome
  here is data to record rather than an error to propagate.

  ## Redirects

  Redirects are followed, up to #{@max_redirects} hops, and the result
  describes where the chain **ended**: `:http_status` is the final
  response's, and `:final_url` is the URL that produced it. Both are
  stored on the check, so a URL quietly redirecting somewhere else
  shows up in its history rather than looking like an ordinary
  success.

  `:final_url` is always set — for a URL that did not redirect, and
  for one that never responded at all, it is the URL as requested.

  Two redirect outcomes are failures rather than successes: exceeding
  the hop limit, which is usually a loop, and a 3xx arriving here at
  all, which means the response carried no usable `Location`.

  When the response advertises XML, the root element is inspected and
  a sitemap is flagged. Extracting the URLs is
  `UptimeMonitor.Jobs.DiscoverSitemapUrls`'s job; this only sets the
  flag.

  The flag means *worth looking at properly*, not *is a valid
  sitemap*. Parsing stops at the first start tag, so a truncated
  response is still flagged — the discovery job fetches it again and
  parses in full. Validating here as well would mean parsing every
  sitemap twice, on the path walked once per URL per sweep.
  """

  alias UptimeMonitor.Monitors.CheckResult

  @connect_timeout 5_000
  @receive_timeout 10_000

  @sitemap_roots ~w(urlset sitemapindex)
  @xml_content_type ~r{^(application|text)/(.*\+)?xml(\s*;.*)?$}i

  @doc """
  Probe `url` and describe what happened.

  Options are merged into the `Req` request, which is how tests inject
  a stub — see `config/test.exs`.
  """
  @spec probe(String.t(), keyword()) :: CheckResult.t()
  def probe(url, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    request =
      url
      |> default_options()
      |> Req.new()
      |> Req.merge(Application.get_env(:uptime_monitor, :req_options, []))
      |> Req.merge(opts)
      |> Req.Request.append_response_steps(final_url: &stash_final_url/1)

    case Req.request(request) do
      {:ok, response} -> from_response(response, url, elapsed(started))
      {:error, exception} -> from_exception(exception, url, elapsed(started))
    end
  end

  defp default_options(url) do
    [
      url: url,
      method: :get,
      redirect: true,
      max_redirects: @max_redirects,
      connect_options: [timeout: @connect_timeout],
      receive_timeout: @receive_timeout,
      # Zizq owns retrying. Req retrying underneath would make one
      # job look like a fast success after several slow failures, and
      # hide the outage from the recorded response time.
      retry: false,
      # The body is inspected as bytes, not decoded into a term.
      decode_body: false
    ]
  end

  # Appended after the redirect step, so it sees the request as it
  # finally stood rather than as it was first made.
  defp stash_final_url({request, response}) do
    {request, Req.Response.put_private(response, :final_url, URI.to_string(request.url))}
  end

  defp from_response(%Req.Response{status: status} = response, url, elapsed)
       when status in 200..299 do
    CheckResult.up(
      http_status: status,
      response_time_ms: elapsed,
      final_url: final_url(response, url),
      sitemap?: sitemap?(response)
    )
  end

  defp from_response(%Req.Response{status: status} = response, url, elapsed) do
    CheckResult.down(
      http_status: status,
      response_time_ms: elapsed,
      final_url: final_url(response, url),
      error_message: describe_status(status)
    )
  end

  defp from_exception(exception, url, elapsed) do
    CheckResult.down(
      response_time_ms: elapsed,
      final_url: url,
      error_message: describe_exception(exception)
    )
  end

  defp final_url(response, url) do
    Req.Response.get_private(response, :final_url, url)
  end

  # `redirect: true` resolves 3xx, so one arriving here means the hop
  # limit was hit or the response had no usable Location.
  defp describe_status(status) when status in 300..399,
    do: "Unfollowed redirect: HTTP #{status}"

  defp describe_status(status), do: "HTTP #{status}"

  defp describe_exception(%Req.TransportError{reason: reason}) do
    case reason do
      :timeout -> "Timed out"
      :econnrefused -> "Connection refused"
      :nxdomain -> "Host not found"
      :closed -> "Connection closed"
      other -> "Connection failed: #{inspect(other)}"
    end
  end

  defp describe_exception(%Req.TooManyRedirectsError{max_redirects: max}),
    do: "Too many redirects (more than #{max})"

  defp describe_exception(exception) when is_exception(exception),
    do: Exception.message(exception)

  defp describe_exception(other), do: inspect(other)

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  defp sitemap?(%Req.Response{} = response) do
    xml?(response) and root_element(response.body) in @sitemap_roots
  end

  defp xml?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&Regex.match?(@xml_content_type, &1))
  end

  # Only the root element is wanted, so parsing halts at the first
  # start tag rather than walking a sitemap that may hold 50,000 URLs
  # just to learn its name.
  defp root_element(body) when is_binary(body) do
    case Saxy.parse_string(body, __MODULE__.RootElement, nil) do
      {:halt, name, _rest} -> name
      _otherwise -> nil
    end
  end

  defp root_element(_body), do: nil

  defmodule RootElement do
    @moduledoc false

    @behaviour Saxy.Handler

    @impl Saxy.Handler
    def handle_event(:start_element, {name, _attributes}, _state) do
      # `<sitemap:urlset>` and `<urlset xmlns="...">` are the same
      # element; only the local name identifies it.
      {:halt, name |> String.split(":") |> List.last()}
    end

    def handle_event(_event, _data, state), do: {:ok, state}
  end
end
