defmodule Shuttle.LifecycleStore do
  @moduledoc """
  Daemon-owned standing-role lifecycle transitions backed by RuntimeStore.

  The synced fiber remains the document: status, outcome, address, and schedule
  stay there. Runtime lifecycle keys are written to the host-local runtime
  store and removed from the `shuttle:` frontmatter so Poller can rehydrate them
  through its lifecycle overlay.
  """

  alias Shuttle.{Cron, FeltStores, RuntimeStore, StandingRole}

  @runtime_keys ~w(review next_due_at last_run_at session)

  @spec accept(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def accept(fiber_id, opts \\ []) when is_binary(fiber_id) do
    keep_outcome? = Keyword.get(opts, :keep_outcome, false)

    with {:ok, path, frontmatter, body} <- read_fiber(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         shuttle <- merge_lifecycle_overlay(fiber_id, shuttle),
         :ok <- require_standing(shuttle),
         {:ok, review} <- require_review_state(shuttle, "awaiting"),
         {:ok, schedule} <- require_schedule(shuttle),
         {:ok, next_due_at} <- accepted_next_due_at(schedule, shuttle, review),
         {:ok, frontmatter} <- update_document(frontmatter, keep_outcome?) do
      run_id = Map.get(review, "run_id") || ""
      ad_hoc? = StandingRole.ad_hoc_run_id?(run_id)

      lifecycle = %{
        kind: "standing",
        phase: "scheduled",
        run_id: run_id,
        next_due_at: next_due_at,
        last_run_at: parse_datetime(Map.get(shuttle, "last_run_at")),
        review: %{
          "state" => "scheduled",
          "run_id" => run_id,
          "accepted_run_id" => run_id
        }
      }

      RuntimeStore.upsert_lifecycle(runtime_store_path(), fiber_id, lifecycle)
      write_fiber!(path, evict_runtime_keys(frontmatter), body)

      next_text = if next_due_at, do: DateTime.to_iso8601(next_due_at), else: "unchanged"

      if ad_hoc? do
        {:ok,
         "accepted ad-hoc run #{run_id} for #{fiber_id}\n  next due: #{next_text} (unchanged)\n"}
      else
        {:ok, "accepted run #{run_id} for #{fiber_id}\n  next due: #{next_text}\n"}
      end
    end
  end

  @spec resume(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resume(fiber_id) when is_binary(fiber_id) do
    with {:ok, path, frontmatter, body} <- read_fiber(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         shuttle <- merge_lifecycle_overlay(fiber_id, shuttle),
         :ok <- require_standing(shuttle),
         {:ok, review} <- require_any_review_state(shuttle, ["awaiting", "review", "in_review"]),
         {:ok, frontmatter} <- update_document(frontmatter, true) do
      prior_state = Map.get(review, "state")
      run_id = Map.get(review, "run_id") || ""
      now = DateTime.utc_now()

      lifecycle = %{
        kind: "standing",
        phase: "scheduled",
        run_id: empty_to_nil(run_id),
        next_due_at: now,
        last_run_at: parse_datetime(Map.get(shuttle, "last_run_at")),
        review: %{"state" => "scheduled"} |> put_if_present("run_id", run_id)
      }

      RuntimeStore.upsert_lifecycle(runtime_store_path(), fiber_id, lifecycle)
      write_fiber!(path, evict_runtime_keys(frontmatter), body)

      run_line = if run_id == "", do: "", else: "  prior run_id: #{run_id}\n"

      {:ok,
       "resumed #{fiber_id} (standing role; re-queued for immediate dispatch)\n" <>
         "  review.state: #{prior_state} -> scheduled\n" <>
         "  next_due_at:  #{DateTime.to_iso8601(now)} (immediate)\n" <>
         run_line <>
         "  note: use 'accept' to advance the recurrence instead\n"}
    end
  end

  defp read_fiber(fiber_id) do
    with {:ok, path} <- resolve_fiber_path(fiber_id),
         {:ok, text} <- File.read(path),
         {:ok, frontmatter_yaml, body} <- split_frontmatter(text),
         {:ok, frontmatter} <- YamlElixir.read_from_string(frontmatter_yaml) do
      {:ok, path, stringify_keys(frontmatter || %{}), body}
    else
      {:error, :not_found} -> {:error, "fiber not found: #{fiber_id}"}
      {:error, reason} when is_atom(reason) -> {:error, to_string(reason)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp resolve_fiber_path(fiber_id) do
    FeltStores.configured_hosts()
    |> Enum.find_value(fn host ->
      case exact_fiber_path(host, fiber_id) do
        {:ok, path} -> path
        {:error, _} -> nil
      end
    end)
    |> case do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp exact_fiber_path(host, fiber_id) do
    segments = String.split(fiber_id, "/")
    basename = List.last(segments)
    felt_dir = Path.join(host, ".felt")
    bare_path = Path.join(felt_dir, "#{basename}.md")
    dir_path = Path.join([felt_dir | segments] ++ ["#{basename}.md"])

    cond do
      not String.contains?(fiber_id, "/") and File.exists?(bare_path) -> {:ok, bare_path}
      File.exists?(dir_path) -> {:ok, dir_path}
      true -> {:error, :not_found}
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case :binary.split(rest, "\n---", []) do
      [frontmatter, body] -> {:ok, frontmatter, body}
      _ -> {:error, "missing closing frontmatter delimiter"}
    end
  end

  defp split_frontmatter(_), do: {:error, "missing opening frontmatter delimiter"}

  defp shuttle_block(%{"shuttle" => shuttle}) when is_map(shuttle), do: {:ok, shuttle}
  defp shuttle_block(_), do: {:error, "fiber has no shuttle: block"}

  defp merge_lifecycle_overlay(fiber_id, shuttle) do
    case RuntimeStore.fetch_lifecycle(runtime_store_path(), fiber_id) do
      lifecycle when is_map(lifecycle) ->
        shuttle
        |> put_if_missing("review", stringify_keys(Map.get(lifecycle, :review, %{})))
        |> put_if_missing("next_due_at", Map.get(lifecycle, :next_due_at))
        |> put_if_missing("last_run_at", Map.get(lifecycle, :last_run_at))
        |> put_if_missing("session", stringify_keys(Map.get(lifecycle, :session, %{})))

      _ ->
        shuttle
    end
  end

  defp require_standing(%{"kind" => "standing"}), do: :ok
  defp require_standing(%{"mode" => "standing"}), do: :ok

  defp require_standing(shuttle),
    do:
      {:error,
       "accept/resume store path only applies to standing roles (kind=#{inspect(Map.get(shuttle, "kind"))})"}

  defp require_review_state(shuttle, expected) do
    with {:ok, review} <- review_map(shuttle),
         ^expected <- Map.get(review, "state") do
      {:ok, review}
    else
      {:error, reason} -> {:error, reason}
      actual -> {:error, "fiber is not #{expected} review state (state=#{inspect(actual)})"}
    end
  end

  defp require_any_review_state(shuttle, expected) do
    with {:ok, review} <- review_map(shuttle),
         true <- Map.get(review, "state") in expected do
      {:ok, review}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "fiber is not in a resumable review state"}
    end
  end

  defp review_map(%{"review" => review}) when is_map(review), do: {:ok, review}
  defp review_map(_), do: {:error, "fiber has no review state"}

  defp require_schedule(%{"schedule" => schedule}) when is_map(schedule), do: {:ok, schedule}
  defp require_schedule(_), do: {:error, "fiber has no schedule"}

  defp accepted_next_due_at(_schedule, shuttle, %{"run_id" => "adhoc-" <> _}) do
    {:ok, parse_datetime(Map.get(shuttle, "next_due_at"))}
  end

  defp accepted_next_due_at(schedule, shuttle, _review) do
    now = DateTime.utc_now()
    stored = parse_datetime(Map.get(shuttle, "next_due_at"))

    # Anchor on the present. Advancing from a STALE stored next_due_at (manual
    # dispatch, late accept, daemon downtime) only moves one cron tick and can
    # stay in the past — then `due?` stays true and the role re-fires immediately
    # instead of waiting for the next real occurrence (the morning-post drift
    # bug). Use the later of stored/now so we always land on the next occurrence
    # AFTER now; missed ticks are skipped, not replayed (correct for a recurring
    # role — you want the next morning post, not a backlog of them).
    from = if stored && DateTime.compare(stored, now) == :gt, do: stored, else: now

    Cron.next_occurrence(schedule, from)
  end

  defp update_document(frontmatter, keep_outcome?) do
    frontmatter =
      frontmatter
      |> Map.put("status", "active")
      |> Map.delete("tempered")
      |> Map.delete("closed-at")
      |> enable_shuttle()

    frontmatter =
      if keep_outcome?, do: frontmatter, else: Map.put(frontmatter, "outcome", "")

    {:ok, frontmatter}
  end

  # accept/resume both re-arm the role. A paused standing role (`enabled:
  # false`) sits in Drafts with its last run's `review` preserved; accepting
  # (the human "temper") or resuming it reschedules the next run AND flips
  # `enabled` back on, so it re-enters the queue. Already-enabled roles are
  # unaffected (no-op).
  defp enable_shuttle(%{"shuttle" => shuttle} = frontmatter) when is_map(shuttle) do
    %{frontmatter | "shuttle" => Map.put(shuttle, "enabled", true)}
  end

  defp enable_shuttle(frontmatter), do: frontmatter

  defp evict_runtime_keys(%{"shuttle" => shuttle} = frontmatter) do
    %{frontmatter | "shuttle" => Map.drop(shuttle, @runtime_keys)}
  end

  defp write_fiber!(path, frontmatter, body) do
    tmp = path <> ".tmp"
    File.write!(tmp, ["---\n", yaml(frontmatter), "---\n", body, ensure_trailing_newline(body)])
    File.rename!(tmp, path)
    :ok
  end

  defp runtime_store_path do
    System.get_env("SHUTTLE_RUNTIME_STORE") || RuntimeStore.default_path()
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil
  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
  defp put_if_missing(map, _key, nil), do: map
  defp put_if_missing(map, _key, value) when value == %{}, do: map

  defp put_if_missing(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      "" -> Map.put(map, key, value)
      %{} = nested when map_size(nested) == 0 -> Map.put(map, key, value)
      _ -> map
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp stringify_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp yaml(map) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join("", fn {key, value} -> yaml_field(key, value, 0) end)
  end

  defp yaml_field(key, value, indent) when is_map(value) do
    "#{spaces(indent)}#{key}:\n" <> yaml_nested(value, indent + 2)
  end

  defp yaml_field(key, value, indent) when is_list(value) do
    "#{spaces(indent)}#{key}:\n" <>
      Enum.map_join(value, "", fn item -> "#{spaces(indent + 2)}- #{yaml_scalar(item)}\n" end)
  end

  defp yaml_field(key, value, indent), do: "#{spaces(indent)}#{key}: #{yaml_scalar(value)}\n"

  defp yaml_nested(map, indent) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join("", fn {key, value} -> yaml_field(key, value, indent) end)
  end

  defp yaml_scalar(value) when is_boolean(value), do: to_string(value)
  defp yaml_scalar(value) when is_integer(value), do: to_string(value)
  defp yaml_scalar(value) when is_float(value), do: to_string(value)
  defp yaml_scalar(nil), do: "null"

  defp yaml_scalar(value) when is_binary(value) do
    cond do
      value == "" -> ~s("")
      String.match?(value, ~r/^[A-Za-z0-9_\/.\-:@+]+$/) -> value
      true -> inspect(value)
    end
  end

  defp yaml_scalar(value), do: inspect(value)

  defp spaces(n), do: String.duplicate(" ", n)
  defp ensure_trailing_newline(""), do: ""
  defp ensure_trailing_newline(body), do: if(String.ends_with?(body, "\n"), do: "", else: "\n")
end
