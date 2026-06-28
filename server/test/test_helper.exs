ExUnit.start()

case AgentOS.Supervisor.start_link() do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
