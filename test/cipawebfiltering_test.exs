defmodule CipaWebFilteringTest do
  use ExUnit.Case
  alias CipaWebFiltering.Policy

  test "cleans an API record" do
    r = CipaWebFiltering.clean(%{"sni" => "khanacademy.org", "web_filtering_category" => "Education/Reference| education/reference", "country" => "-", "method" => "root_domain_direct", "confidence" => 1})
    assert r.categories == ["Education/Reference"]
    assert r.found
    assert r.country == nil
  end

  test "not found record" do
    r = CipaWebFiltering.clean(%{"sni" => "zz.example", "web_filtering_category" => nil, "method" => "not_found"})
    refute r.found
  end

  test "rules" do
    cats = ["Adult", "Dating"]
    assert Policy.blocks?(Policy.statutory_core(), cats)
    refute Policy.blocks?(Policy.with_rule(Policy.statutory_core(), :majority), cats)
    assert Policy.blocks?(Policy.with_rule(Policy.district(), :all), cats)
    refute Policy.blocks?(Policy.restrictive(), ["Education/Reference"])
  end

  test "live health endpoint" do
    case CipaWebFiltering.health(CipaWebFiltering.new("none")) do
      {:ok, h} -> assert h["status"] == "ok"
      {:error, %{status: 0}} -> :ok
    end
  end
end
