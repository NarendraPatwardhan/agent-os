# @generated from contracts/wire.kdl by //contracts/codegen:projector — do not edit.
defmodule AgentOS.Contracts.Wire do
  @sidecar_scope_header "x-agentos-sidecar-scope"
  def sidecar_scope_header, do: @sidecar_scope_header

  @wire_version 3
  def wire_version, do: @wire_version
  @header_len 9
  def header_len, do: @header_len

  def hello, do: 0x00
  def welcome, do: 0x01
  def shell_in, do: 0x10
  def shell_out, do: 0x11
  def host_call, do: 0x20
  def host_result, do: 0x21
  def host_cancel, do: 0x22
  def session_start, do: 0x30
  def session_event, do: 0x31
  def session_end, do: 0x32
  def permission_request, do: 0x40
  def permission_response, do: 0x41

  def messages do
    [
      %{name: "HELLO", tag: 0x00, dir: "client->server", body: "json"},
      %{name: "WELCOME", tag: 0x01, dir: "server->client", body: "json"},
      %{name: "SHELL_IN", tag: 0x10, dir: "client->server", body: "binary"},
      %{name: "SHELL_OUT", tag: 0x11, dir: "server->client", body: "binary"},
      %{name: "HOST_CALL", tag: 0x20, dir: "server->client", body: "binary"},
      %{name: "HOST_RESULT", tag: 0x21, dir: "client->server", body: "binary"},
      %{name: "HOST_CANCEL", tag: 0x22, dir: "server->client", body: "binary"},
      %{name: "SESSION_START", tag: 0x30, dir: "client->server", body: "json"},
      %{name: "SESSION_EVENT", tag: 0x31, dir: "server->client", body: "json"},
      %{name: "SESSION_END", tag: 0x32, dir: "server->client", body: "json"},
      %{name: "PERMISSION_REQUEST", tag: 0x40, dir: "server->client", body: "json"},
      %{name: "PERMISSION_RESPONSE", tag: 0x41, dir: "client->server", body: "json"},
    ]
  end
end
