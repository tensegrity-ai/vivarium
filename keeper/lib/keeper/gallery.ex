defmodule Keeper.Gallery do
  @moduledoc "Syncs /vivarium/public/ from a Sprite to the gallery server after each breath."

  require Logger

  alias Keeper.Sprites

  @doc """
  Sync the terrarium's /vivarium/public/ directory to the gallery server.
  No-op if the directory doesn't exist or gallery is not configured.
  """
  def maybe_sync(name) do
    with {:ok, url} <- gallery_url(),
         {:ok, token} <- gallery_token(),
         true <- public_exists?(name) do
      sync(name, url, token)
    else
      _ -> :noop
    end
  end

  defp sync(name, url, token) do
    with {:ok, _} <- Sprites.exec(name, "tar -czf /tmp/public.tar.gz -C /vivarium/public ."),
         {:ok, tarball} <- Sprites.read_file(name, "/tmp/public.tar.gz"),
         :ok <- push(name, url, token, tarball) do
      Logger.info("[#{name}] gallery synced")
      :ok
    else
      {:error, reason} ->
        Logger.warning("[#{name}] gallery sync failed: #{inspect(reason)}")
        :error
    end
  end

  defp push(name, url, token, tarball) do
    push_url = "#{url}/api/sync/#{name}"

    case Req.post(push_url,
           body: tarball,
           headers: [
             {"authorization", "Bearer #{token}"},
             {"content-type", "application/gzip"}
           ],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{body}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp public_exists?(name) do
    case Sprites.exec(
           name,
           "test -d /vivarium/public -a -n \"$(ls -A /vivarium/public 2>/dev/null)\" && echo yes || echo no"
         ) do
      {:ok, "yes"} -> true
      _ -> false
    end
  end

  defp gallery_url do
    case Application.get_env(:keeper, :gallery_url) do
      nil -> :not_configured
      url -> {:ok, url}
    end
  end

  defp gallery_token do
    case Application.get_env(:keeper, :gallery_token) do
      nil -> :not_configured
      token -> {:ok, token}
    end
  end
end
