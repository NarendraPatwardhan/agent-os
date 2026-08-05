defmodule AgentOS.SnapshotContractTest do
  use ExUnit.Case, async: true

  alias AgentOS.Contracts.Snapshot

  test "full baseline identity matches the MCSN v4 cross-host vector" do
    view = %{
      kind: :full,
      kernel_digest: :binary.copy(<<0x11>>, Snapshot.snapshot_digest_len()),
      memory_root: :binary.copy(<<0x22>>, Snapshot.snapshot_digest_len()),
      memory_len: 65_536
    }

    assert Base.encode16(Snapshot.full_baseline_id(view), case: :lower) ==
             "119c5f4b0dc01dc676e915857df680612687dce3d63944f5d85be7429e96adcd"
  end
end
