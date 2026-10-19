defmodule CipaWebFiltering.MixProject do
  use Mix.Project

  def project do
    [
      app: :cipawebfiltering,
      version: "1.0.0",
      elixir: "~> 1.14",
      description: "Elixir client for the CIPA Web Filtering lookup API: web-filtering categories for 100M+ domains, batch lookups of 1,000 and policy presets for school and library filters.",
      package: package(),
      deps: deps(),
      docs: [main: "readme", extras: ["README.md"]],
      source_url: "https://github.com/explainableaixai/cipawebfiltering-elixir",
      homepage_url: "https://www.cipawebfiltering.com"
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl, :public_key]]

  defp deps do
    [{:jason, "~> 1.4"}, {:ex_doc, "~> 0.34", only: :dev, runtime: false}]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "Homepage" => "https://www.cipawebfiltering.com",
        "Domain checker" => "https://www.cipawebfiltering.com/check-domain.php",
        "GitHub" => "https://github.com/explainableaixai/cipawebfiltering-elixir"
      }
    ]
  end
end
