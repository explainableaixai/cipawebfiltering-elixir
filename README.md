# CipaWebFiltering

An Elixir client for the CIPA Web Filtering lookup API, with a `CipaWebFiltering.Policy` module for turning a domain's categories into a block decision.

```elixir
def deps do
  [{:cipawebfiltering, "~> 1.0"}]
end
```

The library talks HTTPS through Erlang's built-in `:httpc` with certificate verification, and needs only `jason`. Generated documentation is on [hexdocs.pm](https://hexdocs.pm/cipawebfiltering); if you are setting up Elixir for the first time, start at [elixir-lang.org](https://elixir-lang.org).

## The problem this solves

Every school web filter produces the same support ticket, many times a week: "Can you unblock this site? I need it for a lesson." Somebody in IT then opens the site, guesses what it is, checks the district's policy, decides, and writes back. In a district with a few thousand staff that is a real workload, and the decisions are often inconsistent because nobody can see why a site was blocked in the first place.

Elixir is a good fit for the tool that fixes this: a small Phoenix app where staff paste a URL, see immediately which categories the site carries and which rule of the district's policy blocks it, and either get an instant answer or create a review request that IT can approve in one click. The pieces of that app that need outside data are exactly what this library provides:

1. a lookup that says what kind of site it is,
2. a policy model that explains which categories caused the block, and
3. batch lookups for the nightly job that re-checks everything on the allow list.

