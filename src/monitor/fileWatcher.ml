(**
 * Copyright (c) 2018-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Logger = FlowServerMonitorLogger

exception FileWatcherDied of exn

(* TODO - Push-based API for dfind. While the FileWatcher API is push based, dfind is faking it
 * by polling every seconds.
 *
 * If we decide we care about this, we could Build DfindServerLwt which can listen for events and
 * write messages at the same time (we don't want to block the file watching if the writes block)
 *)
class type watcher =
  object
    method name: string
    method start_init: unit
    method wait_for_init: unit Lwt.t
    method get_and_clear_changed_files: (SSet.t * MonitorProt.file_watcher_metadata option) Lwt.t
    method wait_for_changed_files: unit Lwt.t
    method stop: unit Lwt.t
    method waitpid: Unix.process_status Lwt.t
    method getpid: int option
  end

class dummy : watcher = object
  method name = "dummy"
  method start_init = ()
  method wait_for_init = Lwt.return_unit
  method get_and_clear_changed_files = Lwt.return (SSet.empty, None)
  method wait_for_changed_files = Lwt.return_unit
  method stop = Lwt.return_unit
  method waitpid = let wait_forever_thread, _ = Lwt.task () in wait_forever_thread
  method getpid = None
end

class dfind (monitor_options: FlowServerMonitorOptions.t) : watcher =
  object (self)
    val mutable dfind_instance = None
    val mutable files = SSet.empty

    method name = "dfind"

    method private get_dfind =
      match dfind_instance with
      | None -> failwith "Dfind was not initialized"
      | Some dfind -> dfind

    method start_init =
      let file_options =
        Options.file_options monitor_options.FlowServerMonitorOptions.server_options
      in
      let watch_paths = Files.watched_paths file_options in
      let null_fd = Daemon.null_fd () in
      let fds = (null_fd, null_fd, null_fd) in
      let dfind = DfindLibLwt.init fds ("flow_server_events", watch_paths) in
      dfind_instance <- Some dfind

    method wait_for_init =
      DfindLibLwt.wait_until_ready (self#get_dfind)

    (* We don't want two threads to talk to dfind at the same time. And we don't want those two
     * threads to get the same file change events *)
    val dfind_mutex = Lwt_mutex.create ()
    method private fetch =
      Lwt_mutex.with_lock dfind_mutex (fun () ->
        let dfind = self#get_dfind in
        try%lwt
          let%lwt new_files = DfindLibLwt.get_changes dfind in
          files <- SSet.union files new_files;
          Lwt.return_unit
        with
        | Sys_error msg as exn when msg = "Broken pipe" -> raise (FileWatcherDied exn)
        | End_of_file
        | Unix.Unix_error (Unix.EPIPE, _, _) as exn -> raise (FileWatcherDied exn)
      )

    method get_and_clear_changed_files =
      let%lwt () = self#fetch in
      let ret = files, None in
      files <- SSet.empty;
      Lwt.return ret

    method wait_for_changed_files =
      let%lwt () = self#fetch in
      if not (SSet.is_empty files)
      then Lwt.return_unit
      else
        let%lwt () = Lwt_unix.sleep 1.0 in
        self#wait_for_changed_files

    method stop =
      let dfind = self#get_dfind in
      let pid = DfindLibLwt.pid dfind in
      DfindLibLwt.stop dfind;
      dfind_instance <- None;
      (* Reap the killed process *)
      let%lwt _ = LwtSysUtils.blocking_waitpid pid in
      Lwt.return_unit

    method waitpid =
      let dfind = self#get_dfind in
      let pid = DfindLibLwt.pid dfind in
      let%lwt (_, status) = LwtSysUtils.blocking_waitpid pid in
      Lwt.return status

    method getpid =
      let dfind = self#get_dfind in
      Some (DfindLibLwt.pid dfind)
  end

module WatchmanFileWatcher : sig
  class watchman : FlowServerMonitorOptions.t -> watcher
end = struct
  (* We need to keep track of when hg transactions start and end. It's generally unsafe to read the
   * state of the repo in the middle of a transaction, so we often need to avoid reading scm info
   * until all transactions are done *)
  module HgTransaction: sig
    type t
    val empty: t
    val enter: t -> t
    val leave: t -> t Lwt.t
    val register_callback: t -> (unit -> unit Lwt.t) -> t Lwt.t
  end = struct
    type t = {
      count: int;
      callbacks: (unit -> unit Lwt.t) list
    }

    let empty = { count = 0; callbacks = []; }

    let enter t =
      { t with count = t.count + 1 }

    let leave t =
      let t = { t with count = t.count - 1; } in
      if t.count = 0
      then
        let%lwt () = Lwt_list.iter_s (fun f -> f ()) (List.rev t.callbacks) in
        Lwt.return { t with callbacks = []; }
      else
        Lwt.return t

    let register_callback t f =
      if t.count = 0
      then
        let%lwt () = f () in
        Lwt.return t
      else
        Lwt.return { t with callbacks = f :: t.callbacks }
  end


  type env = {
    mutable instance: Watchman_lwt.watchman_instance;
    mutable files: SSet.t;
    mutable metadata: MonitorProt.file_watcher_metadata;
    mutable mergebase: string option;
    mutable hg_transactions: HgTransaction.t;
    listening_thread: unit Lwt.t;
    changes_condition: unit Lwt_condition.t;
    init_settings: Watchman_lwt.init_settings;
    should_track_mergebase: bool;
  }

  let get_mergebase env =
    if env.should_track_mergebase
    then
      Watchman_lwt.with_instance env.instance
        ~try_to_restart:true
        ~on_alive:(fun watchman_env ->
          env.instance <- Watchman_lwt.Watchman_alive watchman_env;
          let%lwt mergebase = Watchman_lwt.get_mergebase watchman_env in
          Lwt.return (Some mergebase)
        )
        ~on_dead:(fun dead_env ->
          env.instance <- Watchman_lwt.Watchman_dead dead_env;
          failwith "Failed to connect to Watchman to get mergebase"
        )
    else Lwt.return_none

  module WatchmanListenLoop = LwtLoop.Make(struct
    module J = Hh_json_helpers.AdhocJsonHelpers

    type acc = env

    let extract_hg_update_metadata = function
    | None -> "<UNKNOWN>", "<UNKNOWN REV>"
    | Some metadata ->
      let distance = J.get_number_val "distance" ~default:"<UNKNOWN>" metadata in
      let rev = J.get_string_val "rev" ~default:"<UNKNOWN REV>" metadata in
      distance, rev

    let broadcast env =
      if not (SSet.is_empty env.files)
      then Lwt_condition.broadcast env.changes_condition ()

    let main env =
      let deadline = Unix.time () +. 604800. in
      let%lwt instance, result = Watchman_lwt.get_changes ~deadline env.instance in
      env.instance <- instance;
      begin match result with
      | Watchman_lwt.Watchman_pushed pushed_changes ->
        begin match pushed_changes with
        | Watchman_lwt.Files_changed new_files ->
          env.files <- SSet.union env.files new_files;
          broadcast env;
          Lwt.return env
        | Watchman_lwt.State_enter (name, metadata) ->
          (match name with
          | "hg.update" ->
            let distance, rev = extract_hg_update_metadata metadata in
            Logger.info
              "Watchman reports an hg.update just started. Moving %s revs from %s" distance rev
          | "hg.transaction" ->
            env.hg_transactions <- HgTransaction.enter env.hg_transactions
          | _ -> ());
          Lwt.return env
        | Watchman_lwt.State_leave (name, metadata) ->
          (match name with
          | "hg.update" ->
            let distance, rev = extract_hg_update_metadata metadata in
            env.metadata <- MonitorProt.({ env.metadata with
              total_update_distance = env.metadata.total_update_distance + (int_of_string distance);
            });
            Logger.info
              "Watchman reports an hg.update just finished. Moved %s revs to %s" distance rev;

            let old_mergebase = env.mergebase in

            let%lwt hg_trans = HgTransaction.register_callback env.hg_transactions @@ fun () ->
              (* If the mergebase has changed for some reason before this callback runs, then
               * don't run this callback. For example, I could imagine multiple hg.update's inside a
               * single transaction queueing up multiple callbacks. *)
              if env.mergebase <> old_mergebase
              then Lwt.return_unit
              else begin
                let%lwt new_mergebase = get_mergebase env in
                match new_mergebase, old_mergebase with
                | (Some new_mergebase), (Some old_mergebase) when new_mergebase <> old_mergebase ->
                  Logger.info
                    "Watchman reports mergebase changed from %S to %S"
                    old_mergebase
                    new_mergebase;
                  env.mergebase <- Some new_mergebase;
                  env.metadata <- { env.metadata with MonitorProt.changed_mergebase = true; };
                  Lwt.return_unit
                | _ -> Lwt.return_unit
              end
            in
            env.hg_transactions <- hg_trans;
            Lwt.return env
          | "hg.transaction" ->
            let%lwt hg_trans = HgTransaction.leave env.hg_transactions in
            env.hg_transactions <- hg_trans;
            Lwt.return env
          | _ -> Lwt.return env)
        | Watchman_lwt.Changed_merge_base _ ->
          failwith "We're not using an scm aware subscription, so we should never get these"
        end
      | Watchman_lwt.Watchman_synchronous _ ->
        failwith "Flow should never use the synchronous watchman API"
      | Watchman_lwt.Watchman_unavailable ->
        (* TODO (glevi) - Should we die if we get this for too long? *)
        Logger.error "Watchman unavailable. Retrying...";
        (* Watchman_lwt.get_changes will restart the connection. However it has some backoff
         * built in and will do nothing if called too early. That turns this LwtLoop module into a
         * busy wait. So let's add a sleep here to yield and prevent spamming the logs too much. *)
        let%lwt () = Lwt_unix.sleep 1.0 in
        Lwt.return env
      end

    external reraise : exn -> 'a = "%reraise"

    let catch _ exn =
      Logger.error ~exn "Uncaught exception in Watchman listening loop";
      reraise exn
  end)

  class watchman (monitor_options: FlowServerMonitorOptions.t) : watcher =
    object (self)
      val mutable env = None
      val mutable init_thread = None
      val mutable init_settings = None

      method name = "watchman"

      method private get_env =
        match env with
        | None -> failwith "Watchman was not initialized"
        | Some env -> env

      method start_init =
        let { FlowServerMonitorOptions.server_options; file_watcher_debug; _} =
            monitor_options in
        let file_options = Options.file_options server_options in

        let watchman_expression_terms = Watchman_expression_terms.make ~options:server_options in

        let settings = {
          (* Defer updates during `hg.update` *)
          Watchman_lwt.subscribe_mode = Some Watchman_lwt.Defer_changes;
          (* Hack makes this configurable in their local config. Apparently buck & hgwatchman also
           * use 10 seconds *)
          init_timeout = 10;
          expression_terms = watchman_expression_terms;
          subscription_prefix = "flow_watcher";
          roots = Files.watched_paths file_options;
          debug_logging = file_watcher_debug;
        } in

        init_settings <- Some settings;

        init_thread <- Some (Watchman_lwt.init settings ())

      method wait_for_init =
        let%lwt watchman = Option.value_exn init_thread in
        init_thread <- None;

        let should_track_mergebase =
          let server_options = monitor_options.FlowServerMonitorOptions.server_options in
          Options.lazy_mode server_options = Some Options.LAZY_MODE_WATCHMAN
        in

        match watchman with
        | Some watchman ->
          let waiter, wakener = Lwt.task () in
          let new_env = {
            instance = Watchman_lwt.Watchman_alive watchman;
            files = SSet.empty;
            listening_thread = (let%lwt env = waiter in WatchmanListenLoop.run env);
            mergebase = None;
            hg_transactions = HgTransaction.empty;
            changes_condition = Lwt_condition.create ();
            metadata = MonitorProt.empty_file_watcher_metadata;
            init_settings = Option.value_exn init_settings;
            should_track_mergebase;
          } in
          let%lwt mergebase = get_mergebase new_env in
          Option.iter mergebase ~f:(Logger.info "Watchman reports the initial mergebase as %S");
          let new_env = { new_env with mergebase; } in
          env <- Some new_env;
          Lwt.wakeup wakener new_env;
          Lwt.return_unit
        | None ->
          failwith "Failed to initialize watchman"

      (* Should we throw away metadata even if files is empty? glevi thinks that's fine, since we
       * probably don't care about hg updates or mergebase changing if no files were affected *)
      method get_and_clear_changed_files =
        let env = self#get_env in
        let ret = env.files, Some env.metadata in
        env.files <- SSet.empty;
        env.metadata <- MonitorProt.empty_file_watcher_metadata;
        Lwt.return ret

      method wait_for_changed_files =
        let env = self#get_env in
        Lwt_condition.wait env.changes_condition

      method stop =
        (* Flow doesn't own the watchman process, so it's not Flow's job to stop the watchman
         * process. What we can do, though, is stop listening to the messages *)
        let env = self#get_env in
        Logger.info "Canceling Watchman listening thread & closing connection";
        Lwt.cancel env.listening_thread;
        Watchman_lwt.with_instance env.instance
          ~try_to_restart:false
          ~on_alive:Watchman_lwt.close
          ~on_dead:(fun _ -> Lwt.return_unit)

      method waitpid =
        (* If watchman dies, we can start it back up again and use clockspec to make sure we didn't
         * miss anything. So from the point of view of the FileWatcher abstraction, watchman never
         * dies and this method can just wait forever *)
        let waiter, _ = Lwt.task () in
        waiter

      method getpid = None
    end

end

class watchman = WatchmanFileWatcher.watchman
