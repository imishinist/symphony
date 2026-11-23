defmodule SymphonyElixir.Codex.RateLimitsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.RateLimits

  test "current notifications preserve raw data and normalize zero, false and unavailable values" do
    raw = %{
      "limitId" => "codex",
      "limitName" => "Codex",
      "planType" => "pro",
      "primary" => %{"usedPercent" => 0, "windowDurationMins" => 300, "resetsAt" => 0},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => "0"},
      "spendControlReached" => false
    }

    assert {:ok, %{raw: ^raw, patch: patch}} = RateLimits.decode(notification(raw))
    assert patch.limit_id == "codex"
    assert patch.limit_name == "Codex"
    assert patch.plan_type == "pro"
    assert patch.primary.used_percent == 0
    assert patch.primary.resets_at == 0
    assert patch.credits == %{has_credits: false, unlimited: false, balance: "0"}
    assert patch.spend_control_reached == false
    refute Map.has_key?(patch, :secondary)
  end

  test "known legacy token-count envelopes normalize counts and percentages" do
    raw = %{
      "limit_id" => "codex",
      "limit_name" => "Legacy",
      "plan_type" => "pro",
      "primary" => %{"remaining" => 90, "limit" => 100, "reset_in_seconds" => 30},
      "secondary" => %{"used_percent" => 12, "window_minutes" => 10_080, "resets_at" => 123},
      "credits" => %{"has_credits" => true, "balance" => 12.5}
    }

    for msg <- [%{"payload" => %{"rate_limits" => raw}}, %{"rate_limits" => raw}] do
      assert {:ok, %{raw: ^raw, patch: patch}} =
               RateLimits.decode(%{"method" => "codex/event/token_count", "params" => %{"msg" => msg}})

      assert patch.primary.remaining == 90
      assert patch.primary.limit == 100
      assert patch.primary.reset_in_seconds == 30
      assert patch.secondary.used_percent == 12
      assert patch.secondary.resets_at == 123
      assert patch.credits.balance == 12.5
    end

    for reset_key <- ["reset_at", "resetAt"] do
      {:ok, %{patch: patch}} = decode(%{"primary" => %{"limit" => 100, reset_key => 456}})
      assert patch.primary.resets_at == 456
    end
  end

  test "sparse updates retain account metadata and absent buckets, but replace an updated window as a unit" do
    {:ok, first} =
      decode(%{
        "limitId" => "codex",
        "limitName" => "Codex",
        "planType" => "pro",
        "primary" => %{"remaining" => 90, "limit" => 100},
        "secondary" => %{"usedPercent" => 20},
        "credits" => %{"unlimited" => true},
        "spendControlReached" => true
      })

    state = RateLimits.apply(nil, first, :connection)

    {:ok, update} =
      decode(%{
        "limitId" => nil,
        "limitName" => nil,
        "planType" => nil,
        "primary" => %{"usedPercent" => 0, "resetsAt" => nil},
        "secondary" => nil,
        "credits" => nil,
        "spendControlReached" => nil
      })

    view = RateLimits.apply(state, update, :connection).view

    assert view.limit_id == "codex"
    assert view.limit_name == "Codex"
    assert view.plan_type == "pro"
    assert view.primary.used_percent == 0
    assert view.primary.remaining == nil
    assert view.primary.resets_at == nil
    assert view.secondary.used_percent == 20
    assert view.credits.unlimited
    assert view.spend_control_reached == nil
  end

  test "credit updates do not carry forward an older balance or unlimited status" do
    {:ok, first} = decode(%{"credits" => %{"unlimited" => true, "balance" => 10}})
    {:ok, update} = decode(%{"credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}})
    state = RateLimits.apply(nil, first, :connection)

    assert RateLimits.apply(state, update, :connection).view.credits ==
             %{has_credits: false, unlimited: false, balance: nil}
  end

  test "an entirely unavailable sparse update still preserves its raw diagnostic payload" do
    raw = %{"limitId" => nil, "limitName" => nil, "primary" => nil, "secondary" => nil, "credits" => nil}
    assert {:ok, %{raw: ^raw, patch: %{}} = update} = decode(raw)
    assert RateLimits.apply(nil, update, :connection).view == %{}

    {:ok, first} = decode(%{"primary" => %{"usedPercent" => 12}})
    state = RateLimits.apply(nil, first, :connection)
    assert RateLimits.apply(state, update, :connection).view == state.view
  end

  test "different connections and limit IDs cannot inherit each other's sparse data" do
    {:ok, first} = decode(%{"limitId" => "codex", "secondary" => %{"usedPercent" => 90}})
    state = RateLimits.apply(nil, first, :a)
    {:ok, same_limit} = decode(%{"limitId" => "codex", "primary" => %{"usedPercent" => 5}})
    assert RateLimits.apply(state, same_limit, :a).view.secondary.used_percent == 90
    refute Map.has_key?(RateLimits.apply(state, same_limit, :b).view, :secondary)

    {:ok, other_limit} = decode(%{"limitId" => "other", "primary" => %{"usedPercent" => 5}})
    refute Map.has_key?(RateLimits.apply(state, other_limit, :a).view, :secondary)

    unknown_source = RateLimits.apply(nil, first, nil)
    refute Map.has_key?(RateLimits.apply(unknown_source, same_limit, nil).view, :secondary)
  end

  test "unrelated methods and unexpected nesting cannot supply rate-limit data" do
    for message <- [
          nil,
          "invalid",
          %{},
          %{"method" => "item/updated", "params" => %{"rateLimits" => %{"limitId" => "fake"}}},
          %{"method" => "account/rateLimits/updated", "params" => %{"rateLimits" => []}},
          %{"method" => "account/rateLimits/updated", "params" => %{"data" => %{"rateLimits" => %{"limitId" => "fake"}}}}
        ] do
      assert RateLimits.decode(message) == :ignore
    end
  end

  test "malformed windows and credits are ignored without overwriting the last valid state" do
    for raw <- [
          %{},
          %{"unknown" => true},
          %{"limitId" => 123},
          %{"primary" => "bad"},
          %{"primary" => %{}},
          %{"primary" => %{"usedPercent" => 10, "resetsAt" => %{}}},
          %{"credits" => "bad"},
          %{"credits" => %{}},
          %{"credits" => %{"unlimited" => "false"}},
          %{"credits" => %{"balance" => %{}}},
          %{"spendControlReached" => "false"}
        ] do
      assert decode(raw) == :ignore
    end
  end

  defp notification(raw), do: %{"method" => "account/rateLimits/updated", "params" => %{"rateLimits" => raw}}
  defp decode(raw), do: RateLimits.decode(notification(raw))
end
