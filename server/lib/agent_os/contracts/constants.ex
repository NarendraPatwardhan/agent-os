# @generated from contracts/constants.kdl by //contracts/codegen:projector — do not edit.
defmodule AgentOS.Contracts.Constants do

  # syscall ABI version: (major << 16) | minor
  def sys_abi_major, do: 1
  def sys_abi_minor, do: 7
  def abi_version, do: 65543

  # errno
  def esuccess, do: 0
  def eacces, do: 2
  def eagain, do: 6
  def ebadf, do: 8
  def echild, do: 10
  def eexist, do: 20
  def eintr, do: 27
  def einval, do: 28
  def eio, do: 29
  def eisdir, do: 31
  def eloop, do: 32
  def emfile, do: 33
  def enoent, do: 44
  def enosys, do: 52
  def emsgsize, do: 53
  def enotdir, do: 54
  def enotempty, do: 55
  def eperm, do: 63
  def epipe, do: 64
  def esrch, do: 71
  def etimedout, do: 73
  def exdev, do: 75

  # tier
  def tier_inherit, do: 0
  def tier_full, do: 1
  def tier_read_write, do: 2
  def tier_read_only, do: 3
  def tier_isolated, do: 4

  # capability
  def cap_fs_read, do: 1
  def cap_fs_write, do: 2
  def cap_spawn, do: 4
  def cap_net, do: 8
  def cap_persist, do: 16
  def cap_ambient, do: 32
  def cap_scratch, do: 64
  def cap_mount, do: 128

  # tier → capability ceiling — the kernel's Tier::caps() consumes this (single source)
  def tier_caps(tier) do
    case tier do
      0 -> 0
      1 -> 255
      2 -> 99
      3 -> 97
      4 -> 1
      _ -> 0
    end
  end

  # open-flags
  def o_read, do: 1
  def o_write, do: 2
  def o_create, do: 4
  def o_trunc, do: 8
  def o_append, do: 16

  # seek
  def seek_set, do: 0
  def seek_cur, do: 1
  def seek_end, do: 2

  # waitpid
  def wnohang, do: 1

  # poll
  def pollin, do: 1
  def pollout, do: 4
  def pollerr, do: 8
  def pollhup, do: 16
  def poll_block, do: -1

  # signal
  def sighup, do: 1
  def sigint, do: 2
  def sigquit, do: 3
  def sigkill, do: 9
  def sigusr1, do: 10
  def sigusr2, do: 12
  def sigterm, do: 15
  def sigchld, do: 17
  def sigcont, do: 18
  def sigstop, do: 19
  def sigtstp, do: 20
  def sig_dfl, do: 0
  def sig_ign, do: 1
  def stopped_status_base, do: 65536

  # serve-op
  def serve_op_open, do: 0
  def serve_op_readdir, do: 1
  def serve_op_mkdir, do: 2
  def serve_op_unlink, do: 3
  def serve_op_rename, do: 4
  def serve_op_stat, do: 5
  def serve_dirent_file, do: 0
  def serve_dirent_dir, do: 1
  def serve_dirent_symlink, do: 2

  # mount-op
  def mount_op_open, do: 0
  def mount_op_readdir, do: 1
  def mount_op_mkdir, do: 2
  def mount_op_unlink, do: 3
  def mount_op_rename, do: 4
  def mount_op_stat, do: 5
  def mount_op_write, do: 6

  # persist-op
  def persist_op_get, do: 1
  def persist_op_put, do: 2
  def persist_op_delete, do: 3
  def persist_op_list, do: 4
  def persist_get_absent, do: 0
  def persist_get_present, do: 1

  # stat-record
  def stat_node_file, do: 0
  def stat_node_dir, do: 1
  def stat_node_symlink, do: 2
  def stat_rec_size_off, do: 0
  def stat_rec_node_type_off, do: 8
  def stat_rec_nlink_off, do: 12
  def stat_rec_mode_off, do: 16
  def stat_rec_mtime_off, do: 20
  def stat_rec_atime_off, do: 28
  def stat_rec_ctime_off, do: 36
  def stat_rec_len, do: 44
  def wire_version, do: 2

  # the argv[1] marker the kernel passes to spawn a binary in SERVICE mode (SYSTEMS.md)
  def service_marker, do: "--mc-serve"
end
