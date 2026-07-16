# @generated from contracts/browser.kdl by //contracts/codegen:projector — do not edit.
defmodule AgentOS.Contracts.Browser do
  @moduledoc false

  @protocol_version 1
  def protocol_version, do: @protocol_version
  @browser_kind "browser"
  def browser_kind, do: @browser_kind
  @browser_contract_digest "sha256:467c154dc423f6db81ceabce046c3044e2ca7dd780b4fbb3eb3e26fa29f83fca"
  def browser_contract_digest, do: @browser_contract_digest
  @browser_runner_profile "browser"
  def browser_runner_profile, do: @browser_runner_profile
  @browser_version 1
  def browser_version, do: @browser_version
  @browser_default_timeout_seconds 300
  def browser_default_timeout_seconds, do: @browser_default_timeout_seconds
  @browser_min_timeout_seconds 10
  def browser_min_timeout_seconds, do: @browser_min_timeout_seconds
  @browser_max_timeout_seconds 300
  def browser_max_timeout_seconds, do: @browser_max_timeout_seconds
  @browser_default_viewport_width 1280
  def browser_default_viewport_width, do: @browser_default_viewport_width
  @browser_default_viewport_height 720
  def browser_default_viewport_height, do: @browser_default_viewport_height
  @browser_min_viewport_edge 320
  def browser_min_viewport_edge, do: @browser_min_viewport_edge
  @browser_max_viewport_edge 4096
  def browser_max_viewport_edge, do: @browser_max_viewport_edge
  @browser_max_url_bytes 16384
  def browser_max_url_bytes, do: @browser_max_url_bytes
  @browser_max_page_id_bytes 96
  def browser_max_page_id_bytes, do: @browser_max_page_id_bytes
  @browser_max_selector_bytes 4096
  def browser_max_selector_bytes, do: @browser_max_selector_bytes
  @browser_max_text_bytes 1048576
  def browser_max_text_bytes, do: @browser_max_text_bytes
  @browser_max_type_delay_ms 1000
  def browser_max_type_delay_ms, do: @browser_max_type_delay_ms
  @browser_max_pages 32
  def browser_max_pages, do: @browser_max_pages
  @browser_max_screenshot_edge 16384
  def browser_max_screenshot_edge, do: @browser_max_screenshot_edge
  @browser_max_screenshot_pixels 16777216
  def browser_max_screenshot_pixels, do: @browser_max_screenshot_pixels
  @browser_wait_load 1
  def browser_wait_load, do: @browser_wait_load
  @browser_wait_dom_content_loaded 2
  def browser_wait_dom_content_loaded, do: @browser_wait_dom_content_loaded
  @browser_wait_network_idle 3
  def browser_wait_network_idle, do: @browser_wait_network_idle
  @browser_wait_commit 4
  def browser_wait_commit, do: @browser_wait_commit
  @browser_op_pages_list "pages.list"
  def browser_op_pages_list, do: @browser_op_pages_list
  @browser_op_pages_goto "pages.goto"
  def browser_op_pages_goto, do: @browser_op_pages_goto
  @browser_op_pages_title "pages.title"
  def browser_op_pages_title, do: @browser_op_pages_title
  @browser_op_pages_text "pages.text"
  def browser_op_pages_text, do: @browser_op_pages_text
  @browser_op_pages_click "pages.click"
  def browser_op_pages_click, do: @browser_op_pages_click
  @browser_op_pages_fill "pages.fill"
  def browser_op_pages_fill, do: @browser_op_pages_fill
  @browser_op_computer_screenshot "computer.screenshot"
  def browser_op_computer_screenshot, do: @browser_op_computer_screenshot
  @browser_op_computer_click "computer.click"
  def browser_op_computer_click, do: @browser_op_computer_click
  @browser_op_computer_type "computer.type"
  def browser_op_computer_type, do: @browser_op_computer_type
  @browser_op_computer_key "computer.key"
  def browser_op_computer_key, do: @browser_op_computer_key
  @browser_op_computer_scroll "computer.scroll"
  def browser_op_computer_scroll, do: @browser_op_computer_scroll


  defp field!(map, key) do
    case field(map, key, :__mc_missing__) do
      :__mc_missing__ -> raise KeyError, key: key, term: map
      value -> value
    end
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp read_header(bytes, expected_id, expected_version) do
    with {:ok, id, rest} <- read_u16(bytes),
         true <- id == expected_id || {:error, "wrong message id"},
         {:ok, version, rest} <- read_u8(rest),
         true <- version == expected_version || {:error, "unsupported message version"} do
      {:ok, rest}
    end
  end

  defp read_u8(<<value, rest::binary>>), do: {:ok, value, rest}
  defp read_u8(_bytes), do: {:error, "truncated frame"}
  defp read_u16(<<value::unsigned-little-16, rest::binary>>), do: {:ok, value, rest}
  defp read_u16(_bytes), do: {:error, "truncated frame"}
  defp read_u32(<<value::unsigned-little-32, rest::binary>>), do: {:ok, value, rest}
  defp read_u32(_bytes), do: {:error, "truncated frame"}
  defp read_bool(bytes) do
    case read_u8(bytes) do
      {:ok, 0, rest} -> {:ok, false, rest}
      {:ok, 1, rest} -> {:ok, true, rest}
      {:ok, _value, _rest} -> {:error, "invalid bool"}
      err -> err
    end
  end

  defp read_bytes(bytes) do
    with {:ok, len, rest} <- read_u32(bytes),
         true <- byte_size(rest) >= len || {:error, "truncated frame"} do
      <<out::binary-size(^len), rest::binary>> = rest
      {:ok, out, rest}
    end
  end

  defp read_str(bytes) do
    with {:ok, out, rest} <- read_bytes(bytes),
         true <- String.valid?(out) || {:error, "invalid utf-8"} do
      {:ok, out, rest}
    end
  end

  defp read_opt(bytes, fun) do
    case read_u8(bytes) do
      {:ok, 0, rest} -> {:ok, nil, rest}
      {:ok, 1, rest} -> fun.(rest)
      {:ok, _value, _rest} -> {:error, "invalid optional presence"}
      err -> err
    end
  end

  defp read_eof(<<>>), do: :ok
  defp read_eof(_rest), do: {:error, "trailing bytes"}

  defp put_u8(value), do: <<value::unsigned-little-8>>
  defp put_u16(value), do: <<value::unsigned-little-16>>
  defp put_u32(value), do: <<value::unsigned-little-32>>
  defp put_bool(true), do: <<1>>
  defp put_bool(false), do: <<0>>
  defp put_bytes(bytes), do: [put_u32(byte_size(bytes)), bytes]
  defp put_str(value), do: put_bytes(value)

  defp read_message_list(bytes, decoder) do
    with {:ok, n, rest} <- read_u32(bytes) do
      read_message_list_items(n, rest, decoder, [])
    end
  end

  defp read_message_list_items(0, rest, _decoder, acc), do: {:ok, Enum.reverse(acc), rest}

  defp read_message_list_items(n, bytes, decoder, acc) do
    with {:ok, item_bytes, rest} <- read_bytes(bytes),
         {:ok, item} <- decoder.(item_bytes) do
      read_message_list_items(n - 1, rest, decoder, [item | acc])
    end
  end

  defp put_message_list(values, encoder) do
    [put_u32(length(values)), Enum.map(values, fn value -> put_bytes(encoder.(value)) end)]
  end

  defp read_message(bytes, decoder) do
    with {:ok, item_bytes, rest} <- read_bytes(bytes),
         {:ok, item} <- decoder.(item_bytes) do
      {:ok, item, rest}
    end
  end

  defp read_i32(<<value::signed-little-32, rest::binary>>), do: {:ok, value, rest}
  defp read_i32(_bytes), do: {:error, "truncated frame"}
  defp put_i32(value), do: <<value::signed-little-32>>

  @browser_viewport_msg_id 1
  @browser_viewport_version 1

  def encode_browser_viewport(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_viewport_msg_id),
      put_u8(@browser_viewport_version),
      put_u32(field!(msg, :width)),
      put_u32(field!(msg, :height))
    ])
  end

  def decode_browser_viewport(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_viewport_msg_id, @browser_viewport_version),
         {:ok, width, rest} <- read_u32(rest),
         {:ok, height, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        width: width,
        height: height,
      }}
    end
  end

  def browser_viewport_msg_id, do: @browser_viewport_msg_id
  def browser_viewport_version, do: @browser_viewport_version

  # BROWSER_VIEWPORT
  @browser_create_options_msg_id 2
  @browser_create_options_version 1

  def encode_browser_create_options(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_create_options_msg_id),
      put_u8(@browser_create_options_version),
      put_bool(field!(msg, :headless)),
      put_u32(field!(msg, :timeout_seconds)),
      case field(msg, :viewport) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_browser_viewport(value))]
      end
    ])
  end

  def decode_browser_create_options(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_create_options_msg_id, @browser_create_options_version),
         {:ok, headless, rest} <- read_bool(rest),
         {:ok, timeout_seconds, rest} <- read_u32(rest),
         {:ok, viewport, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_browser_viewport/1) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        headless: headless,
        timeout_seconds: timeout_seconds,
        viewport: viewport,
      }}
    end
  end

  def browser_create_options_msg_id, do: @browser_create_options_msg_id
  def browser_create_options_version, do: @browser_create_options_version

  # BROWSER_CREATE_OPTIONS
  @browser_metadata_msg_id 3
  @browser_metadata_version 1

  def encode_browser_metadata(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_metadata_msg_id),
      put_u8(@browser_metadata_version),
      put_bool(field!(msg, :headless)),
      put_bytes(encode_browser_viewport(field!(msg, :viewport))),
      put_str(field!(msg, :active_page_id))
    ])
  end

  def decode_browser_metadata(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_metadata_msg_id, @browser_metadata_version),
         {:ok, headless, rest} <- read_bool(rest),
         {:ok, viewport, rest} <- read_message(rest, &decode_browser_viewport/1),
         {:ok, active_page_id, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        headless: headless,
        viewport: viewport,
        active_page_id: active_page_id,
      }}
    end
  end

  def browser_metadata_msg_id, do: @browser_metadata_msg_id
  def browser_metadata_version, do: @browser_metadata_version

  # BROWSER_METADATA
  @browser_page_msg_id 4
  @browser_page_version 1

  def encode_browser_page(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_page_msg_id),
      put_u8(@browser_page_version),
      put_str(field!(msg, :id)),
      put_str(field!(msg, :url)),
      put_str(field!(msg, :title))
    ])
  end

  def decode_browser_page(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_page_msg_id, @browser_page_version),
         {:ok, id, rest} <- read_str(rest),
         {:ok, url, rest} <- read_str(rest),
         {:ok, title, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        id: id,
        url: url,
        title: title,
      }}
    end
  end

  def browser_page_msg_id, do: @browser_page_msg_id
  def browser_page_version, do: @browser_page_version

  # BROWSER_PAGE
  @browser_pages_msg_id 5
  @browser_pages_version 1

  def encode_browser_pages(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_pages_msg_id),
      put_u8(@browser_pages_version),
      put_message_list(field!(msg, :items), &encode_browser_page/1)
    ])
  end

  def decode_browser_pages(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_pages_msg_id, @browser_pages_version),
         {:ok, items, rest} <- read_message_list(rest, &decode_browser_page/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        items: items,
      }}
    end
  end

  def browser_pages_msg_id, do: @browser_pages_msg_id
  def browser_pages_version, do: @browser_pages_version

  # BROWSER_PAGES
  @browser_page_target_msg_id 6
  @browser_page_target_version 1

  def encode_browser_page_target(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_page_target_msg_id),
      put_u8(@browser_page_target_version),
      case field(msg, :page_id) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end
    ])
  end

  def decode_browser_page_target(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_page_target_msg_id, @browser_page_target_version),
         {:ok, page_id, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        page_id: page_id,
      }}
    end
  end

  def browser_page_target_msg_id, do: @browser_page_target_msg_id
  def browser_page_target_version, do: @browser_page_target_version

  # BROWSER_PAGE_TARGET
  @browser_goto_request_msg_id 7
  @browser_goto_request_version 1

  def encode_browser_goto_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_goto_request_msg_id),
      put_u8(@browser_goto_request_version),
      case field(msg, :page_id) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_str(field!(msg, :url)),
      put_u32(field!(msg, :wait_until))
    ])
  end

  def decode_browser_goto_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_goto_request_msg_id, @browser_goto_request_version),
         {:ok, page_id, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, url, rest} <- read_str(rest),
         {:ok, wait_until, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        page_id: page_id,
        url: url,
        wait_until: wait_until,
      }}
    end
  end

  def browser_goto_request_msg_id, do: @browser_goto_request_msg_id
  def browser_goto_request_version, do: @browser_goto_request_version

  # BROWSER_GOTO_REQUEST
  @browser_locator_request_msg_id 8
  @browser_locator_request_version 1

  def encode_browser_locator_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_locator_request_msg_id),
      put_u8(@browser_locator_request_version),
      case field(msg, :page_id) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_str(field!(msg, :selector))
    ])
  end

  def decode_browser_locator_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_locator_request_msg_id, @browser_locator_request_version),
         {:ok, page_id, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, selector, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        page_id: page_id,
        selector: selector,
      }}
    end
  end

  def browser_locator_request_msg_id, do: @browser_locator_request_msg_id
  def browser_locator_request_version, do: @browser_locator_request_version

  # BROWSER_LOCATOR_REQUEST
  @browser_fill_request_msg_id 9
  @browser_fill_request_version 1

  def encode_browser_fill_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_fill_request_msg_id),
      put_u8(@browser_fill_request_version),
      case field(msg, :page_id) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_str(field!(msg, :selector)),
      put_str(field!(msg, :value))
    ])
  end

  def decode_browser_fill_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_fill_request_msg_id, @browser_fill_request_version),
         {:ok, page_id, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, selector, rest} <- read_str(rest),
         {:ok, value, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        page_id: page_id,
        selector: selector,
        value: value,
      }}
    end
  end

  def browser_fill_request_msg_id, do: @browser_fill_request_msg_id
  def browser_fill_request_version, do: @browser_fill_request_version

  # BROWSER_FILL_REQUEST
  @browser_point_request_msg_id 10
  @browser_point_request_version 1

  def encode_browser_point_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_point_request_msg_id),
      put_u8(@browser_point_request_version),
      case field(msg, :page_id) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_u32(field!(msg, :x)),
      put_u32(field!(msg, :y))
    ])
  end

  def decode_browser_point_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_point_request_msg_id, @browser_point_request_version),
         {:ok, page_id, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, x, rest} <- read_u32(rest),
         {:ok, y, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        page_id: page_id,
        x: x,
        y: y,
      }}
    end
  end

  def browser_point_request_msg_id, do: @browser_point_request_msg_id
  def browser_point_request_version, do: @browser_point_request_version

  # BROWSER_POINT_REQUEST
  @browser_type_request_msg_id 11
  @browser_type_request_version 1

  def encode_browser_type_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_type_request_msg_id),
      put_u8(@browser_type_request_version),
      case field(msg, :page_id) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_str(field!(msg, :text)),
      put_u32(field!(msg, :delay_ms))
    ])
  end

  def decode_browser_type_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_type_request_msg_id, @browser_type_request_version),
         {:ok, page_id, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, text, rest} <- read_str(rest),
         {:ok, delay_ms, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        page_id: page_id,
        text: text,
        delay_ms: delay_ms,
      }}
    end
  end

  def browser_type_request_msg_id, do: @browser_type_request_msg_id
  def browser_type_request_version, do: @browser_type_request_version

  # BROWSER_TYPE_REQUEST
  @browser_key_request_msg_id 12
  @browser_key_request_version 1

  def encode_browser_key_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_key_request_msg_id),
      put_u8(@browser_key_request_version),
      case field(msg, :page_id) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_str(field!(msg, :key))
    ])
  end

  def decode_browser_key_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_key_request_msg_id, @browser_key_request_version),
         {:ok, page_id, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, key, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        page_id: page_id,
        key: key,
      }}
    end
  end

  def browser_key_request_msg_id, do: @browser_key_request_msg_id
  def browser_key_request_version, do: @browser_key_request_version

  # BROWSER_KEY_REQUEST
  @browser_scroll_request_msg_id 13
  @browser_scroll_request_version 1

  def encode_browser_scroll_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_scroll_request_msg_id),
      put_u8(@browser_scroll_request_version),
      case field(msg, :page_id) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_i32(field!(msg, :delta_x)),
      put_i32(field!(msg, :delta_y))
    ])
  end

  def decode_browser_scroll_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_scroll_request_msg_id, @browser_scroll_request_version),
         {:ok, page_id, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, delta_x, rest} <- read_i32(rest),
         {:ok, delta_y, rest} <- read_i32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        page_id: page_id,
        delta_x: delta_x,
        delta_y: delta_y,
      }}
    end
  end

  def browser_scroll_request_msg_id, do: @browser_scroll_request_msg_id
  def browser_scroll_request_version, do: @browser_scroll_request_version

  # BROWSER_SCROLL_REQUEST
  @browser_screenshot_request_msg_id 14
  @browser_screenshot_request_version 1

  def encode_browser_screenshot_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_screenshot_request_msg_id),
      put_u8(@browser_screenshot_request_version),
      case field(msg, :page_id) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_bool(field!(msg, :full_page))
    ])
  end

  def decode_browser_screenshot_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_screenshot_request_msg_id, @browser_screenshot_request_version),
         {:ok, page_id, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, full_page, rest} <- read_bool(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        page_id: page_id,
        full_page: full_page,
      }}
    end
  end

  def browser_screenshot_request_msg_id, do: @browser_screenshot_request_msg_id
  def browser_screenshot_request_version, do: @browser_screenshot_request_version

  # BROWSER_SCREENSHOT_REQUEST
  @browser_string_msg_id 15
  @browser_string_version 1

  def encode_browser_string(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_string_msg_id),
      put_u8(@browser_string_version),
      put_str(field!(msg, :value))
    ])
  end

  def decode_browser_string(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_string_msg_id, @browser_string_version),
         {:ok, value, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        value: value,
      }}
    end
  end

  def browser_string_msg_id, do: @browser_string_msg_id
  def browser_string_version, do: @browser_string_version

  # BROWSER_STRING
  @browser_bytes_msg_id 16
  @browser_bytes_version 1

  def encode_browser_bytes(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@browser_bytes_msg_id),
      put_u8(@browser_bytes_version),
      put_bytes(field!(msg, :value))
    ])
  end

  def decode_browser_bytes(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @browser_bytes_msg_id, @browser_bytes_version),
         {:ok, value, rest} <- read_bytes(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        value: value,
      }}
    end
  end

  def browser_bytes_msg_id, do: @browser_bytes_msg_id
  def browser_bytes_version, do: @browser_bytes_version

  # BROWSER_BYTES
end
