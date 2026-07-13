# @generated from contracts/snapshot.kdl by //contracts/codegen:projector — do not edit.

defmodule AgentOS.Contracts.Snapshot do
  @moduledoc "Projected MCSN snapshot framing and validation."

  @snapshot_magic 1314079565
  @snapshot_version 2
  @snapshot_header_len 128
  @snapshot_page_size 65536
  @snapshot_max_memory_len 1073741824
  @snapshot_digest_len 32
  @snapshot_kind_full 1
  @snapshot_kind_incremental 2

  def snapshot_magic, do: @snapshot_magic
  def snapshot_version, do: @snapshot_version
  def snapshot_header_len, do: @snapshot_header_len
  def snapshot_page_size, do: @snapshot_page_size
  def snapshot_max_memory_len, do: @snapshot_max_memory_len
  def snapshot_digest_len, do: @snapshot_digest_len

  def snapshot_bitmap_len(memory_len) when is_integer(memory_len) and memory_len >= 0 do
    memory_len
    |> div(@snapshot_page_size)
    |> then(&div(&1 + 7, 8))
  end

  def parse(bytes) when is_binary(bytes) and byte_size(bytes) < @snapshot_header_len,
    do: {:error, :too_short}

  def parse(bytes) when is_binary(bytes) do
    raw_kind = u32_at(bytes, 8)
    memory_len = u32_at(bytes, 20)
    changed_pages = u32_at(bytes, 24)
    kernel_digest = digest_at(bytes, 32)
    memory_digest = digest_at(bytes, 64)
    base_snapshot_digest = digest_at(bytes, 96)
    payload = binary_part(bytes, @snapshot_header_len, byte_size(bytes) - @snapshot_header_len)

    with :ok <- equal(u32_at(bytes, 0), @snapshot_magic, :bad_magic),
         :ok <- equal(u32_at(bytes, 4), @snapshot_version, :unsupported_version),
         {:ok, kind} <- snapshot_kind(raw_kind),
         :ok <- equal(u32_at(bytes, 12), @snapshot_header_len, :bad_header_length),
         :ok <- equal(u32_at(bytes, 16), @snapshot_page_size, :bad_page_size),
         :ok <- positive(memory_len, :empty_memory),
         :ok <- at_most(memory_len, @snapshot_max_memory_len, :memory_too_large),
         :ok <- divisible(memory_len, @snapshot_page_size, :misaligned_memory),
         :ok <- equal(u32_at(bytes, 28), 0, :reserved_nonzero),
         :ok <- present(kernel_digest, :missing_digest),
         :ok <- present(memory_digest, :missing_digest) do
      parse_payload(kind, memory_len, changed_pages, kernel_digest, memory_digest,
        base_snapshot_digest, payload)
    end
  end

  def parse(_bytes), do: {:error, :too_short}

  defp parse_payload(:full, memory_len, changed_pages, kernel_digest, memory_digest,
         base_snapshot_digest, payload) do
    with :ok <- missing(base_snapshot_digest, :unexpected_base),
         :ok <- equal(changed_pages, 0, :unexpected_changed_pages),
         :ok <- equal(byte_size(payload), memory_len, :length_mismatch) do
      {:ok, snapshot_view(:full, memory_len, changed_pages, kernel_digest, memory_digest,
        base_snapshot_digest, <<>>, payload)}
    end
  end

  defp parse_payload(:incremental, memory_len, changed_pages, kernel_digest, memory_digest,
         base_snapshot_digest, payload) do
    bitmap_len = snapshot_bitmap_len(memory_len)

    with :ok <- present(base_snapshot_digest, :missing_base),
         :ok <- at_least(byte_size(payload), bitmap_len, :length_mismatch) do
      bitmap = binary_part(payload, 0, bitmap_len)
      pages = binary_part(payload, bitmap_len, byte_size(payload) - bitmap_len)
      memory_pages = div(memory_len, @snapshot_page_size)

      with :ok <- valid_bitmap_tail(bitmap, memory_pages),
           :ok <- equal(bitmap_popcount(bitmap), changed_pages, :bad_bitmap),
           :ok <- equal(byte_size(pages), changed_pages * @snapshot_page_size, :length_mismatch) do
        {:ok, snapshot_view(:incremental, memory_len, changed_pages, kernel_digest,
          memory_digest, base_snapshot_digest, bitmap, pages)}
      end
    end
  end

  defp snapshot_view(kind, memory_len, changed_pages, kernel_digest, memory_digest,
         base_snapshot_digest, bitmap, pages) do
    %{
      kind: kind,
      memory_len: memory_len,
      changed_pages: changed_pages,
      kernel_digest: kernel_digest,
      memory_digest: memory_digest,
      base_snapshot_digest: base_snapshot_digest,
      bitmap: bitmap,
      pages: pages
    }
  end

  defp snapshot_kind(@snapshot_kind_full), do: {:ok, :full}
  defp snapshot_kind(@snapshot_kind_incremental), do: {:ok, :incremental}
  defp snapshot_kind(_kind), do: {:error, :unknown_kind}

  defp valid_bitmap_tail(_bitmap, memory_pages) when rem(memory_pages, 8) == 0, do: :ok

  defp valid_bitmap_tail(bitmap, memory_pages) do
    if :erlang.bsr(:binary.last(bitmap), rem(memory_pages, 8)) == 0,
      do: :ok,
      else: {:error, :bad_bitmap}
  end

  defp bitmap_popcount(bitmap) do
    for <<byte <- bitmap>>, reduce: 0 do
      count -> count + popcount_byte(byte, 0)
    end
  end

  defp popcount_byte(0, count), do: count
  defp popcount_byte(byte, count), do: popcount_byte(:erlang.band(byte, byte - 1), count + 1)

  defp u32_at(bytes, offset) do
    <<value::little-unsigned-32>> = binary_part(bytes, offset, 4)
    value
  end

  defp digest_at(bytes, offset), do: binary_part(bytes, offset, @snapshot_digest_len)
  defp present(<<0::size(@snapshot_digest_len * 8)>>, error), do: {:error, error}
  defp present(_digest, _error), do: :ok
  defp missing(<<0::size(@snapshot_digest_len * 8)>>, _error), do: :ok
  defp missing(_digest, error), do: {:error, error}
  defp equal(value, value, _error), do: :ok
  defp equal(_left, _right, error), do: {:error, error}
  defp positive(value, _error) when value > 0, do: :ok
  defp positive(_value, error), do: {:error, error}
  defp at_most(value, max, _error) when value <= max, do: :ok
  defp at_most(_value, _max, error), do: {:error, error}
  defp at_least(value, min, _error) when value >= min, do: :ok
  defp at_least(_value, _min, error), do: {:error, error}
  defp divisible(value, divisor, _error) when rem(value, divisor) == 0, do: :ok
  defp divisible(_value, _divisor, error), do: {:error, error}
end