The rest of this README walks through those pieces and ends with a sketch of the review workflow. If you are still choosing between buying and building, the comparison of the [best web filter for schools](https://www.cipawebfiltering.com/solutions/best-web-filter-for-schools.php) lists what districts typically evaluate.

## Configuration

```elixir
client = CipaWebFiltering.new(System.fetch_env!("CWF_API_KEY"))
# options: base_url (for tests) and timeout in milliseconds (default 60_000)
client = CipaWebFiltering.new(key, timeout: 10_000)
```

The client is a plain struct, so you can build it once in `application.ex`, keep it in `:persistent_term`, or put it in your config. It holds no process and no connection pool of its own; `:httpc` manages connections.

## Looking up one site

```elixir
{:ok, r} = CipaWebFiltering.classify(client, "https://quizlet.com/some/set")

r.domain           # "quizlet.com"
r.categories       # ["Education/Reference"]   (no particular order)
r.country          # "United States", or nil when unknown
r.found            # true
r.method           # "root_domain_direct"
```

The result is a `%CipaWebFiltering.Classification{}` struct with `domain`, `root_domain`, `categories`, `content_category`, `country`, `method`, `confidence` and `found`. Country placeholders that some records carry (`"-"`, `"n/a"` and similar) are normalised to `nil`, so templates can simply write `<%= if @r.country, do: @r.country %>`.

Each call costs one credit. Errors come back as `{:error, %CipaWebFiltering.Error{status: s, message: m}}` where `status` is the HTTP status, or `0` for a transport failure.

## Many sites at once

```elixir
{:ok, results, credits} = CipaWebFiltering.classify_many(client, urls)
credits["remaining"]
```

`classify_many/2` trims and drops empty strings, splits the list into chunks of 1,000 (the endpoint's limit, also available as `CipaWebFiltering.batch_max/0`) and posts the chunks one after another. It stops at the first error and returns it, so a nightly job never silently skips a chunk.

For very large jobs, combine it with `Task.async_stream/3` at a low concurrency:

```elixir
urls
|> Enum.chunk_every(CipaWebFiltering.batch_max())
|> Task.async_stream(&CipaWebFiltering.classify_many(client, &1), max_concurrency: 2, timeout: 120_000)
|> Enum.flat_map(fn {:ok, {:ok, rs, _credits}} -> rs end)
```

Keep concurrency small. The service checks credits per request, and parallel batches make the "remaining" figure in each answer less useful.

## Policies

```elixir
alias CipaWebFiltering.Policy

policy = Policy.district()
Policy.blocks?(policy, r.categories)   # true / false
Policy.matches(policy, r.categories)   # the categories that triggered
```

A policy is a set of blocked category names and a rule: `:any` (block if any category is blocked), `:majority` (more than half), or `:all` (every category). Build your own with `Policy.new(["Adult", "Gambling"], :any)`, or start from one of five cumulative presets:

- `Policy.statutory_core/0`: Adult only. This is the category that corresponds to what the Children's Internet Protection Act names.
- `Policy.with_circumvention/0`: adds VPN / Proxy / Anonymizers.
- `Policy.broad_harm/0`: adds Lingerie/Swimsuits/Intimate Apparel, Violence, Weapons, Hate/Discrimination, Illegal Drugs and Gambling.
- `Policy.district/0`: adds Alcohol, Tobacco, Dating, File Sharing/P2P, Remote Access Tools, URL Shorteners, Parked / For-Sale Domains, Cryptocurrency and Phishing / Suspicious.
- `Policy.restrictive/0`: adds Social Networking, Gaming, Streaming Media, Forums / Message Boards, Community Sites, Shopping, Marketplaces, Podcasts, Sports & Recreation, AI / LLM Tools, Email and Messaging and Blogs/Personal Sites.

Switch the rule with `Policy.with_rule(policy, :majority)`.

### Why the rule matters in a review tool

The most common reason a teacher's site is blocked is not that it is harmful. It is that it carries a second label the policy blocks. A school's athletics page carries Sports & Recreation; a university bookstore carries Shopping; a town portal carries Community Sites. Under the `:any` rule, one of those labels is enough.

An October 2026 study ran the five presets over 103 million domains. The restrictive preset under `:any` blocked 7.6% of all domains with an education, health, government, news, science or civic label, roughly 1.24 million domains, against 0.30% for the typical district preset. Switching the restrictive preset to `:majority` cut that to about 75,000. A review tool that shows staff *which* label caused the block, and lets IT answer with "allowed under the majority rule" instead of a one-off exception, removes a large share of tickets for good.

## A review workflow sketch

Here is the core of a Phoenix context for unblock requests. Schema and LiveView code are left out; the interesting part is the decision.

```elixir
defmodule District.Review do
  alias CipaWebFiltering.Policy

  @floor Policy.with_circumvention()                         # never overridden
  @lesson Policy.with_rule(Policy.restrictive(), :majority)  # discretionary

  def check(url) do
    client = :persistent_term.get(:cwf_client)

    with {:ok, r} <- CipaWebFiltering.classify(client, url) do
      cond do
        not r.found ->
          {:review, r, "Not in the database yet. IT will look at it."}

        Policy.blocks?(@floor, r.categories) ->
          {:deny, r, "Blocked by the district's legal floor: #{Enum.join(Policy.matches(@floor, r.categories), ", ")}"}

        Policy.blocks?(@lesson, r.categories) ->
          {:review, r, "Limited during lessons because of: #{Enum.join(Policy.matches(@lesson, r.categories), ", ")}"}

        true ->
          {:allow, r, "This site is open."}
      end
    end
  end
end
```

Three outcomes cover almost every request. `:deny` explains the legal reason and ends the discussion. `:allow` tells the teacher the site is already open (often the problem was a typo or a cached block page). `:review` creates a ticket that already contains the categories and the triggering rule, so IT decides in seconds.

Run the same function in a nightly Oban job over everything on the allow list. Sites change ownership, and an allowed domain that suddenly carries Adult should come off the list automatically.

## Caching with ETS

Categories change slowly. Most review tools look up the same few hundred sites again and again (the video platform every teacher uses, the quiz site of the month), so a small cache saves credits and makes the page instant.

```elixir
defmodule District.CategoryCache do
  @table :cwf_cache
  @ttl :timer.hours(12)

  def init, do: :ets.new(@table, [:named_table, :public, read_concurrency: true])

  def classify(client, url) do
    key = url |> String.trim() |> String.downcase()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, r, at}] when now - at < @ttl ->
        {:ok, r}

      _ ->
        with {:ok, r} <- CipaWebFiltering.classify(client, url) do
          :ets.insert(@table, {key, r, now})
          {:ok, r}
        end
    end
  end
end
```

Create the table from your application's start function, so it lives as long as the node. Twelve hours is a sensible lifetime: long enough to absorb a school day of repeated lookups, short enough that a site whose categories change is re-checked the next morning. If you run several nodes, a per-node cache is fine; the cost of an occasional duplicate lookup is one credit.

## Keeping a decision log

When a parent or an auditor asks why a site was open or closed on a particular day, "the filter decided" is not an answer. Store each decision with what led to it:

```elixir
%{
  url: url,
  categories: r.categories,
  policy_version: "2026-10 board approved",
  rule: :majority,
  triggered: Policy.matches(@lesson, r.categories),
  outcome: :review,
  decided_at: DateTime.utc_now()
}
```

Because the policy is data (a set of names plus a rule), recording its version next to the categories is enough to reconstruct any decision later. That record is also what makes the yearly review of the Internet Safety Policy easy: you can show the board which categories generated requests, which were approved, and which rule changes would have avoided them.

## Account and health endpoints

```elixir
{:ok, h} = CipaWebFiltering.health(client)          # free, no key needed
h["status"]                                          # "ok"

{:ok, s} = CipaWebFiltering.account_status(client)  # key and plan (database subscribers)
{:ok, i} = CipaWebFiltering.database_info(client)   # last update time, file size
```

`health/1` is the right call for a readiness probe. It does not use credits and reports how many records the service has loaded.

## How the law and the categories fit together

People outside education IT often ask [what is a cipa filter](https://www.cipawebfiltering.com/solutions/cipa-compliant-web-filter.php), expecting a certified product. There is no such certification. CIPA requires schools and libraries that receive E-Rate discounts to use a technology protection measure against obscene images, child sexual abuse material and, for minors, material harmful to minors, a standard defined in terms of sexual content. It also requires an Internet Safety Policy. Violence, weapons, drugs and gambling are local additions, decided by a board and written into that policy and into the district's [acceptable use policy for students](https://www.cipawebfiltering.com/guides/acceptable-use-policy-schools.php).

For your application this means: hard-code nothing beyond the statutory floor. Store the district's chosen categories in the database, version them, and show the version on every decision, because that is what an auditor or a parent will ask about.

Independent and private schools that do not take E-Rate funding are not bound by CIPA at all, yet most adopt similar rules for safeguarding reasons; their typical setups are described under [internet filtering independent schools](https://www.cipawebfiltering.com/solutions/web-filtering-independent-private-schools.php). The same library and presets work for them; they simply start from a different preset.

## Testing your code

`CipaWebFiltering.clean/1` turns a raw API map into a `Classification` struct without any network call, which is handy for fixtures:

```elixir
r = CipaWebFiltering.clean(%{
  "sni" => "example.org",
  "web_filtering_category" => "Shopping|Weapons",
  "method" => "root_domain_direct",
  "confidence" => 1
})
```

For integration tests, start a Bypass or Plug server and pass `base_url: "http://localhost:#{port}"` to `new/2`. The library builds plain HTTP requests for non-HTTPS base URLs, so no certificates are needed in tests.

## Categories you will see

The taxonomy has 58 web-filtering categories. In school traffic, a few dozen dominate: Education/Reference, Search Engines & Platforms, Web-based Applications, Social Networking, Streaming Media, Gaming, Shopping, News/Media and Computers & Technology. Category names are stable strings, so they are safe to store as keys. A full list with descriptions, grouped the way most districts think about them, is on the page about [k-12 web filtering](https://www.cipawebfiltering.com/solutions/web-filtering-categories-taxonomy.php) categories. Districts comparing vendors' category models will also find the notes on [content filtering software for schools](https://www.cipawebfiltering.com/solutions/content-filtering-software-for-schools.php) useful.

## FAQ

**Does it work without Phoenix?**
Yes. It is a plain library with no OTP application of its own. Phoenix only appears in the examples.

**Why `:httpc` instead of Finch or Req?**
To keep the dependency tree at one package. If your app already uses Req, wrapping two endpoints in it is easy; the request and response formats are documented in the module docs.

**What about domains the database does not know?**
`found` is `false` and `categories` is empty. No policy blocks them. Decide explicitly what your tool does with them; in a review tool, "send to IT" is usually right.

**How many credits does a review tool use?**
Fewer than most people expect. With the ETS cache above, a district of a few thousand staff usually needs a few hundred lookups on a busy day, plus one nightly batch over the allow list. Start with the smallest plan and watch `credits["remaining"]` in the batch answers for a month.

**Can students use the tool too?**
Technically yes, but keep the `:deny` message neutral. A student-facing page should say a site is not available at school and how to ask for a review, not list the categories in detail.

**Is there a way to see the whole database?**
Database subscribers download it as a file. `database_info/1` tells you when it was last updated.

If you only need a hosted filter and not an integration, the site's [cipa web filter](https://www.cipawebfiltering.com/) runs the same data with per-school profiles and a staff unblock page.

## License

MIT, Copyright (c) 2026 Alpha Quantum.
