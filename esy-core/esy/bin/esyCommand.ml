open Esy

module StringMap = Map.Make(String)
module StringSet = Set.Make(String)

let cwd = Sys.getcwd ()

(** This is set by bash script wrapper currently *)
let version =
  try Sys.getenv "ESY__VERSION"
  with Not_found -> "dev"

let concurrency =
  (** TODO: handle more platforms, right now this is tested only on macOS and
   * Linux *)
  let cmd = Bos.Cmd.(v "getconf" % "_NPROCESSORS_ONLN") in
  match Bos.OS.Cmd.(run_out cmd |> to_string) with
  | Ok out -> begin match out |> String.trim |> int_of_string_opt with
    | Some n -> n
    | None -> 1
    end
  | Error _ -> 1

let measureTime ~label f =
  let open RunAsync.Syntax in
  let s = Unix.gettimeofday () in
  let%bind res = f () in
  let e = Unix.gettimeofday () in
  let%lwt () = Logs_lwt.debug(fun m -> m "time spent %s: %f" label (e -. s)) in
  return res

let pathTerm =
  let open Cmdliner in
  let parse = Path.of_string in
  let print = Path.pp in
  Arg.conv ~docv:"PATH" (parse, print)

let resolvedPathTerm =
  let open Cmdliner in
  let parse v =
    match Path.of_string v with
    | Ok path ->
      if Path.is_abs path then
        Ok path
      else
        Ok Path.(v cwd // path |> normalize)
    | err -> err
  in
  let print = Path.pp in
  Arg.conv ~docv:"PATH" (parse, print)

let pkgPathTerm =
  let open Cmdliner in
  let doc = "Path to package." in
  Arg.(
    value
    & pos 0  (some resolvedPathTerm) None
    & info [] ~doc
  )

let configTerm =
  let open Cmdliner in
  let docs = Manpage.s_common_options in
  let prefixPath =
    let doc = "Specifies esy prefix path." in
    let env = Arg.env_var "ESY__PREFIX" ~doc in
    Arg.(
      value
      & opt (some pathTerm) None
      & info ["prefix-path"; "P"] ~env ~docs ~doc
    )
  in
  let sandboxPath =
    let doc = "Specifies esy sandbox path." in
    let env = Arg.env_var "ESY__SANDBOX" ~doc in
    Arg.(
      value
      & opt (some pathTerm) None
      & info ["sandbox-path"; "S"] ~env ~docs ~doc
    )
  in
  let parse prefixPath sandboxPath =
    Config.create ~esyVersion:version ~prefixPath sandboxPath
  in
  Term.(const(parse) $ prefixPath $ sandboxPath)

let setupLogTerm =
  let lwt_reporter () =
    let buf_fmt ~like =
      let b = Buffer.create 512 in
      Fmt.with_buffer ~like b,
      fun () -> let m = Buffer.contents b in Buffer.reset b; m
    in
    let app, app_flush = buf_fmt ~like:Fmt.stdout in
    let dst, dst_flush = buf_fmt ~like:Fmt.stderr in
    let reporter = Logs_fmt.reporter ~app ~dst () in
    let report src level ~over k msgf =
      let k () =
        let write () = match level with
        | Logs.App -> Lwt_io.write Lwt_io.stdout (app_flush ())
        | _ -> Lwt_io.write Lwt_io.stderr (dst_flush ())
        in
        let unblock () = over (); Lwt.return_unit in
        Lwt.finalize write unblock |> Lwt.ignore_result;
        k ()
      in
      reporter.Logs.report src level ~over:(fun () -> ()) k msgf;
    in
    { Logs.report = report }
  in
  let setupLog style_renderer level =
    let style_renderer = match style_renderer with
    | None -> `None
    | Some renderer -> renderer
    in
    Fmt_tty.setup_std_outputs ~style_renderer ();
    Logs.set_level level;
    Logs.set_reporter (lwt_reporter ())
  in
  let open Cmdliner in
  Term.(
    const setupLog
    $ Fmt_cli.style_renderer ()
    $ Logs_cli.level ~env:(Arg.env_var "ESY__LOG") ())

module SandboxInfo = struct

  open RunAsync.Syntax

  type t = {
    sandbox : Sandbox.t;
    task : BuildTask.t;
    commandEnv : Environment.Closed.t;
    sandboxEnv : Environment.Closed.t;
  }

  let cachePath (cfg : Config.t) =
    let hash = [
        Path.to_string cfg.storePath;
        Path.to_string cfg.localStorePath;
        Path.to_string cfg.sandboxPath;
        cfg.esyVersion
      ]
      |> String.concat "$$"
      |> Digest.string
      |> Digest.to_hex
    in
    let name = Printf.sprintf "sandbox-%s" hash in
    Path.(cfg.sandboxPath / "node_modules" / ".cache" / "_esy" / name)

  let writeCache (cfg : Config.t) (info : t) =
    let f () =
      let cachePath = cachePath cfg in
      let%bind () = Fs.createDirectory (Path.parent cachePath) in
      let f oc =
        let%lwt () = Lwt_io.write_value oc info in
        Lwt.return_ok ()
      in
      Lwt_io.with_file ~mode:Lwt_io.Output (Path.to_string cachePath) f
    in measureTime ~label:"writing sandbox info cache" f

  let readCache (cfg : Config.t) =
    let f () =
      let cachePath = cachePath cfg in
      let f ic =
        let%lwt info = (Lwt_io.read_value ic : t Lwt.t) in
        let%bind isStale =
          let checkMtime (path, mtime) =
            let%bind { Unix.st_mtime = curMtime; _ } = Fs.stat path in
            return (curMtime > mtime)
          in
          info.sandbox.manifestInfo
            |> List.map checkMtime
            |> RunAsync.joinAll
          in
        if List.exists (fun x -> x) isStale
        then return None
        else return (Some info)
      in
      try%lwt Lwt_io.with_file ~mode:Lwt_io.Input (Path.to_string cachePath) f
      with | Unix.Unix_error _ -> return None
    in measureTime ~label:"reading sandbox info cache" f

  let ofConfig (cfg : Config.t) =
    let makeInfo () =
      let f () =
        let%bind sandbox = Sandbox.ofDir cfg in
        let%bind task, commandEnv, sandboxEnv = RunAsync.liftOfRun (
          let open Run.Syntax in
          let%bind task = BuildTask.ofPackage sandbox.root in
          let%bind commandEnv = BuildTask.commandEnv sandbox.root in
          let%bind sandboxEnv = BuildTask.sandboxEnv sandbox.root in
          return (task, commandEnv, sandboxEnv)
        ) in
        return {task; sandbox; commandEnv; sandboxEnv}
      in measureTime ~label:"constructing sandbox info" f
    in
    match%bind readCache cfg with
    | Some info -> return info
    | None ->
      let%bind info = makeInfo () in
      let%bind () = writeCache cfg info in
      return info
end

let withPackageByPath
    ~(cfg : Config.t)
    ~(info : SandboxInfo.t)
    packagePath
    f =
  let open RunAsync.Syntax in
  match packagePath with
  | Some packagePath ->
    let findByPath (pkg : Package.t) =
      let sourcePath = Config.ConfigPath.toPath cfg pkg.sourcePath in
      Path.equal sourcePath packagePath
    in begin match Package.DependencyGraph.find ~f:findByPath info.sandbox.root with
    | None ->
      let msg = Printf.sprintf "No package found at %s" (Path.to_string packagePath) in
      error msg
    | Some pkg -> f pkg
    end
  | None -> f info.sandbox.root

let buildPlan cfg packagePath =
  let open RunAsync.Syntax in

  let%bind cfg = RunAsync.liftOfRun cfg in

  let f pkg =
    let%bind task = RunAsync.liftOfRun (BuildTask.ofPackage pkg) in
    return (
      BuildTask.toBuildProtocolString ~pretty:true task
      |> print_endline
    )
  in

  let%bind info = SandboxInfo.ofConfig cfg in
  withPackageByPath ~cfg ~info packagePath f

let buildShell cfg packagePath =
  let open RunAsync.Syntax in

  let%bind cfg = RunAsync.liftOfRun cfg in

  let f pkg =
    let%bind task = RunAsync.liftOfRun (BuildTask.ofPackage pkg) in
    let%bind () = Build.buildDependencies ~concurrency cfg task in
    PackageBuilder.buildShell cfg task
  in

  let%bind info = SandboxInfo.ofConfig cfg in
  withPackageByPath ~cfg ~info packagePath f

let buildPackage cfg packagePath =
  let open RunAsync.Syntax in

  let%bind cfg = RunAsync.liftOfRun cfg in

  let f pkg =
    let%bind task = RunAsync.liftOfRun (BuildTask.ofPackage pkg) in
    let%bind () = Build.buildDependencies ~concurrency cfg task in
    Build.build ~concurrency ~force:`Yes cfg task
  in

  let%bind info = SandboxInfo.ofConfig cfg in
  withPackageByPath ~cfg ~info packagePath f

let build ?(buildOnly=`ForRoot) cfg command =
  let open RunAsync.Syntax in
  let%bind cfg = RunAsync.liftOfRun cfg in
  let%bind {SandboxInfo. task; _} = SandboxInfo.ofConfig cfg in

  (** TODO: figure out API to build devDeps in parallel with the root *)

  match command with
  | [] ->
    Build.build ~concurrency ~force:`ForRoot ~buildOnly cfg task

  | command ->
    let%bind () = Build.buildDependencies ~concurrency cfg task in
    PackageBuilder.buildExec cfg task command

let makeEnvCommand ~computeEnv ~header cfg asJson packagePath =
  let open RunAsync.Syntax in

  let%bind cfg = RunAsync.liftOfRun cfg in

  let f (pkg : Package.t) =
    let%bind source = RunAsync.liftOfRun (
      let open Run.Syntax in
      let%bind env = computeEnv pkg in
      let header = header pkg in
      if asJson
      then
        let env = Environment.Closed.value env in
        let%bind env = Environment.Value.bindToConfig cfg env in
        Ok (
          env
          |> Environment.Value.to_yojson
          |> Yojson.Safe.pretty_to_string)
      else
        env
        |> Environment.Closed.bindings
        |> Environment.renderToShellSource ~header cfg
    ) in
    let%lwt () = Lwt_io.print source in
    return ()
  in

  let%bind info = SandboxInfo.ofConfig cfg in
  withPackageByPath ~cfg ~info packagePath f

let buildEnv =
  let header (pkg : Package.t) =
    Printf.sprintf "# Build environment for %s@%s" pkg.name pkg.version
  in
  makeEnvCommand ~computeEnv:BuildTask.buildEnv ~header

let commandEnv =
  let header (pkg : Package.t) =
    Printf.sprintf "# Command environment for %s@%s" pkg.name pkg.version
  in
  makeEnvCommand ~computeEnv:BuildTask.commandEnv ~header

let sandboxEnv =
  let header (pkg : Package.t) =
    Printf.sprintf "# Sandbox environment for %s@%s" pkg.name pkg.version
  in
  makeEnvCommand ~computeEnv:BuildTask.sandboxEnv ~header

let makeExecCommand
    ?(checkIfDependenciesAreBuilt=false)
    ?prepare
    ~env
    cfg
    command
    =
  let open RunAsync.Syntax in

  let%bind cfg = RunAsync.liftOfRun cfg in
  let%bind (info: SandboxInfo.t) = SandboxInfo.ofConfig cfg in

  let%bind () = match prepare with
  | None -> return ()
  | Some prepare -> prepare cfg info.sandbox.root
  in

  let%bind () =
    if checkIfDependenciesAreBuilt
    then Build.buildDependencies ~concurrency cfg info.task
    else return ()
  in

  let%bind envValue = RunAsync.liftOfRun (
    let env = match env with
    | `CommandEnv -> info.commandEnv
    | `SandboxEnv -> info.sandboxEnv
    in
    let env = Environment.Closed.value env in
    Environment.Value.bindToConfig cfg env
  ) in

  let%bind env = RunAsync.liftOfRun (
    Ok (
      envValue
      |> Environment.Value.M.bindings
      |> List.map (fun (name, value) -> Printf.sprintf "%s=%s" name value)
      |> Array.of_list)
  ) in

  let resolvePrg prg =
    let path =
      let v = match Environment.Value.M.find_opt "PATH" envValue with
      | Some v -> v
      | None -> ""
      in String.split_on_char ':' v
    in
    Run.liftOfBosError (Cmd.resolveCmd path prg)
  in

  let%bind command = RunAsync.liftOfRun (
    let open Run.Syntax in
    match command with
    | [] -> Run.error "empty command"
    | (prg::_) as entire ->
      let%bind prg = resolvePrg prg in
      Ok (prg, Array.of_list entire)
  ) in

  let waitForProcess process =
    let%lwt status = process#status in
    match status with
    | Unix.WEXITED 0 -> return ()
    | _ -> RunAsync.error "error running command"
  in

  Lwt_process.with_process_none
    ~env
    ~stderr:(`FD_copy Unix.stderr)
    ~stdout:(`FD_copy Unix.stdout)
    ~stdin:(`FD_copy Unix.stdin)
    command waitForProcess

let exec cfgRes =
  let open RunAsync.Syntax in
  let prepare cfg (pkg : Package.t) =
    let installPath =
      pkg
      |> BuildTask.pkgInstallPath
      |> Config.ConfigPath.toPath cfg
    in
    if%bind Fs.exists installPath then
      return ()
    else
      build ~buildOnly:`No cfgRes []
  in
  makeExecCommand
    ~prepare
    ~env:`SandboxEnv
    cfgRes

let devExec =
  makeExecCommand
    ~checkIfDependenciesAreBuilt:true
    ~env:`CommandEnv

let devShell cfg =
  let shell =
    try Sys.getenv "SHELL"
    with Not_found -> "/bin/bash"
  in
  makeExecCommand
    ~env:`CommandEnv
    cfg
    [shell]

let makeLsCommand ~computeLine ~includeTransitive cfg =
  let open RunAsync.Syntax in

  let%bind cfg = RunAsync.liftOfRun cfg in
  let%bind (info : SandboxInfo.t) = SandboxInfo.ofConfig cfg in

  let seen = ref StringSet.empty in

  let f ~foldDependencies (pkg : Package.t) =
    if StringSet.mem pkg.id !seen then
      return None
    else (
      seen := StringSet.add pkg.id !seen;
      let%bind children =
        if not includeTransitive && pkg.id <> info.sandbox.root.id then
          return []
        else
          foldDependencies ()
          |> List.map (fun (_, v) -> v)
          |> RunAsync.joinAll
      in
      let children =
        let f xs = function | Some x -> x::xs | None -> xs in
        children
        |> ListLabels.fold_left ~f ~init:[]
        |> List.rev
      in
      let%bind line = computeLine cfg pkg in
      return (Some (Esy.TermTree.Node { children; line; }))
    )
  in

  match%bind Package.DependencyGraph.fold ~f info.sandbox.root with
  | Some tree -> return (print_endline (Esy.TermTree.toString tree))
  | None -> return ()

let lsBuilds =
  let open RunAsync.Syntax in
  let computeLine cfg (pkg : Package.t) =
    let%bind built =
      BuildTask.pkgInstallPath pkg
      |> Config.ConfigPath.toPath cfg
      |> Fs.exists
    in
    let status = match pkg.sourceType, built with
    | Esy.Package.SourceType.Immutable, true -> "[built]"
    | Esy.Package.SourceType.Immutable, false
    | _, _  -> "[build pending]"
    in
    let line = Printf.sprintf "%s@%s %s" pkg.name pkg.version status in
    return line
  in
  makeLsCommand ~computeLine

let () =
  let open Cmdliner in

  (** Prelude *)

  let exits = Term.default_exits in
  let sdocs = Manpage.s_common_options in
  (** CLI helpers *)

  let runCommand (cmd : unit Run.t) =
    match cmd with
    | Ok () -> `Ok ()
    | Error error ->
      let msg = Run.formatError error in
      let msg = Printf.sprintf "error, exiting...\n%s" msg in
      `Error (false, msg)
  in

  let runAsyncCommand ?(header=`Standard) (info : Cmdliner.Term.info) (cmd : unit RunAsync.t) =
    let work () =
      let%lwt () = match header with
      | `Standard -> begin match Cmdliner.Term.name info with
        | "esy" -> Logs_lwt.app (fun m -> m "esy %s" version)
        | name -> Logs_lwt.app (fun m -> m "esy %s %s" name version);
        end
      | `No -> Lwt.return ()
      in
      cmd
    in
    work () |> Lwt_main.run |> runCommand
  in

  (** Commands *)

  let defaultCommand =
    let doc = "package.json workflow for native development with Reason/OCaml" in
    let info = Term.info "esy" ~version ~doc ~sdocs ~exits in
    let cmd cfg command () =
      runAsyncCommand ~header:`No info (devExec cfg command)
    in
    let commandTerm =
      Arg.(non_empty & (pos_all string []) & (info [] ~docv:"COMMAND"))
    in
    Term.(ret (const cmd $ configTerm $ commandTerm $ setupLogTerm)), info
  in

  let buildPlanCommand =
    let doc = "Print build plan to stdout" in
    let info = Term.info "build-plan" ~version ~doc ~sdocs ~exits in
    let cmd cfg packagePath () =
      runAsyncCommand ~header:`No info (buildPlan cfg packagePath)
    in
    Term.(ret (const cmd $ configTerm $ pkgPathTerm $ setupLogTerm)), info
  in

  let buildShellCommand =
    let doc = "Enter the build shell" in
    let info = Term.info "build-shell" ~version ~doc ~sdocs ~exits in
    let cmd cfg packagePath () =
      runAsyncCommand info (buildShell cfg packagePath)
    in
    Term.(ret (const cmd $ configTerm $ pkgPathTerm $ setupLogTerm)), info
  in

  let buildPackageCommand =
    let doc = "Build specified package" in
    let info = Term.info "build-package" ~version ~doc ~sdocs ~exits in
    let cmd cfg packagePath () =
      runAsyncCommand info (buildPackage cfg packagePath)
    in
    Term.(ret (const cmd $ configTerm $ pkgPathTerm $ setupLogTerm)), info
  in

  let buildCommand =
    let doc = "Build entire sandbox" in
    let info = Term.info "build" ~version ~doc ~sdocs ~exits in
    let cmd cfg command () =
      let header = match command with
      | [] -> `Standard
      | _ -> `No
      in
      runAsyncCommand ~header info (build cfg command)
    in
    let commandTerm =
      Arg.(value & (pos_all string []) & (info [] ~docv:"COMMAND"))
    in
    Term.(ret (const cmd $ configTerm $ commandTerm $ setupLogTerm)), info
  in

  let buildEnvCommand =
    let doc = "Print build environment to stdout" in
    let info = Term.info "build-env" ~version ~doc ~sdocs ~exits in
    let cmd cfg asJson packagePath () =
      runAsyncCommand ~header:`No info (buildEnv cfg asJson packagePath)
    in
    let json =
      let doc = "Format output as JSON" in
      Arg.(value & flag & info ["json"]  ~doc);
    in
    Term.(ret (const cmd $ configTerm $ json $ pkgPathTerm $ setupLogTerm)), info
  in

  let commandEnvCommand =
    let doc = "Print command environment to stdout" in
    let info = Term.info "command-env" ~version ~doc ~sdocs ~exits in
    let cmd cfg asJson packagePath () =
      runAsyncCommand ~header:`No info (commandEnv cfg asJson packagePath)
    in
    let json =
      let doc = "Format output as JSON" in
      Arg.(value & flag & info ["json"]  ~doc);
    in
    Term.(ret (const cmd $ configTerm $ json $ pkgPathTerm $ setupLogTerm)), info
  in

  let sandboxEnvCommand =
    let doc = "Print install environment to stdout" in
    let info = Term.info "sandbox-env" ~version ~doc ~sdocs ~exits in
    let cmd cfg asJson packagePath () =
      runAsyncCommand ~header:`No info (sandboxEnv cfg asJson packagePath)
    in
    let json =
      let doc = "Format output as JSON" in
      Arg.(value & flag & info ["json"]  ~doc);
    in
    Term.(ret (const cmd $ configTerm $ json $ pkgPathTerm $ setupLogTerm)), info
  in

  let execCommand =
    let doc = "Execute command as if the package is installed" in
    let info = Term.info "x" ~version ~doc ~sdocs ~exits in
    let cmd cfg command () =
      runAsyncCommand ~header:`No info (exec cfg command)
    in
    let commandTerm =
      Arg.(non_empty & (pos_all string []) & (info [] ~docv:"COMMAND"))
    in
    Term.(ret (const cmd $ configTerm $ commandTerm $ setupLogTerm)), info
  in

  let shellCommand =
    let doc = "Enter esy sandbox shell" in
    let info = Term.info "shell" ~version ~doc ~sdocs ~exits in
    let cmd cfg () =
      runAsyncCommand ~header:`No info (devShell cfg)
    in
    Term.(ret (const cmd $ configTerm $ setupLogTerm)), info
  in

  let lsBuildsCommand =
    let doc = "Output a tree of packages in the sandbox along with their status" in
    let info = Term.info "ls-builds" ~version ~doc ~sdocs ~exits in
    let cmd includeTransitive cfg () =
      runAsyncCommand info (lsBuilds ~includeTransitive cfg)
    in
    let includeTransitive =
      let doc = "Include transitive dependencies" in
      Arg.(value & flag & info ["T"; "include-transitive"]  ~doc);
    in
    Term.(ret (const cmd $ includeTransitive $ configTerm $ setupLogTerm)), info
  in

  let makeAlias command alias =
    let term, info = command in
    let name = Term.name info in
    let doc = Printf.sprintf "An alias for $(b,%s) command" name in
    term, Term.info alias ~version ~doc ~sdocs ~exits
  in

  let bCommand = makeAlias buildCommand "b" in

  let commands = [
    (* commands *)
    buildPlanCommand;
    buildShellCommand;
    buildPackageCommand;
    buildCommand;

    shellCommand;

    buildEnvCommand;
    commandEnvCommand;
    sandboxEnvCommand;

    lsBuildsCommand;

    execCommand;

    (* aliases *)
    bCommand;
  ] in
  Term.(exit @@ eval_choice defaultCommand commands);
