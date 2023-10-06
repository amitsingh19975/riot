[@@@warning "-32"]

module Proc_state = Proc_state
module Logs = Logs

(** Uid Modules *)

module Scheduler_uid = struct
  type t = int

  let __current__ = Atomic.make 0
  let next () = Atomic.fetch_and_add __current__ 1

  let reset () =
    Logs.debug (fun f -> f "Resetting Scheduler Uids");
    Atomic.set __current__ 0
end

module Pid = struct
  type t = int

  let zero : t = 0
  let __current__ = Atomic.make 0
  let next () = Atomic.fetch_and_add __current__ 1
  let equal a b = Int.equal a b
  let pp ppf pid = Format.fprintf ppf "<0.%d.0>" pid

  let reset () =
    Logs.debug (fun f -> f "Resetting Process Ids");
    Atomic.set __current__ 0
end

module Message = struct
  type select_marker = Take | Skip
  type monitor = Process_down of Pid.t
  type t = ..
  type t += Exit_signal | Monitor of monitor
end

module Mailbox = struct
  type t = { size : int Atomic.t; queue : Message.t Lf_queue.t }

  let create () = { size = Atomic.make 0; queue = Lf_queue.create () }

  let queue t msg =
    Atomic.incr t.size;
    Lf_queue.add msg t.queue

  let next (t : t) =
    Atomic.decr t.size;
    Lf_queue.take_opt t.queue

  let is_empty (t : t) = Lf_queue.is_empty t.queue
  let merge (a : t) (b : t) = Lf_queue.merge a.queue b.queue
  let size (t : t) = Atomic.get t.size
end

(** Process *)

type state =
  | Runnable
  | Waiting
  | Running
  | Exited of (exit_reason, exn) result

