# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.TLS do
  @moduledoc false
  # Translates the client's `:tls` option into Erlang `:ssl` options.
  #
  # Each value may be a **PEM string** or a **path to a PEM file**,
  # matching the Ruby client, so the same certificate material can be
  # configured the same way from either. They are told apart by looking
  # for a PEM header, which is what Ruby does too.
  #
  # A path becomes `cacertfile`/`certfile`/`keyfile`, letting `:ssl`
  # read it; a PEM string is decoded here into `cacerts`/`cert`/`key`.

  @pem_header "-----BEGIN "

  @doc """
  Build `:ssl` options from a validated `:tls` keyword list.

  Returns `[]` when nothing is configured, so callers can append
  unconditionally.
  """
  @spec to_ssl_options(keyword()) :: keyword()
  def to_ssl_options(tls) when is_list(tls) do
    []
    |> put_ca(tls[:ca])
    |> put_client_cert(tls[:client_cert])
    |> put_client_key(tls[:client_key])
  end

  @doc """
  Check a `:tls` list, raising `ArgumentError` with a message naming
  what is wrong.

  Called while the client starts, so a mistake fails at boot rather
  than as a handshake error on the first request — by which point the
  cause is several layers away from the configuration that caused it.
  """
  @spec validate!(keyword(), URI.t()) :: keyword()
  def validate!([], _uri), do: []

  def validate!(_tls, %URI{scheme: scheme}) when scheme != "https" do
    raise ArgumentError, """
    :tls was given but the URL is #{inspect(scheme)}://, not https://.

    TLS options are only meaningful over HTTPS. Either point :url at an
    https:// URL, or drop the :tls option.
    """
  end

  def validate!(tls, _uri) do
    # A certificate without its key presents nothing, and a key without
    # its certificate has nothing to present. Either alone is silently
    # useless — the handshake simply proceeds without a client
    # identity, and the server rejects it for reasons that look
    # unrelated.
    case {tls[:client_cert], tls[:client_key]} do
      {nil, nil} ->
        :ok

      {cert, key} when is_binary(cert) and is_binary(key) ->
        :ok

      {nil, _key} ->
        raise ArgumentError,
              "tls :client_key was given without :client_cert — mutual TLS needs both"

      {_cert, nil} ->
        raise ArgumentError,
              "tls :client_cert was given without :client_key — mutual TLS needs both"
    end

    Enum.each([:ca, :client_cert, :client_key], &check_readable!(tls, &1))

    tls
  end

  defp check_readable!(tls, key) do
    case tls[key] do
      nil ->
        :ok

      value ->
        if pem?(value) do
          decode_pem!(value, key)
          :ok
        else
          unless File.regular?(value) do
            raise ArgumentError, """
            tls :#{key} is neither a PEM string nor a readable file: #{inspect(value)}

            Give the PEM contents directly, or a path to a file holding
            them.
            """
          end
        end
    end
  end

  defp put_ca(opts, nil), do: opts

  defp put_ca(opts, value) do
    if pem?(value) do
      # Every certificate in the bundle, so an intermediate chain in
      # one file works.
      Keyword.put(opts, :cacerts, certificates!(value, :ca))
    else
      Keyword.put(opts, :cacertfile, value)
    end
  end

  defp put_client_cert(opts, nil), do: opts

  defp put_client_cert(opts, value) do
    if pem?(value) do
      # A list rather than a single DER, so a leaf plus its chain is
      # expressible in one option.
      Keyword.put(opts, :cert, certificates!(value, :client_cert))
    else
      Keyword.put(opts, :certfile, value)
    end
  end

  defp put_client_key(opts, nil), do: opts

  defp put_client_key(opts, value) do
    if pem?(value) do
      Keyword.put(opts, :key, private_key!(value))
    else
      Keyword.put(opts, :keyfile, value)
    end
  end

  defp certificates!(pem, key) do
    pem
    |> decode_pem!(key)
    |> Enum.filter(&match?({:Certificate, _der, _cipher}, &1))
    |> case do
      [] ->
        raise ArgumentError, "tls :#{key} contains no certificate"

      entries ->
        Enum.map(entries, fn {:Certificate, der, _cipher} -> der end)
    end
  end

  # Selected by name rather than by "not a certificate". An EC key
  # written by OpenSSL leads with an `EcpkParameters` block, so taking
  # the first non-certificate entry picks the curve parameters and
  # hands `:ssl` something that is not a key at all.
  @private_key_types [:RSAPrivateKey, :DSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo]

  defp private_key!(pem) do
    pem
    |> decode_pem!(:client_key)
    |> Enum.filter(fn {type, _der, _cipher} -> type in @private_key_types end)
    |> case do
      [] ->
        raise ArgumentError, "tls :client_key contains no private key"

      # `:ssl` wants `{type, der}`, where the type names the ASN.1
      # structure — `:RSAPrivateKey`, `:ECPrivateKey`, `:PrivateKeyInfo`.
      [{type, der, :not_encrypted} | _rest] ->
        {type, der}

      [{_type, _der, _cipher} | _rest] ->
        raise ArgumentError, """
        tls :client_key is encrypted, which is not supported as a PEM string.

        Pass a path to the key file instead — `:ssl` can decrypt one
        given a `:password`, which a PEM string here cannot carry.
        """
    end
  end

  defp decode_pem!(value, key) do
    entries =
      try do
        :public_key.pem_decode(value)
      rescue
        # Malformed input has two shapes: `pem_decode/1` returns `[]`
        # for something it does not recognise as PEM at all, but
        # *raises* on a block it started to parse and could not finish
        # — a corrupted base64 body, say. Both mean the same thing
        # here, and neither should reach the caller as a
        # FunctionClauseError from inside OTP.
        _exception -> []
      end

    case entries do
      [] ->
        raise ArgumentError, """
        tls :#{key} looks like PEM but no entries could be decoded.

        Check the value is complete, including its BEGIN and END lines.
        """

      entries ->
        entries
    end
  end

  defp pem?(value), do: is_binary(value) and String.contains?(value, @pem_header)
end
