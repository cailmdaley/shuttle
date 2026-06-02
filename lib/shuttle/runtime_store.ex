defmodule Shuttle.RuntimeStore do
  @moduledoc """
  Host-local durable runtime state for the Shuttle daemon.

  This is intentionally narrower than the eventual lifecycle store: it persists
  daemon-owned runtime that must survive restarts while the fiber remains the
  source of document truth.
  """

  require Logger

  @schema_version 1
  @default_path "~/.shuttle/runtime.db"

  @type path :: String.t()

  @spec default_path() :: path()
  def default_path, do: Path.expand(@default_path)

  @spec init(path()) :: :ok
  def init(path) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))

    sql = """
    PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS running_workers (
      fiber_id TEXT PRIMARY KEY,
      tmux_session TEXT NOT NULL,
      agent_id TEXT,
      state TEXT NOT NULL DEFAULT 'running',
      run_id TEXT,
      run_kind TEXT,
      started_at TEXT NOT NULL,
      last_activity_at TEXT NOT NULL,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS retry_queue (
      fiber_id TEXT PRIMARY KEY,
      attempt INTEGER NOT NULL,
      due_at_ms INTEGER NOT NULL,
      delay_type TEXT NOT NULL DEFAULT 'failure',
      error TEXT,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      updated_at TEXT NOT NULL
    );
    INSERT OR IGNORE INTO schema_migrations(version, applied_at)
    VALUES (#{@schema_version}, #{sql_string(DateTime.utc_now() |> DateTime.to_iso8601())});
    """

    exec!(path, sql)
  end

  @spec list_running(path()) :: [%{fiber_id: String.t(), metadata: map()}]
  def list_running(path) when is_binary(path) do
    init(path)

    sql = """
    SELECT fiber_id, metadata_json
    FROM running_workers
    ORDER BY started_at, fiber_id;
    """

    path
    |> query_lines(sql)
    |> Enum.map(fn line ->
      [fiber_id, metadata_json] = String.split(line, "\t", parts: 2)
      %{"metadata" => metadata} = Jason.decode!(metadata_json)
      %{fiber_id: fiber_id, metadata: decode_metadata(metadata)}
    end)
  end

  @spec upsert_running(path(), String.t(), map()) :: :ok
  def upsert_running(path, fiber_id, metadata) when is_binary(path) and is_binary(fiber_id) do
    init(path)

    session = Map.fetch!(metadata, :session)
    agent_id = Map.get(metadata, :agent_id)
    state = Map.get(metadata, :state, "running")
    run_id = Map.get(metadata, :run_id)
    run_kind = Map.get(metadata, :run_kind)
    started_at = metadata |> Map.fetch!(:started_at) |> encode_datetime()
    last_activity_at = metadata |> Map.fetch!(:last_activity_at) |> encode_datetime()
    updated_at = DateTime.utc_now() |> DateTime.to_iso8601()

    metadata_json =
      %{metadata: encode_metadata(metadata)}
      |> Jason.encode!()

    sql = """
    INSERT INTO running_workers (
      fiber_id, tmux_session, agent_id, state, run_id, run_kind,
      started_at, last_activity_at, metadata_json, updated_at
    ) VALUES (
      #{sql_string(fiber_id)}, #{sql_string(session)}, #{sql_string(agent_id)},
      #{sql_string(state)}, #{sql_string(run_id)}, #{sql_string(run_kind)},
      #{sql_string(started_at)}, #{sql_string(last_activity_at)},
      #{sql_string(metadata_json)}, #{sql_string(updated_at)}
    )
    ON CONFLICT(fiber_id) DO UPDATE SET
      tmux_session = excluded.tmux_session,
      agent_id = excluded.agent_id,
      state = excluded.state,
      run_id = excluded.run_id,
      run_kind = excluded.run_kind,
      started_at = excluded.started_at,
      last_activity_at = excluded.last_activity_at,
      metadata_json = excluded.metadata_json,
      updated_at = excluded.updated_at;
    """

    exec!(path, sql)
  end

  @spec delete_running(path(), String.t()) :: :ok
  def delete_running(path, fiber_id) when is_binary(path) and is_binary(fiber_id) do
    init(path)
    exec!(path, "DELETE FROM running_workers WHERE fiber_id = #{sql_string(fiber_id)};")
  end

  @spec list_retries(path()) :: [%{fiber_id: String.t(), metadata: map()}]
  def list_retries(path) when is_binary(path) do
    init(path)

    sql = """
    SELECT fiber_id, metadata_json
    FROM retry_queue
    ORDER BY due_at_ms, fiber_id;
    """

    path
    |> query_lines(sql)
    |> Enum.map(fn line ->
      [fiber_id, metadata_json] = String.split(line, "\t", parts: 2)
      %{"metadata" => metadata} = Jason.decode!(metadata_json)
      %{fiber_id: fiber_id, metadata: decode_metadata(metadata)}
    end)
  end

  @spec upsert_retry(path(), String.t(), map()) :: :ok
  def upsert_retry(path, fiber_id, metadata) when is_binary(path) and is_binary(fiber_id) do
    init(path)

    attempt = Map.fetch!(metadata, :attempt)
    due_at_ms = Map.fetch!(metadata, :due_at_ms)
    delay_type = metadata |> Map.get(:delay_type, :failure) |> to_string()
    error = Map.get(metadata, :error)
    updated_at = DateTime.utc_now() |> DateTime.to_iso8601()

    metadata_json =
      %{metadata: encode_metadata(metadata)}
      |> Jason.encode!()

    sql = """
    INSERT INTO retry_queue (
      fiber_id, attempt, due_at_ms, delay_type, error, metadata_json, updated_at
    ) VALUES (
      #{sql_string(fiber_id)}, #{attempt}, #{due_at_ms},
      #{sql_string(delay_type)}, #{sql_string(error)}, #{sql_string(metadata_json)},
      #{sql_string(updated_at)}
    )
    ON CONFLICT(fiber_id) DO UPDATE SET
      attempt = excluded.attempt,
      due_at_ms = excluded.due_at_ms,
      delay_type = excluded.delay_type,
      error = excluded.error,
      metadata_json = excluded.metadata_json,
      updated_at = excluded.updated_at;
    """

    exec!(path, sql)
  end

  @spec delete_retry(path(), String.t()) :: :ok
  def delete_retry(path, fiber_id) when is_binary(path) and is_binary(fiber_id) do
    init(path)
    exec!(path, "DELETE FROM retry_queue WHERE fiber_id = #{sql_string(fiber_id)};")
  end

  defp exec!(path, sql) do
    case System.cmd("sqlite3", sqlite_args(path, sql), stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        raise "sqlite3 exited #{code} for #{path}: #{String.trim(output)}"
    end
  end

  defp query_lines(path, sql) do
    args = ["-batch", "-cmd", ".timeout 5000", "-separator", "\t", path, sql]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)

      {output, code} ->
        raise "sqlite3 query exited #{code} for #{path}: #{String.trim(output)}"
    end
  end

  defp sqlite_args(path, sql) do
    ["-batch", "-cmd", ".timeout 5000", path, sql]
  end

  defp sql_string(nil), do: "NULL"

  defp sql_string(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp encode_metadata(metadata) do
    metadata
    |> Map.drop([:pid])
    |> Map.new(fn
      {key, %DateTime{} = value} -> {to_string(key), DateTime.to_iso8601(value)}
      {key, value} when is_atom(value) -> {to_string(key), to_string(value)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp decode_metadata(metadata) do
    metadata
    |> Map.new(fn
      {"started_at", value} -> {:started_at, decode_datetime(value)}
      {"last_activity_at", value} -> {:last_activity_at, decode_datetime(value)}
      {"delay_type", value} when is_binary(value) -> {:delay_type, String.to_atom(value)}
      {key, value} -> {String.to_atom(key), value}
    end)
  end

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(value) when is_binary(value), do: value

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} ->
        datetime

      {:error, reason} ->
        Logger.warning(
          "RuntimeStore could not parse datetime #{inspect(value)}: #{inspect(reason)}"
        )

        DateTime.utc_now()
    end
  end
end