and process = {
  pid : Pid.t;
  state : state Atomic.t;
  mutable cont : exit_reason Proc_state.t;
  mailbox : Mailbox.t;
  links : Pid.t list Atomic.t;
  monitors : Pid.t list Atomic.t;
}
(** ['msg process] an internal process descriptor. Represents a process in the runtime. *)

(** [exit_reason] indicates why a process was terminated. *)
and exit_reason =
  | Normal
  | Exit_signal
  | Timeout_value
  | Bad_link
  | Exception of exn

(** [signal]s are used to communicate to a process that a given action needs to be performed by it. They are low-level primitives used by the runtime. *)
and signal = Link | Unlink | Exit | Monitor | Demonitor | Message

(** Effects *)

[@@@warning "-30"]

type _ Effect.t +=
  | Receive : {
      select : Message.t -> Message.select_marker;
    }
      -> Message.t Effect.t
  | Yield : unit Effect.t

let pp_effect : type a. Format.formatter -> a Effect.t -> unit =
 fun ppf eff ->
  match eff with
  | Receive _ -> Format.fprintf ppf "Receive"
  | Yield -> Format.fprintf ppf "Yield"
  | _effect -> Format.fprintf ppf "Unhandled effect"

module Process = struct
  type t = process

  module Pid = Pid

  let cont t = t.cont
  let set_cont c t = t.cont <- c
  let state t = Atomic.get t.state

  let is_alive t =
    match Atomic.get t.state with
    | Runnable | Waiting | Running -> true
    | Exited _ -> false

  let mark_as_running t = Atomic.set t.state Running
  let mark_as_dead t reason = Atomic.set t.state (Exited reason)
  let mark_as_awaiting_message t = Atomic.set t.state Waiting
  let mark_as_runnable t = Atomic.set t.state Runnable
  let add_link t pid = Atomic.set t.links (pid :: Atomic.get t.links)

  let make fn =
    let cont = Proc_state.make fn Yield in
    let pid = Pid.next () in
    Logs.debug (fun f -> f "Making process with pid: %a" Pid.pp pid);
    {
      pid;
      cont;
      state = Atomic.make Runnable;
      links = Atomic.make [];
      monitors = Atomic.make [];
      mailbox = Mailbox.create ();
    }
end

module Process_table = struct
  type t = { processes : (Pid.t, Process.t) Hashtbl.t; lock : Mutex.t }

  let create () = { lock = Mutex.create (); processes = Hashtbl.create 16_000 }

  let register_process t proc =
    Mutex.lock t.lock;
    Hashtbl.add t.processes proc.pid proc;
    Mutex.unlock t.lock

  let get t pid = Hashtbl.find_opt t.processes pid
  let process_count t = Hashtbl.length t.processes
  let processes t = Hashtbl.to_seq t.processes
end

(** Scheduler *)

type scheduler = {
  uid : Scheduler_uid.t; [@warning "-69"]
  rnd : Random.State.t;
  ready_queue : process Lf_queue.t;
}

type pool = {
  mutable stop : bool;
  schedulers : scheduler list;
  processes : Process_table.t;
}

let pp_process ppf t = Format.fprintf ppf "pid=%a" Pid.pp t.pid

module Thread_local = struct
  exception Uninitialized_thread_local of string

  let make ~name =
    let value = Atomic.make None in
    let key = Domain.DLS.new_key (fun () -> Atomic.get value) in
    let get () =
      match Domain.DLS.get key with
      | Some x -> x
      | None -> raise (Uninitialized_thread_local name)
    in
    let set x = Domain.DLS.set key (Some x) in
    (get, set)
end

module Scheduler = struct
  module Uid = Scheduler_uid

  let make ~rnd () =
    let uid = Uid.next () in
    Logs.debug (fun f -> f "Making scheduler with id: %d" uid);
    { uid; rnd = Random.State.copy rnd; ready_queue = Lf_queue.create () }

  let get_current_scheduler, set_current_scheduler =
    Thread_local.make ~name:"CURRENT_SCHEDULER"

  let get_current_process_pid, set_current_process_pid =
    Thread_local.make ~name:"CURRENT_PID"

  let get_random_scheduler : pool -> scheduler =
   fun pool ->
    let scheduler = get_current_scheduler () in
    let all_schedulers = pool.schedulers in
    let rnd_idx = Random.State.int scheduler.rnd (List.length all_schedulers) in
    List.nth all_schedulers rnd_idx

  let perform _scheduler process =
    let open Proc_state in
    let perform : type a b. (a, b) step_callback =
     fun k eff ->
      Logs.debug (fun f -> f "performing effect: %a" pp_effect eff);
      match eff with
      | Yield -> k Yield
      (* NOTE(leostera): the selective receive algorithm goes:

         * is there a new message?
           -> no: reperform – we will essentially be blocked here until we
                  either receive a message or we timeout (if a timeout is set)
           -> yes: check if we should take the message
              -> take: return the message and continue
              -> skip: put the message on a temporary skip queue
         * loop until the mailbox is
      *)
      | Receive { select } as effect ->
          if Mailbox.is_empty process.mailbox then (
            Logs.debug (fun f ->
                f "%a is awaiting for new messages" Pid.pp process.pid);
            Process.mark_as_awaiting_message process;
            k (Delay effect))
          else
            let skipped = Mailbox.create () in
            let rec go () =
              (* NOTE(leostera): we can get the value out of the option because
                 the case above checks for an empty mailbox. *)
              match Mailbox.next process.mailbox with
              | None ->
                  Mailbox.merge process.mailbox skipped;
                  k (Delay effect)
              | Some msg -> (
                  match select msg with
                  | Take -> k (Continue msg)
                  | Skip ->
                      Mailbox.queue skipped msg;
                      go ())
            in
            go ()
      | effect -> k (Reperform effect)
    in
    { perform }

  let step_process pool scheduler proc =
    set_current_process_pid proc.pid;
    match Process.state proc with
    | Waiting -> Lf_queue.add proc scheduler.ready_queue
    | Exited _ ->
        (* send monitors a process-down message *)
        let monitoring_pids = Atomic.get proc.monitors in
        List.iter
          (fun pid ->
            match Process_table.get pool.processes pid with
            | None -> ()
            | Some mon_proc ->
                Logs.debug (fun f ->
                    f "notified %a of %a terminating" Pid.pp pid Pid.pp proc.pid);
                Mailbox.queue mon_proc.mailbox
                  Message.(Monitor (Process_down proc.pid));
                Process.mark_as_runnable mon_proc)
          monitoring_pids;

        (* mark linked processes as dead *)
        let linked_pids = Atomic.get proc.links in
        Logs.debug (fun f ->
            f "terminating %d processes linked to %a" (List.length linked_pids)
              Pid.pp proc.pid);
        List.iter
          (fun pid ->
            match Process_table.get pool.processes pid with
            | None -> ()
            | Some linked_proc ->
                Logs.debug (fun f ->
                    f "marking linked %a as dead" Pid.pp linked_proc.pid);
                Process.mark_as_dead linked_proc (Ok Exit_signal))
          linked_pids
    | Running | Runnable -> (
        Process.mark_as_running proc;
        let perform = perform scheduler proc in
        let cont = Proc_state.run ~perform (Process.cont proc) in
        Process.set_cont cont proc;
        match cont with
        | Proc_state.Finished reason ->
            Process.mark_as_dead proc reason;
            Lf_queue.add proc scheduler.ready_queue
        | Proc_state.Suspended _ | Proc_state.Unhandled _ ->
            Lf_queue.add proc scheduler.ready_queue)

  let is_idle t = Lf_queue.is_empty t.ready_queue

  let run pool scheduler () =
    Logs.debug (fun f -> f "> enter worker loop");
    let exception Exit in
    (try
       while true do
         Domain.cpu_relax ();
         if pool.stop then raise_notrace Exit;
         match Lf_queue.take_opt scheduler.ready_queue with
         | None ->
             Logs.debug (fun f -> f "no ready processes");
             ()
         | Some proc ->
             Logs.debug (fun f -> f "found process: %a" pp_process proc);
             step_process pool scheduler proc;
             ()
       done
     with Exit -> ());
    Logs.debug (fun f -> f "< exit worker loop")
end

(** handles spinning up several schedulers and synchronizing the shutdown *)
module Pool = struct
  let get_pool, set_pool = Thread_local.make ~name:"POOL"
  let shutdown pool = pool.stop <- true

  let make ?(rnd = Random.State.make_self_init ()) ~domains ~main () =
    Logs.debug (fun f -> f "Making scheduler pool...");
    let schedulers = List.init domains @@ fun _ -> Scheduler.make ~rnd () in
    let pool =
      {
        stop = false;
        schedulers = [ main ] @ schedulers;
        processes = Process_table.create ();
      }
    in
    let spawn scheduler =
      Stdlib.Domain.spawn (fun () ->
          set_pool pool;
          Scheduler.run pool scheduler ())
    in
    Logs.debug (fun f -> f "Created %d schedulers" (List.length schedulers));
    (pool, List.map spawn schedulers)
end

(** Public API *)

let yield () = Effect.perform Yield
let self () = Scheduler.get_current_process_pid ()

let exit pid reason =
  let pool = Pool.get_pool () in
  match Process_table.get pool.processes pid with
  | Some proc -> Process.mark_as_dead proc (Ok reason)
  | None -> ()

(* NOTE(leostera): to send a message, we will find the receiver process
   in the process table and queue at the back of their mailbox
*)
let send pid msg =
  let pool = Pool.get_pool () in
  match Process_table.get pool.processes pid with
  | Some proc ->
      Logs.debug (fun f ->
          f "delivering message meant for %a to %a" Pid.pp pid Pid.pp proc.pid);
      Mailbox.queue proc.mailbox msg;
      Process.mark_as_runnable proc
  | None ->
      (* Effect.perform (Send (msg, pid)) *)
      Logs.debug (fun f -> f "COULD NOT DELIVER message to %a" Pid.pp pid)

let _spawn pool scheduler fn =
  let proc =
    Process.make (fun () ->
        try
          fn ();
          Normal
        with exn ->
          Logs.debug (fun f ->
              f "Process %a died with exception %s:\n%s" Pid.pp (self ())
                (Printexc.to_string exn)
                (Printexc.get_backtrace ()));
          Exception exn)
  in
  Process_table.register_process pool.processes proc;
  Lf_queue.add proc scheduler.ready_queue;
  proc.pid

let spawn fn =
  let pool = Pool.get_pool () in
  let scheduler = Scheduler.get_random_scheduler pool in
  _spawn pool scheduler fn

exception Link_no_process of Pid.t

let link pid =
  let this = self () in
  Logs.debug (fun f -> f "linking %a <-> %a" Pid.pp this Pid.pp pid);
  let pool = Pool.get_pool () in
  (match Process_table.get pool.processes this with
  | Some proc -> Process.add_link proc pid
  | None -> ());
  match Process_table.get pool.processes pid with
  | Some proc ->
      if Process.is_alive proc then Process.add_link proc this
      else raise (Link_no_process pid)
  | None -> ()

let rec monitor pid1 pid2 =
  let pool = Pool.get_pool () in
  match Process_table.get pool.processes pid2 with
  | Some proc ->
      let pids = Atomic.get proc.monitors in
      if Atomic.compare_and_set proc.monitors pids (pid1 :: pids) then ()
      else monitor pid1 pid2
  | None -> ()

let processes () =
  yield ();
  let pool = Pool.get_pool () in
  Process_table.processes pool.processes

let is_process_alive pid =
  yield ();
  let pool = Pool.get_pool () in
  match Process_table.get pool.processes pid with
  | Some proc -> Process.is_alive proc
  | None -> false

let random () = (Scheduler.get_current_scheduler ()).rnd

let receive ?(select = fun _ -> Message.Take) () =
  Effect.perform (Receive { select })

let shutdown () =
  let pool = Pool.get_pool () in
  Pool.shutdown pool

let run ?(rnd = Random.State.make_self_init ())
    ?(workers = max 0 (Stdlib.Domain.recommended_domain_count () - 1)) main =
  Logs.debug (fun f -> f "Initializing Riot runtime...");
  Process.Pid.reset ();
  Scheduler.Uid.reset ();

  let sch0 = Scheduler.make ~rnd () in
  let pool, domains = Pool.make ~main:sch0 ~domains:workers () in

  Scheduler.set_current_scheduler sch0;
  Pool.set_pool pool;

  let _pid = _spawn pool sch0 main in
  Scheduler.run pool sch0 ();

  Logs.debug (fun f -> f "Riot runtime shutting down...");
  List.iter Stdlib.Domain.join domains;
  Logs.debug (fun f -> f "Riot runtime shutdown");
  ()