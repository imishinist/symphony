defmodule SymphonyElixir.Codex.RateLimits do
  @moduledoc """
  Deterministic decoding and reduction of Codex rate-limit notifications.

  Raw payloads remain available for diagnostics. The view uses atom keys and
  preserves available account metadata across sparse updates from the same source.
  Windows and credits are replaced as units; their unavailable fields are not
  filled from an older window or credit balance.
  """

  @type update :: %{required(:raw) => map(), required(:patch) => map(), optional(:source) => term()}
  @type state :: %{source: term(), view: map()}

  @snapshot_fields ~w(limit_id limitId limit_name limitName plan_type planType primary secondary credits spendControlReached)

  @spec decode(term()) :: {:ok, update()} | :ignore
  def decode(notification) do
    case payload(notification) do
      raw when is_map(raw) -> normalize(raw)
      _ -> :ignore
    end
  end

  @spec apply(state() | nil, update(), term()) :: state()
  def apply(previous, %{patch: patch}, source) do
    base = compatible_view(previous, patch, source)
    %{source: source, view: Map.merge(base, patch)}
  end

  defp payload(%{"method" => "account/rateLimits/updated", "params" => %{"rateLimits" => raw}}), do: raw

  defp payload(%{"method" => "codex/event/token_count", "params" => %{"msg" => %{"payload" => %{"rate_limits" => raw}}}}),
    do: raw

  defp payload(%{"method" => "codex/event/token_count", "params" => %{"msg" => %{"rate_limits" => raw}}}), do: raw
  defp payload(_notification), do: nil

  defp normalize(raw) do
    with :ok <- validate_metadata(raw),
         {:ok, primary} <- window(raw["primary"]),
         {:ok, secondary} <- window(raw["secondary"]),
         {:ok, credits} <- credits(raw["credits"]) do
      patch =
        %{
          limit_id: text(value(raw, "limit_id", "limitId")),
          limit_name: text(value(raw, "limit_name", "limitName")),
          plan_type: text(value(raw, "plan_type", "planType")),
          primary: primary,
          secondary: secondary,
          credits: credits
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
        |> put_spend_control(raw)

      if Enum.any?(@snapshot_fields, &Map.has_key?(raw, &1)), do: {:ok, %{raw: raw, patch: patch}}, else: :ignore
    else
      :invalid -> :ignore
    end
  end

  defp validate_metadata(raw) do
    metadata = [value(raw, "limit_id", "limitId"), value(raw, "limit_name", "limitName"), value(raw, "plan_type", "planType")]
    valid_metadata = Enum.all?(metadata, &(is_nil(&1) or is_binary(&1)))
    spend_control = raw["spendControlReached"]

    if valid_metadata and (is_nil(spend_control) or is_boolean(spend_control)), do: :ok, else: :invalid
  end

  defp window(nil), do: {:ok, nil}

  defp window(raw) when is_map(raw) do
    fields = %{
      used_percent: value(raw, "used_percent", "usedPercent"),
      remaining: raw["remaining"],
      limit: raw["limit"],
      window_minutes: value(raw, "window_minutes", "windowDurationMins"),
      reset_in_seconds: value(raw, "reset_in_seconds", "resetInSeconds"),
      resets_at: value(raw, "resets_at", "resetsAt") || value(raw, "reset_at", "resetAt")
    }

    has_usage = Enum.any?([:used_percent, :remaining, :limit], &is_number(fields[&1]))
    valid_fields = Enum.all?(fields, fn {_key, value} -> is_nil(value) or is_number(value) end)

    if has_usage and valid_fields, do: {:ok, fields}, else: :invalid
  end

  defp window(_raw), do: :invalid

  defp credits(nil), do: {:ok, nil}

  defp credits(raw) when is_map(raw) do
    fields = %{
      has_credits: value(raw, "has_credits", "hasCredits"),
      unlimited: raw["unlimited"],
      balance: raw["balance"]
    }

    valid_flags = Enum.all?([fields.has_credits, fields.unlimited], &(is_nil(&1) or is_boolean(&1)))
    has_flags = Enum.any?([fields.has_credits, fields.unlimited], &is_boolean/1)
    valid_balance = is_nil(fields.balance) or is_number(fields.balance) or is_binary(fields.balance)

    if has_flags and valid_flags and valid_balance, do: {:ok, fields}, else: :invalid
  end

  defp credits(_raw), do: :invalid

  defp put_spend_control(patch, raw) do
    case Map.fetch(raw, "spendControlReached") do
      {:ok, value} when is_boolean(value) or is_nil(value) -> Map.put(patch, :spend_control_reached, value)
      _ -> patch
    end
  end

  defp compatible_view(%{source: source, view: view}, patch, source) when not is_nil(source) do
    case {view[:limit_id], patch[:limit_id]} do
      {id, id} -> view
      {_id, nil} -> view
      _ -> %{}
    end
  end

  defp compatible_view(_previous, _patch, _source), do: %{}

  defp value(raw, snake, camel), do: Map.get(raw, camel, Map.get(raw, snake))
  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil
end
