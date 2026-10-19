defmodule CipaWebFiltering do
  @moduledoc """
  Elixir client for the CIPA Web Filtering lookup API at https://www.cipawebfiltering.com/api/v1/ .

      client = CipaWebFiltering.new(System.fetch_env!("CWF_API_KEY"))
      {:ok, r} = CipaWebFiltering.classify(client, "example.com")
      CipaWebFiltering.Policy.blocks?(CipaWebFiltering.Policy.statutory_core(), r.categories)

  Functions return `{:ok, value}` or `{:error, %CipaWebFiltering.Error{}}`.
  """

  @version Mix.Project.config()[:version]
  @default_base "https://www.cipawebfiltering.com/api"
  @batch_max 1000

  defstruct api_key: nil, base_url: @default_base, timeout: 60_000

  @type t :: %__MODULE__{}

  defmodule Error do
    @moduledoc "Non-2xx answer (`status` > 0) or transport failure (`status` 0)."
    defexception [:status, :message, :body]
  end

  defmodule Classification do
    @moduledoc "One classified domain. `categories` has no particular order; `country` is nil when unknown."
    defstruct [:domain, :root_domain, :content_category, :country, :method, confidence: 0.0, categories: [], found: false]
  end

  @doc "Build a client. Options: `:base_url`, `:timeout` (milliseconds)."
  def new(api_key, opts \\ []) when is_binary(api_key), do: struct!(__MODULE__, Keyword.put(opts, :api_key, api_key))

  @doc "Largest batch per request."
  def batch_max, do: @batch_max

  @doc "Classify one domain or URL. One credit."
  def classify(%__MODULE__{} = c, domain) when is_binary(domain) do
    case String.trim(domain) do
      "" -> {:error, %Error{status: 0, message: "empty domain"}}
      d -> with {:ok, raw} <- request(c, :get, "/v1/classify", [url: d], nil), do: {:ok, clean(raw)}
    end
  end

  @doc "Classify any number of domains, sent in chunks of 1,000. Returns `{:ok, results, credits}`."
  def classify_many(%__MODULE__{} = c, domains) when is_list(domains) do
    domains
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.chunk_every(@batch_max)
    |> Enum.reduce_while({:ok, [], %{}}, fn chunk, {:ok, acc, cr} ->
      case request(c, :post, "/v1/classify", [], %{"urls" => chunk}) do
        {:ok, %{"results" => rs} = env} -> {:cont, {:ok, acc ++ Enum.map(rs, &clean/1), env["credits"] || cr}}
        {:ok, other} -> {:halt, {:error, %Error{status: 200, message: "unexpected body", body: other}}}
        err -> {:halt, err}
      end
    end)
  end

  @doc "Service health. Free."
  def health(%__MODULE__{} = c), do: request(c, :get, "/v1/health", [], nil)

  @doc "Database subscribers: key status and plan."
  def account_status(%__MODULE__{} = c), do: request(c, :get, "/", [action: "status"], nil)

  @doc "Database subscribers: last update time and size of the database file."
  def database_info(%__MODULE__{} = c), do: request(c, :get, "/", [action: "database_info"], nil)

  @doc "Splits the API's \"A|B|C\" field, trimming and removing duplicates."
  def split_categories(nil), do: []

  def split_categories(s) when is_binary(s) do
    s |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq_by(&String.downcase/1)
  end

  @placeholders ["", "-", "n/a", "na", "unknown", "none", "null"]

  @doc false
  def clean(raw) when is_map(raw) do
    cats = split_categories(raw["web_filtering_category"])
    method = raw["method"] || "unknown"
    country = raw["country"]

    %Classification{
      domain: raw["sni"],
      root_domain: raw["root_domain"],
      categories: cats,
      content_category: raw["category"],
      country: if(is_binary(country) and String.downcase(String.trim(country)) not in @placeholders, do: country),
      method: method,
      confidence: (raw["confidence"] || 0) * 1.0,
      found: method != "not_found" and cats != []
    }
  end

  defp request(c, method, path, query, body) do
    :inets.start()
    :ssl.start()
    qs = if query == [], do: "", else: "?" <> URI.encode_query(query)
    url = String.to_charlist(String.trim_trailing(c.base_url, "/") <> path <> qs)

    headers = [
      {~c"x-api-key", String.to_charlist(c.api_key)},
      {~c"accept", ~c"application/json"},
      {~c"user-agent", String.to_charlist("cipawebfiltering-elixir/#{@version}")}
    ]

    req = if body, do: {url, headers, ~c"application/json", Jason.encode!(body)}, else: {url, headers}
    opts = if String.starts_with?(c.base_url, "https"), do: [timeout: c.timeout, ssl: ssl_opts()], else: [timeout: c.timeout]

    case :httpc.request(method, req, opts, body_format: :binary) do
      {:ok, {{_, status, _}, _h, resp}} -> decode(status, resp)
      {:error, reason} -> {:error, %Error{status: 0, message: inspect(reason)}}
    end
  end

  defp ssl_opts do
    [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 4,
     customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]
  end

  defp decode(status, resp) do
    data = case Jason.decode(resp) do
      {:ok, d} -> d
      _ -> nil
    end

    cond do
      status in 200..299 and is_map(data) -> {:ok, data}
      is_map(data) -> {:error, %Error{status: status, message: data["detail"] || data["error"] || "HTTP #{status}", body: data}}
      true -> {:error, %Error{status: status, message: "HTTP #{status}", body: resp}}
    end
  end
end

defmodule CipaWebFiltering.Policy do
  @moduledoc """
  Turns categories into a block decision. Presets follow the five policies of the October 2026
  study of 103 million domains. `:any` blocks if any category is listed, `:majority` if more than
  half are, `:all` only if every category is.
  """
  defstruct blocked: MapSet.new(), rule: :any

  @core ["Adult"]
  @circumvention ["VPN / Proxy / Anonymizers"]
  @broad_harm ["Lingerie/Swimsuits/Intimate Apparel", "Violence", "Weapons", "Hate/Discrimination", "Illegal Drugs", "Gambling"]
  @district ["Alcohol", "Tobacco", "Dating", "File Sharing/P2P", "Remote Access Tools", "URL Shorteners", "Parked / For-Sale Domains", "Cryptocurrency", "Phishing / Suspicious"]
  @instructional ["Social Networking", "Gaming", "Streaming Media", "Forums / Message Boards", "Community Sites", "Shopping", "Marketplaces / Classifieds / Auctions", "Podcasts", "Sports & Recreation", "AI / LLM Tools", "Email and Messaging", "Blogs/Personal Sites"]

  def new(categories, rule \\ :any) when rule in [:any, :majority, :all], do: %__MODULE__{blocked: MapSet.new(categories), rule: rule}
  def statutory_core, do: new(@core)
  def with_circumvention, do: new(@core ++ @circumvention)
  def broad_harm, do: new(@core ++ @circumvention ++ @broad_harm)
  def district, do: new(@core ++ @circumvention ++ @broad_harm ++ @district)
  def restrictive, do: new(@core ++ @circumvention ++ @broad_harm ++ @district ++ @instructional)
  def with_rule(%__MODULE__{} = p, rule) when rule in [:any, :majority, :all], do: %{p | rule: rule}

  def matches(%__MODULE__{blocked: b}, cats), do: Enum.filter(cats, &MapSet.member?(b, &1))

  def blocks?(%__MODULE__{rule: rule} = p, cats) do
    hit = length(matches(p, cats))

    cond do
      hit == 0 -> false
      rule == :majority -> hit * 2 > length(cats)
      rule == :all -> hit == length(cats)
      true -> true
    end
  end
end
