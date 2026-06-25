//! `exec` job control — the job table, foreground/background management, and the
//! `jobs`/`fg`/`bg`/`wait`/`kill` builtins. Split out of `exec/mod.rs` for
//! navigability; the `Job`/`FgWait` types stay in the core (they appear in `Interp`).

use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;

use crate::ast::Command;
use crate::os::*;
use crate::word::WordPart;

use super::{FgWait, Interp, Job};

impl<'o, O: ShellOs> Interp<'o, O> {
    // ---- foreground job control ----

    /// Whether interactive job control is in effect (the shell owns a terminal).
    pub(crate) fn job_control(&self) -> bool {
        self.os.isatty(STDIN)
    }

    /// A best-effort display label for a command, used in job notices. Renders
    /// the literal text of a simple command's words; falls back to a generic
    /// tag for compounds/functions.
    pub(crate) fn command_label(&self, cmd: &Command) -> String {
        match cmd {
            Command::Simple(sc) => {
                let parts: Vec<String> = sc
                    .words
                    .iter()
                    .map(|w| {
                        w.iter()
                            .map(|p| match p {
                                WordPart::Lit { text, .. } => text.clone(),
                                _ => String::new(),
                            })
                            .collect::<String>()
                    })
                    .filter(|s| !s.is_empty())
                    .collect();
                if parts.is_empty() {
                    "job".to_string()
                } else {
                    parts.join(" ")
                }
            }
            Command::Compound { .. } => "compound".to_string(),
            Command::Function { .. } => "function".to_string(),
        }
    }

    /// Put a freshly-spawned foreground pipeline into its own process group and
    /// give it the terminal, so Ctrl-C / Ctrl-Z reach the job and not the shell.
    /// A no-op without job control (scripts, `-c`, pipes).
    pub(crate) fn enter_foreground(&mut self, pids: &[Pid]) {
        if !self.job_control() || pids.is_empty() {
            return;
        }
        let grp = pids[0];
        for &p in pids {
            let _ = self.os.setpgid(p, grp);
        }
        let _ = self.os.set_foreground_pgid(grp);
    }

    /// Return the terminal to the shell after a foreground job finishes/stops.
    pub(crate) fn leave_foreground(&mut self) {
        if !self.job_control() {
            return;
        }
        let _ = self.os.set_foreground_pgid(self.shell_pid);
    }

    /// Wait for one foreground pid, distinguishing exit from a SIGTSTP stop.
    pub(crate) fn wait_one(&mut self, pid: Pid) -> FgWait {
        match self.os.waitpid(pid) {
            Ok(st) if st >= STOPPED_STATUS => FgWait::Stopped,
            Ok(st) => FgWait::Exited(st),
            Err(_) => FgWait::Exited(1),
        }
    }

    /// Record a freshly-stopped foreground job and announce it, mirroring a
    /// real shell's `[n]+  Stopped` notice. Returns the job id.
    pub(crate) fn record_stopped(&mut self, pids: Vec<Pid>, cmd: String) -> u32 {
        let id = self.next_job;
        self.next_job += 1;
        self.last_bg = pids.last().copied();
        self.jobs.push(Job {
            id,
            pids,
            cmd: cmd.clone(),
            running: true,
            stopped: true,
        });
        let o = self.cur_out();
        self.write_fd(o, &format!("\n[{id}]+  Stopped  {cmd}\n"));
        id
    }

    // ---- job control ----

    /// Reap exited background children, prune dead jobs. Stopped jobs (whose
    /// children have not exited) are left intact. The non-blocking poll never
    /// reports a stop, so this only ever removes genuinely-finished pids.
    fn reap_jobs(&mut self) {
        while let Ok(Some((pid, _st))) = self.os.try_wait_any() {
            for j in self.jobs.iter_mut() {
                j.pids.retain(|&p| p != pid);
                if j.pids.is_empty() {
                    j.running = false;
                }
            }
        }
        self.jobs.retain(|j| j.running);
    }

    /// Resolve a job spec (`%1`, `%%`, `%+`, `%-`, or `None` ⇒ current) to an
    /// index into `self.jobs`. The "current" job is the most recent one.
    fn job_index(&self, spec: Option<&str>) -> Option<usize> {
        match spec {
            None | Some("%%") | Some("%+") | Some("+") | Some("%-") | Some("-") => {
                if self.jobs.is_empty() {
                    None
                } else {
                    Some(self.jobs.len() - 1)
                }
            }
            Some(s) => {
                let n = s.trim_start_matches('%');
                n.parse::<u32>()
                    .ok()
                    .and_then(|id| self.jobs.iter().position(|j| j.id == id))
            }
        }
    }

    pub(crate) fn bi_jobs(&mut self) -> i32 {
        self.reap_jobs();
        let lines: Vec<String> = self
            .jobs
            .iter()
            .map(|j| {
                let state = if j.stopped { "Stopped" } else { "Running" };
                format!("[{}]  {}  {}", j.id, state, j.cmd)
            })
            .collect();
        let o = self.cur_out();
        for l in lines {
            self.write_fd(o, &l);
            self.write_fd(o, "\n");
        }
        0
    }

