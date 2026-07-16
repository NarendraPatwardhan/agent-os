defmodule AgentOS.BrowserFirecrackerTest do
  use ExUnit.Case, async: false
  @moduletag :kvm

  alias AgentOS.Contracts.{Browser, Sidecar}
  alias AgentOS.Sidecars

  test "real browser runner boots and executes its projected page protocol" do
    vm_id = {"browser-kvm", Integer.to_string(System.unique_integer([:positive]))}
    started_at = System.monotonic_time(:microsecond)

    grant = %{
      kind: Browser.browser_kind(),
      version: Browser.browser_version(),
      contract_digest: Browser.browser_contract_digest(),
      guest: true,
      max_instances: 1,
      fork: Sidecar.sidecar_fork_omit(),
      config: <<>>
    }

    assert {:ok, _scope} = Sidecars.attach_vm(vm_id, self(), %{"web" => grant})

    create =
      Browser.encode_browser_create_options(%{
        headless: true,
        timeout_seconds: 60,
        viewport: %{width: 800, height: 600}
      })

    assert {:ok, instance} =
             Sidecars.create(vm_id, %{
               grant: "web",
               kind: Browser.browser_kind(),
               body: create,
               idempotency_key: "browser-kvm",
               timeout_ms: 60_000
             })

    assert {:ok, metadata} = Browser.decode_browser_metadata(instance.metadata)
    create_us = System.monotonic_time(:microsecond) - started_at
    assert {:ok, daemon} = AgentOS.Sidecars.Firecracker.Daemon.measurements(instance.id)
    assert {:ok, relay} = AgentOS.Sidecars.Firecracker.Relay.measurements(instance.id)
    startup = daemon |> Map.merge(relay) |> Map.put(:create_us, create_us)
    assert Enum.all?(startup, fn {_phase, duration} -> is_integer(duration) and duration >= 0 end)
    IO.puts("browser cold start (microseconds): #{inspect(startup, sorted: true)}")

    html =
      """
      <title>AgentOS</title>
      <style>
        body { margin: 0 }
        #name { position: absolute; left: 20px; top: 80px; width: 200px; height: 40px }
        #submit { position: absolute; left: 20px; top: 140px; width: 200px; height: 50px }
        #out { position: absolute; left: 20px; top: 210px }
      </style>
      <input id="name" onkeydown="if(event.key==='Enter')document.getElementById('out').textContent='Hello '+this.value">
      <button id="submit" onclick="document.getElementById('out').textContent='Hello '+document.getElementById('name').value">Submit</button>
      <main id="out">browser sidecar</main>
      <div style="height: 2000px"></div>
      """

    goto =
      Browser.encode_browser_goto_request(%{
        page_id: metadata.active_page_id,
        url: "data:text/html;base64," <> Base.encode64(html),
        wait_until: Browser.browser_wait_load()
      })

    assert {:ok, page_bytes} = invoke(vm_id, instance, Browser.browser_op_pages_goto(), goto)
    assert {:ok, page} = Browser.decode_browser_page(page_bytes)
    assert page.id == metadata.active_page_id

    target = Browser.encode_browser_page_target(%{page_id: page.id})
    assert {:ok, title_bytes} = invoke(vm_id, instance, Browser.browser_op_pages_title(), target)
    assert {:ok, %{value: "AgentOS"}} = Browser.decode_browser_string(title_bytes)

    text = Browser.encode_browser_locator_request(%{page_id: page.id, selector: "main"})
    assert {:ok, text_bytes} = invoke(vm_id, instance, Browser.browser_op_pages_text(), text)
    assert {:ok, %{value: "browser sidecar"}} = Browser.decode_browser_string(text_bytes)

    assert {:ok, pages_bytes} = invoke(vm_id, instance, Browser.browser_op_pages_list(), <<>>)
    assert {:ok, %{items: [%{id: page_id}]}} = Browser.decode_browser_pages(pages_bytes)
    assert page_id == page.id

    fill =
      Browser.encode_browser_fill_request(%{
        page_id: page.id,
        selector: "#name",
        value: "Agent"
      })

    assert {:ok, <<>>} = invoke(vm_id, instance, Browser.browser_op_pages_fill(), fill)

    submit = Browser.encode_browser_locator_request(%{page_id: page.id, selector: "#submit"})
    assert {:ok, <<>>} = invoke(vm_id, instance, Browser.browser_op_pages_click(), submit)
    assert_text(vm_id, instance, page.id, "Hello Agent")

    point = Browser.encode_browser_point_request(%{page_id: page.id, x: 50, y: 100})
    assert {:ok, <<>>} = invoke(vm_id, instance, Browser.browser_op_computer_click(), point)

    select = Browser.encode_browser_key_request(%{page_id: page.id, key: "Control+A"})
    assert {:ok, <<>>} = invoke(vm_id, instance, Browser.browser_op_computer_key(), select)

    type =
      Browser.encode_browser_type_request(%{page_id: page.id, text: "Codex", delay_ms: 0})

    assert {:ok, <<>>} = invoke(vm_id, instance, Browser.browser_op_computer_type(), type)

    enter = Browser.encode_browser_key_request(%{page_id: page.id, key: "Enter"})
    assert {:ok, <<>>} = invoke(vm_id, instance, Browser.browser_op_computer_key(), enter)
    assert_text(vm_id, instance, page.id, "Hello Codex")

    scroll =
      Browser.encode_browser_scroll_request(%{page_id: page.id, delta_x: 0, delta_y: 400})

    assert {:ok, <<>>} = invoke(vm_id, instance, Browser.browser_op_computer_scroll(), scroll)

    screenshot =
      Browser.encode_browser_screenshot_request(%{page_id: page.id, full_page: false})

    assert {:ok, screenshot_bytes} =
             invoke(vm_id, instance, Browser.browser_op_computer_screenshot(), screenshot)

    assert {:ok, %{value: <<0x89, 0x50, _rest::binary>>}} =
             Browser.decode_browser_bytes(screenshot_bytes)

    missing = Browser.encode_browser_locator_request(%{page_id: page.id, selector: "#missing"})

    assert {:error, {:runner, code, _message}} =
             invoke(vm_id, instance, Browser.browser_op_pages_text(), missing)

    assert code == Sidecar.sidecar_error_not_found()

    assert {:error, {:runner, code, "malformed browser request"}} =
             invoke(vm_id, instance, Browser.browser_op_pages_title(), <<1, 2>>)

    assert code == Sidecar.sidecar_error_invalid_request()
    assert {:ok, title_bytes} = invoke(vm_id, instance, Browser.browser_op_pages_title(), target)
    assert {:ok, %{value: "AgentOS"}} = Browser.decode_browser_string(title_bytes)

    assert :ok = Sidecars.close_vm(vm_id)
  end

  defp assert_text(vm_id, instance, page_id, expected) do
    request = Browser.encode_browser_locator_request(%{page_id: page_id, selector: "#out"})
    assert {:ok, bytes} = invoke(vm_id, instance, Browser.browser_op_pages_text(), request)
    assert {:ok, %{value: ^expected}} = Browser.decode_browser_string(bytes)
  end

  defp invoke(vm_id, instance, operation, body) do
    Sidecars.invoke(vm_id, %{
      id: instance.id,
      generation: instance.generation,
      grant: "web",
      kind: Browser.browser_kind(),
      operation: operation,
      body: body,
      timeout_ms: 60_000
    })
  end
end
