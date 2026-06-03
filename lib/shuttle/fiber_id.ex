defmodule Shuttle.FiberId do
  @moduledoc """
  The one canonical fiber-id rule, used everywhere Shuttle assigns an id.

      canonical id = realpath(fiber file) → enclosing .felt → store-relative slug

  Because `realpath` resolves every symlink, the resulting absolute path
  contains exactly one `.felt` segment — the store where the file is
  *physically* rooted. The slug below it is the id `felt ls` reports when run
  from inside that store. The same string therefore names the fiber on every
  daemon surface (`/api/v1/fibers` cards, `/api/v1/state` runtime keys,
  tmux/lifecycle keying), and is host-invariant for git-synced stores like
  loom — so cross-host dedup falls out for free, with no per-store identity.

  This is the Elixir mirror of Portolan's `canonicalStoreRelativeId`
  (`server/src/canonicalFiberRef.ts`); the two implementations must agree.

  ## Symlink topologies it resolves uniformly

    * **Loom-resident** (`loom/.felt/ai-futures/portolan/X`) → `ai-futures/portolan/X`.
      A project whose `.felt` symlinks *into* a loom subpath (portolan shape:
      `project/.felt → loom/.felt/ai-futures/portolan`) resolves to the same
      loom-relative slug, because realpath collapses the symlink onto loom.
    * **Project-resident** (shapepipe shape: `loom/.felt/shapepipe → project/.felt`)
      → the project-relative slug `X`, because realpath collapses the loom
      symlink onto the project's own `.felt`, which is the physically-enclosing
      store.

  In both cases the id is keyed against the store where the file physically
  lives; `project_dir` never participates — it is only the worker's cwd.
  """

  @typedoc "Canonical `(host, id)` for a fiber file: the directory holding the owning `.felt/`, and the store-relative slug."
  @type ref :: %{host: String.t(), id: String.t()}

  @doc """
  Canonical `(host, id)` for an on-disk fiber path.

  `host` is the directory that physically contains the owning `.felt/`; `id`
  is the store-relative slug. Returns `{:error, reason}` when the resolved path
  sits under no `.felt/` directory (`:no_felt_store`) or isn't a fiber-container
  `.md` file (`:not_markdown`, `:unexpected_layout`, `:empty_tail`).
  """
  @spec ref_from_path(String.t()) :: {:ok, ref()} | {:error, term()}
  def ref_from_path(path) do
    resolved =
      case resolve_realpath(path) do
        {:ok, real} -> real
        {:error, _} -> Path.expand(path)
      end

    segments = Path.split(resolved)

    case felt_index(segments) do
      nil ->
        {:error, :no_felt_store}

      felt_idx ->
        tail = Enum.drop(segments, felt_idx + 1)

        with {:ok, fiber_id} <- id_from_tail(tail) do
          host =
            case Enum.take(segments, felt_idx) do
              [] -> "/"
              parts -> Path.join(parts)
            end

          {:ok, %{host: host, id: fiber_id}}
        end
    end
  end

  @doc """
  Canonical store-relative id for an on-disk fiber path — the `id` of
  `ref_from_path/1` without the host. Returns `{:error, reason}` on the same
  conditions.
  """
  @spec canonical_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def canonical_id(path) do
    with {:ok, %{id: id}} <- ref_from_path(path), do: {:ok, id}
  end

  @doc """
  Realpath of a felt store root (resolves symlinks; falls back to `Path.expand/1`).
  Used to compare a candidate fiber's owning host against a configured store.
  """
  @spec canonical_host_path(String.t()) :: String.t()
  def canonical_host_path(host) do
    case resolve_realpath(host) do
      {:ok, resolved} -> resolved
      {:error, _} -> Path.expand(host)
    end
  end

  # POSIX SYMLOOP_MAX is 8; Linux allows 40. We cap symlink *hops* rather than
  # forbidding revisits, because a non-cyclic resolution legitimately re-traverses
  # a shared prefix symlink (e.g. macOS `/tmp → /private/tmp`) on more than one
  # pass — a "never revisit" guard mis-flags that as a loop. A genuine A→B→A
  # cycle still blows past the cap.
  @max_symlink_hops 40

  @doc """
  Pure-Elixir `realpath`: resolves every symlink along an expanded path,
  segment by segment, capping total symlink hops to guard against cyclic links.
  Returns the fully resolved absolute path.
  """
  @spec resolve_realpath(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_realpath(path) do
    expanded = Path.expand(path)

    case Path.split(expanded) do
      ["/" | rest] -> resolve_realpath_segments("/", rest, 0)
      [first | rest] -> resolve_realpath_segments(first, rest, 0)
      [] -> {:error, :empty_path}
    end
  end

  # The enclosing `.felt` segment. After realpath there is exactly one, so the
  # last-occurrence scan is unambiguous; it mirrors Portolan's `lastIndexOf`.
  defp felt_index(segments) do
    segments
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {".felt", idx}, _acc -> idx
      _, acc -> acc
    end)
  end

  defp id_from_tail([]), do: {:error, :empty_tail}

  defp id_from_tail([file]) do
    if String.ends_with?(file, ".md") do
      {:ok, String.replace_suffix(file, ".md", "")}
    else
      {:error, :not_markdown}
    end
  end

  defp id_from_tail(tail) do
    file = List.last(tail)
    parent = Enum.at(tail, -2)

    cond do
      not String.ends_with?(file, ".md") ->
        {:error, :not_markdown}

      String.replace_suffix(file, ".md", "") != parent ->
        {:error, :unexpected_layout}

      true ->
        {:ok, tail |> Enum.take(length(tail) - 1) |> Path.join()}
    end
  end

  defp resolve_realpath_segments(current, [], _hops), do: {:ok, current}

  defp resolve_realpath_segments(_current, _segments, hops) when hops > @max_symlink_hops,
    do: {:error, :symlink_loop}

  defp resolve_realpath_segments(current, [segment | rest], hops) do
    candidate = Path.join(current, segment)

    case :file.read_link(String.to_charlist(candidate)) do
      {:ok, target} ->
        target_path = List.to_string(target)

        expanded_target =
          case Path.type(target_path) do
            :absolute -> Path.expand(target_path)
            _ -> Path.expand(target_path, Path.dirname(candidate))
          end

        case Path.split(expanded_target) do
          ["/" | target_rest] ->
            resolve_realpath_segments("/", target_rest ++ rest, hops + 1)

          [first | target_rest] ->
            resolve_realpath_segments(first, target_rest ++ rest, hops + 1)

          [] ->
            {:error, :empty_target}
        end

      {:error, _} ->
        resolve_realpath_segments(candidate, rest, hops)
    end
  end
end