    pub(crate) fn bi_fg(&mut self, args: &[String]) -> i32 {
        let idx = match self.job_index(args.first().map(|s| s.as_str())) {
            Some(i) => i,
            None => {
                self.eprintln("fg: no current job");
                return 1;
            }
        };
        let pids = self.jobs[idx].pids.clone();
        let cmd = self.jobs[idx].cmd.clone();
        let o = self.cur_out();
        self.write_fd(o, &format!("{cmd}\n"));
        // Resume the job and bring it to the foreground.
        for &p in &pids {
            let _ = self.os.kill(p as i32, Signal::Cont);
        }
        self.jobs[idx].stopped = false;
        self.enter_foreground(&pids);
        let mut status = 0;
        let mut stopped = false;
        for &p in &pids {
            match self.wait_one(p) {
                FgWait::Exited(st) => status = st,
                FgWait::Stopped => {
                    stopped = true;
                    break;
                }
            }
        }
        self.leave_foreground();
        if stopped {
            self.jobs[idx].stopped = true;
            let id = self.jobs[idx].id;
            let o = self.cur_out();
            self.write_fd(o, &format!("\n[{id}]+  Stopped  {cmd}\n"));
            128 + Signal::Tstp as i32
        } else {
            self.jobs.remove(idx);
            self.reap_jobs();
            status
        }
    }

    pub(crate) fn bi_bg(&mut self, args: &[String]) -> i32 {
        let idx = match self.job_index(args.first().map(|s| s.as_str())) {
            Some(i) => i,
            None => {
                self.eprintln("bg: no current job");
                return 1;
            }
        };
        let pids = self.jobs[idx].pids.clone();
        for &p in &pids {
            let _ = self.os.kill(p as i32, Signal::Cont);
        }
        self.jobs[idx].stopped = false;
        let (id, cmd) = (self.jobs[idx].id, self.jobs[idx].cmd.clone());
        let o = self.cur_out();
        self.write_fd(o, &format!("[{id}]+ {cmd} &\n"));
        0
    }

    pub(crate) fn bi_wait(&mut self, _args: &[String]) -> i32 {
        let pids: Vec<Pid> = self.jobs.iter().flat_map(|j| j.pids.clone()).collect();
        let mut status = 0;
        for p in pids {
            status = self.os.waitpid(p).unwrap_or(0);
        }
        self.jobs.clear();
        status
    }

    // Carry-both core set: the twin of `/bin/kill` (programs/), which is pid-based.
    // This builtin ADDITIONALLY resolves `%jobspec` against the job table. The signal
    // names/numbers come from the contract (`parse_signal` → `os::Signal`, rooted in
    // //contracts:constants_rust), so both stay in step with the `mc` ABI.
    pub(crate) fn bi_kill(&mut self, args: &[String]) -> i32 {
        let mut sig = Signal::Term;
        let mut i = 0;
        if let Some(first) = args.first() {
            if let Some(name) = first.strip_prefix('-') {
                match parse_signal(name) {
                    Some(s) => sig = s,
                    None => {
                        self.eprintln(&format!("kill: {first}: invalid signal"));
                        return 1;
                    }
                }
                i = 1;
            }
        }
        if args.len() <= i {
            self.eprintln("kill: usage: kill [-SIG] pid | %job ...");
            return 1;
        }
        let mut rc = 0;
        for t in &args[i..] {
            if t.starts_with('%') {
                // Job spec: signal the job's process group. A wrapper such as
                // `nohup` may spawn children after the shell recorded the job;
                // those descendants inherit the group even though they are not
                // present in `Job::pids`.
                match self.job_index(Some(t)) {
                    Some(idx) => {
                        let pgid = self.jobs[idx].pids.first().copied().unwrap_or(0);
                        if pgid == 0 || self.os.kill(-(pgid as i32), sig).is_err() {
                            rc = 1;
                        }
                    }
                    None => {
                        self.eprintln(&format!("kill: {t}: no such job"));
                        rc = 1;
                    }
                }
            } else if let Ok(pid) = t.parse::<i32>() {
                if self.os.kill(pid, sig).is_err() {
                    rc = 1;
                }
            } else {
                self.eprintln(&format!("kill: {t}: arguments must be process or job IDs"));
                rc = 1;
            }
        }
        rc
    }
}

fn parse_signal(name: &str) -> Option<Signal> {
    let n = name.trim_start_matches("SIG");
    Some(match n {
        "HUP" | "1" => Signal::Hup,
        "INT" | "2" => Signal::Int,
        "KILL" | "9" => Signal::Kill,
        "TERM" | "15" => Signal::Term,
        "CONT" | "18" => Signal::Cont,
        // SIGSTOP (19) is uncatchable in POSIX; this VM only models the
        // terminal stop (TSTP, 20), so `-STOP` maps to it.
        "STOP" | "TSTP" | "19" | "20" => Signal::Tstp,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::parse_signal;
    use crate::os::Signal;

    // `parse_signal` is pure (string → Signal), so it is unit-tested directly;
    // the rest of job control touches the OS and is covered end-to-end.
    #[test]
    fn parse_signal_names_numbers_and_sig_prefix() {
        assert_eq!(parse_signal("INT"), Some(Signal::Int));
        assert_eq!(parse_signal("SIGINT"), Some(Signal::Int));
        assert_eq!(parse_signal("2"), Some(Signal::Int));
        assert_eq!(parse_signal("TERM"), Some(Signal::Term));
        assert_eq!(parse_signal("KILL"), Some(Signal::Kill));
        assert_eq!(parse_signal("9"), Some(Signal::Kill));
        assert_eq!(parse_signal("CONT"), Some(Signal::Cont));
        assert_eq!(parse_signal("HUP"), Some(Signal::Hup));
        // SIGSTOP (uncatchable) folds onto the terminal stop this VM models.
        assert_eq!(parse_signal("STOP"), Some(Signal::Tstp));
        assert_eq!(parse_signal("TSTP"), Some(Signal::Tstp));
        assert_eq!(parse_signal("BOGUS"), None);
    }
}
