defmodule Fairphone3Extras.TEE.QSEECom do
  @moduledoc """
  Talk to trusted applications in the Snapdragon 632's TrustZone (QSEE).

  Experimental, and it needs a kernel the released nerves_system_fp3
  doesn't have yet. Goes through `/dev/qseecom_raw`, a shim the
  `tee-qseecom` branch of `nerves_system_fp3` adds over the mainline
  qseecom transport (a patch that puts `fairphone,fp3` on qseecom's
  allowlist and adds `drivers/firmware/qcom/qcom_qseecom_raw.c`). One
  `write/2` carries an application name plus a request buffer; the
  kernel looks the application up, hands the request to it over an SMC
  call and stores the response, which the next read returns:

      write: <<name_len::little-32, rsp_len::little-32>> <> app_name <> request
      read:  <<status::little-signed-32, app_id::little-32, rsp::binary>>

  An empty request is a lookup only. Mainline qseecom can only talk to
  applications that are already loaded; it can't load one, and it has no
  listener support, so a command that makes the application wait on the
  non-secure side (RPMB, time) fails with `:eio`.

  The Fairphone 3 bootloader loads the `keymaster` application (Keymaster
  4) before Linux starts and leaves it resident, so it is the one to poke
  first, and the only hardware-bound key store the phone has (there's no
  secure element). Its bootloader-facing commands are public (LK's
  `km_main.h`, in `km_commands/0`); the key operations are only known by
  ID, and their request layouts need reversing from the vendor HAL.
  """

  @device "/dev/qseecom_raw"

  @keymaster "keymaster"
  @km_cmd 0x100
  @km_utils 0x200

  @doc "Keymaster command IDs, from LK's `km_main.h`."
  @km_commands %{
    get_supported_algorithms: @km_cmd + 1,
    get_supported_block_modes: @km_cmd + 2,
    get_supported_padding_modes: @km_cmd + 3,
    get_supported_digests: @km_cmd + 4,
    get_supported_import_formats: @km_cmd + 5,
    get_supported_export_formats: @km_cmd + 6,
    add_rng_entropy: @km_cmd + 7,
    generate_key: @km_cmd + 8,
    get_key_characteristics: @km_cmd + 9,
    rescope: @km_cmd + 10,
    import_key: @km_cmd + 11,
    export_key: @km_cmd + 12,
    delete_key: @km_cmd + 13,
    delete_all_keys: @km_cmd + 14,
    begin: @km_cmd + 15,
    get_output_size: @km_cmd + 16,
    update: @km_cmd + 17,
    finish: @km_cmd + 18,
    abort: @km_cmd + 19,
    get_version: @km_utils + 0,
    set_rot: @km_utils + 1,
    read_lk_device_state: @km_utils + 2,
    write_lk_device_state: @km_utils + 3,
    milestone_call: @km_utils + 4,
    secure_write_protect: @km_utils + 6,
    set_boot_state: @km_utils + 8,
    set_vbh: @km_utils + 17,
    get_date_support: @km_utils + 21
  }

  def km_commands, do: @km_commands

  @doc "Whether the kernel has the shim."
  @spec available?() :: boolean()
  def available?, do: File.exists?(@device)

  @doc """
  Look up a trusted application by name. Returns its QSEE app ID.

  `lookup("keymaster")` is the go/no-go check for the whole approach.
  """
  @spec lookup(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def lookup(app) do
    case transact(app, <<>>, 0) do
      {:ok, app_id, 0, _rsp} -> {:ok, app_id}
      {:ok, _app_id, status, _rsp} -> {:error, errno(status)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Send `request` to application `app` and read back `rsp_len` bytes.

  Returns `{:ok, app_id, response}` when the TEE reported success, or
  `{:error, reason, response}` with whatever the application wrote into
  the response buffer before failing (often nothing).
  """
  @spec send(String.t(), binary(), pos_integer()) ::
          {:ok, non_neg_integer(), binary()} | {:error, term(), binary()} | {:error, term()}
  def send(app, request, rsp_len) when is_binary(request) and rsp_len > 0 do
    case transact(app, request, rsp_len) do
      {:ok, app_id, 0, rsp} -> {:ok, app_id, rsp}
      {:ok, _app_id, status, rsp} -> {:error, errno(status), rsp}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Keymaster's version, the first command worth trying.

  Request is just the command ID. Response is a signed status followed by
  four version words (HAL major/minor, TA major/minor).
  """
  def keymaster_version do
    req = <<@km_commands.get_version::little-32>>

    case send(@keymaster, req, 64) do
      {:ok, _id,
       <<status::little-signed-32, major::little-32, minor::little-32, ta_major::little-32,
         ta_minor::little-32, _::binary>>} ->
        {:ok,
         %{status: status, major: major, minor: minor, ta_major: ta_major, ta_minor: ta_minor}}

      other ->
        other
    end
  end

  @doc """
  Send a Keymaster command by name with a raw payload after the command ID.

      QSEECom.keymaster(:get_supported_algorithms, <<0::little-32>>, 256)
  """
  def keymaster(command, payload \\ <<>>, rsp_len \\ 256) when is_atom(command) do
    id = Map.fetch!(@km_commands, command)
    send(@keymaster, <<id::little-32>> <> payload, rsp_len)
  end

  defp transact(app, request, rsp_len) do
    packet = <<byte_size(app)::little-32, rsp_len::little-32>> <> app <> request

    with {:ok, fd} <- :file.open(@device, [:raw, :binary, :read, :write]) do
      try do
        with :ok <- :file.write(fd, packet),
             {:ok, <<status::little-signed-32, app_id::little-32, rsp::binary>>} <-
               :file.read(fd, 8 + rsp_len) do
          {:ok, app_id, status, rsp}
        else
          :eof -> {:error, :no_response}
          {:error, reason} -> {:error, reason}
        end
      after
        :file.close(fd)
      end
    end
  end

  # Negative errno values from the kernel shim.
  defp errno(-2), do: :app_not_found
  defp errno(-5), do: :tee_error
  defp errno(-19), do: :scm_unavailable
  defp errno(-12), do: :enomem
  defp errno(-22), do: :einval
  defp errno(n), do: {:errno, n}
end
